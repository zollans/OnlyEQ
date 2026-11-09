import Foundation
import os.lock

/// Realtime-safe EQ chain: preamp → biquad cascade → soft limiter → output gain.
///
/// The UI thread rebuilds a `Snapshot` and swaps it in under a lock; the render
/// thread try-locks — if the lock is contended it keeps using the old snapshot
/// for that cycle rather than blocking the audio thread.
final class EQProcessor {
    struct Snapshot {
        var coefficients: [BiquadCoefficients] = []
        /// Each channel's filters as a range of `coefficients`: left, right,
        /// and any further channels. All three share one range unless the
        /// preset has left- or right-only bands.
        var leftRange = 0..<0
        var rightRange = 0..<0
        var otherRange = 0..<0
        /// Filter history slots per channel: the longest of the three ranges.
        var stride = 0
        /// Zeroed filter history for `channelCapacity` channels, allocated on
        /// the model thread and adopted by the render thread when the band
        /// count changes, so the realtime path never calls malloc.
        var freshStates: [BiquadState] = []
        var preampLinear: Float = 1
        var outputGainLinear: Float = 1
        var limiterEnabled = true
        var limiterCeilingLinear: Float = pow(10, -1.0 / 20)  // -1 dBFS
        var bypassed = false
    }

    private var snapshot = Snapshot()
    /// Guarded by `lock`. Holds the next snapshot while `hasPending`, and the
    /// retired one afterwards so its storage is released by the next update()
    /// on the model thread rather than freed on the render thread.
    private var pending = Snapshot()
    private var hasPending = false
    private var lock = os_unfair_lock()
    private static let channelCapacity = 8

    // Render-thread state (only touched on the audio thread).
    private var states: [BiquadState] = []  // flattened [channel][band]
    private var stateStride = 0
    /// Applied limiter gain (1 = untouched). Attack is instantaneous so the
    /// ceiling is a hard guarantee on every sample; only recovery is smoothed.
    private var limiterGain: Float = 1
    private var limiterRelease = Float(exp(-1.0 / (0.080 * 48000)))
    private(set) var sampleRate: Double = 48000

