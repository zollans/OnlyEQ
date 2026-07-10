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
        var preampLinear: Float = 1
        var outputGainLinear: Float = 1
        var limiterEnabled = true
        var limiterCeilingLinear: Float = pow(10, -1.0 / 20)  // -1 dBFS
        var bypassed = false
    }

    private var snapshot = Snapshot()
    private var pendingSnapshot: Snapshot?
    private var lock = os_unfair_lock()

    // Render-thread state (only touched on the audio thread).
    private var states: [BiquadState] = []  // flattened [channel][band]
    private var stateChannelCount = 0
    private var stateBandCount = 0
    private var limiterEnvelope: Float = 0
    private var limiterAttack = Float(exp(-1.0 / (0.001 * 48000)))
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
        limiterAttack = Float(exp(-1.0 / (0.001 * sampleRate)))
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
        limiterEnvelope = 0
    }

    /// Called from the UI/model thread whenever parameters change.
    func update(bands: [EQBand], preampDB: Double, outputGainDB: Double = 0,
                limiterEnabled: Bool, limiterCeilingDB: Double, bypassed: Bool) {
        var snap = Snapshot()
        snap.coefficients = bands.filter(\.isEnabled).map {
            BiquadCoefficients.make(type: $0.type, frequency: $0.frequency, gainDB: $0.gain, q: $0.q, sampleRate: sampleRate)
        }
        snap.preampLinear = Float(pow(10, preampDB / 20))
        snap.outputGainLinear = Float(pow(10, outputGainDB / 20))
        snap.limiterEnabled = limiterEnabled
        snap.limiterCeilingLinear = Float(pow(10, limiterCeilingDB / 20))
        snap.bypassed = bypassed
        os_unfair_lock_lock(&lock)
        pendingSnapshot = snap
        os_unfair_lock_unlock(&lock)
    }

    /// Process non-interleaved Float32 channel buffers in place. Audio thread only.
    func process(channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        if os_unfair_lock_trylock(&lock) {
            if let pending = pendingSnapshot {
                snapshot = pending
                pendingSnapshot = nil
            }
            os_unfair_lock_unlock(&lock)
        }
        let snap = snapshot
        if snap.bypassed { return }

        // (Re)size filter state to match topology.
        let channelCount = channels.count
        let bandCount = snap.coefficients.count
        if stateChannelCount != channelCount || stateBandCount != bandCount {
            states = Array(repeating: BiquadState(), count: channelCount * bandCount)
            stateChannelCount = channelCount
            stateBandCount = bandCount
            limiterEnvelope = 0
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
                            var sample = channelBuffers[ch][frame] * snap.preampLinear
                            if bandCount > 0, let stateBase, let coefficientBase {
                                let channelStates = stateBase + ch * bandCount
                                for band in 0..<bandCount {
                                    sample = channelStates[band].process(sample, coefficientBase[band])
                                }
                            }
                            sample *= snap.outputGainLinear
                            channelBuffers[ch][frame] = sample
                            maxMag = max(maxMag, abs(sample))
                        }
                        if snap.limiterEnabled {
                            let coefficient = maxMag > limiterEnvelope ? limiterAttack : limiterRelease
                            limiterEnvelope = coefficient * limiterEnvelope + (1 - coefficient) * maxMag
                            if limiterEnvelope > snap.limiterCeilingLinear {
                                let gain = snap.limiterCeilingLinear / limiterEnvelope
                                for ch in 0..<channelCount { channelBuffers[ch][frame] *= gain }
                                maxMag *= gain
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