    /// Peak level (post-chain) for metering; read from any thread.
    private struct MeterState {
        var peak: Float = 0
        var isActive = false
    }
    private let meter = OSAllocatedUnfairLock(initialState: MeterState())
    var currentPeak: Float {
        meter.withLock { state in
            let value = state.peak
            state.peak = 0
            return value
        }
    }

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        limiterRelease = Float(exp(-1.0 / (0.080 * sampleRate)))
    }

    /// Main/UI thread: the peak accumulator has no consumer while the editor
    /// is hidden, so avoid a cross-thread lock on every render callback.
    func setMeteringActive(_ active: Bool) {
        meter.withLock { state in
            state.isActive = active
            if !active { state.peak = 0 }
        }
    }

    /// Audio thread only. Clear filter and limiter history before the engine
    /// enters its prolonged-silence fast path. Keeping the existing storage
    /// avoids allocating from the realtime callback.
    func resetRenderState() {
        for index in states.indices { states[index] = BiquadState() }
        limiterGain = 1
    }

    /// Called from the UI/model thread whenever parameters change.
    func update(bands: [EQBand], preampDB: Double, outputGainDB: Double = 0,
                limiterEnabled: Bool, limiterCeilingDB: Double, bypassed: Bool) {
        var snap = Snapshot()
        let enabled = bands.filter(\.isEnabled)
        let make = { (list: [EQBand]) in
            list.map {
                BiquadCoefficients.make(type: $0.type, frequency: $0.frequency, gainDB: $0.gain, q: $0.q, sampleRate: self.sampleRate)
            }
        }
        if enabled.contains(where: { $0.channel != .both }) {
            let left = make(enabled.filter { $0.channel.applies(toChannel: 0) })
            let right = make(enabled.filter { $0.channel.applies(toChannel: 1) })
            let other = make(enabled.filter { $0.channel == .both })
            snap.coefficients = left + right + other
            snap.leftRange = 0..<left.count
            snap.rightRange = left.count..<(left.count + right.count)
            snap.otherRange = (left.count + right.count)..<snap.coefficients.count
            snap.stride = max(left.count, right.count)
        } else {
            snap.coefficients = make(enabled)
            snap.leftRange = 0..<snap.coefficients.count
            snap.rightRange = snap.leftRange
            snap.otherRange = snap.leftRange
            snap.stride = snap.coefficients.count
        }
        snap.preampLinear = Float(pow(10, preampDB / 20))
        snap.outputGainLinear = Float(pow(10, outputGainDB / 20))
        snap.limiterEnabled = limiterEnabled
        snap.limiterCeilingLinear = Float(pow(10, limiterCeilingDB / 20))
        snap.bypassed = bypassed
        snap.freshStates = Array(repeating: BiquadState(), count: Self.channelCapacity * snap.stride)
        os_unfair_lock_lock(&lock)
        pending = snap
        hasPending = true
        os_unfair_lock_unlock(&lock)
    }

    /// Process non-interleaved Float32 channel buffers in place. Audio thread only.
    func process(channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        if os_unfair_lock_trylock(&lock) {
            if hasPending {
                swap(&snapshot, &pending)
                hasPending = false
                if snapshot.stride != stateStride {
                    // Adopt the preallocated history; the old one retires
                    // with the previous snapshot.
                    swap(&states, &snapshot.freshStates)
                    stateStride = snapshot.stride
                    limiterGain = 1
                }
            }
            os_unfair_lock_unlock(&lock)
        }
        let snap = snapshot
        // Bypass skips the EQ (preamp + bands) but keeps the output gain and
        // limiter: on devices without hardware volume the output gain is the
        // volume control, and dropping it would jump to full level.
        let applyEQ = !snap.bypassed
        let preampLinear: Float = applyEQ ? snap.preampLinear : 1

        let channelCount = channels.count
        let stride = snap.stride
        if states.count < channelCount * stride {
            // More channels than `channelCapacity`: allocate as a last resort.
            states = Array(repeating: BiquadState(), count: channelCount * stride)
        }

        let meteringActive = meter.withLockIfAvailable { $0.isActive } ?? false
        var peak: Float = 0

        // Work through raw buffers so mutating filter state does not trigger an
        // Array copy-on-write uniqueness check for every sample and band.
        channels.withUnsafeBufferPointer { channelBuffers in
            states.withUnsafeMutableBufferPointer { stateBuffer in
                snap.coefficients.withUnsafeBufferPointer { coefficientBuffer in
                    let stateBase = stateBuffer.baseAddress
                    let coefficientBase = coefficientBuffer.baseAddress

                    for frame in 0..<frameCount {
                        // Stereo-linked limiter: find the loudest post-EQ sample across channels.
                        var maxMag: Float = 0
                        for ch in 0..<channelCount {
                            var sample = channelBuffers[ch][frame] * preampLinear
                            let range = ch == 0 ? snap.leftRange : ch == 1 ? snap.rightRange : snap.otherRange
                            if applyEQ, !range.isEmpty, let stateBase, let coefficientBase {
                                let channelStates = stateBase + ch * stride
                                let channelCoefficients = coefficientBase + range.lowerBound
                                for band in 0..<range.count {
                                    sample = channelStates[band].process(sample, channelCoefficients[band])
                                }
                            }
                            sample *= snap.outputGainLinear
                            channelBuffers[ch][frame] = sample
                            maxMag = max(maxMag, abs(sample))
                        }
                        if snap.limiterEnabled {
                            // A smoothed envelope is the wrong thing to compare
                            // against the ceiling: its attack ramp lets the first
                            // samples of a transient through unattenuated, which
                            // is the one case a safety limiter exists for. Derive
                            // the gain from this frame's peak instead, clamping
                            // immediately and releasing smoothly.
                            let required = maxMag > 0
                                ? min(1, snap.limiterCeilingLinear / maxMag) : 1
                            if required < limiterGain {
                                limiterGain = required
                            } else {
                                limiterGain = limiterRelease * limiterGain + (1 - limiterRelease) * required
                                if limiterGain > 1 { limiterGain = 1 }
                            }
                            if limiterGain < 1 {
                                for ch in 0..<channelCount { channelBuffers[ch][frame] *= limiterGain }
                                maxMag *= limiterGain
                            }
                        }
                        if meteringActive { peak = max(peak, maxMag) }
                    }
                }
            }
        }

        if meteringActive {
            let framePeak = peak
            meter.withLockIfAvailable { state in
                guard state.isActive else { return }
                state.peak = max(state.peak, framePeak)
            }
        }
    }
}
