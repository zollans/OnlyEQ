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
    private var states: [[BiquadState]] = []  // [channel][band]
    private var limiterEnvelope: Float = 0
    private(set) var sampleRate: Double = 48000

    /// Peak level (post-chain) for metering; read from any thread.
    private let peakBits = OSAllocatedUnfairLock(initialState: Float(0))
    var currentPeak: Float {
        peakBits.withLock { let v = $0; $0 = 0; return v }
    }

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
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
        if states.count != channels.count || states.first?.count != snap.coefficients.count {
            states = Array(repeating: Array(repeating: BiquadState(), count: snap.coefficients.count), count: channels.count)
            limiterEnvelope = 0
        }

        // Envelope coefficients: ~1 ms attack, ~80 ms release.
        let attack = Float(exp(-1.0 / (0.001 * sampleRate)))
        let release = Float(exp(-1.0 / (0.080 * sampleRate)))
        var peak: Float = 0

        for frame in 0..<frameCount {
            // Stereo-linked limiter: find the loudest post-EQ sample across channels.
            var maxMag: Float = 0
            for ch in 0..<channels.count {
                var sample = channels[ch][frame] * snap.preampLinear
                for (i, c) in snap.coefficients.enumerated() {
                    sample = states[ch][i].process(sample, c)
                }
                sample *= snap.outputGainLinear
                channels[ch][frame] = sample
                maxMag = max(maxMag, abs(sample))
            }
            if snap.limiterEnabled {
                let coeff = maxMag > limiterEnvelope ? attack : release
                limiterEnvelope = coeff * limiterEnvelope + (1 - coeff) * maxMag
                if limiterEnvelope > snap.limiterCeilingLinear {
                    let g = snap.limiterCeilingLinear / limiterEnvelope
                    for ch in 0..<channels.count { channels[ch][frame] *= g }
                    maxMag *= g
                }
            }
            peak = max(peak, maxMag)
        }
        let framePeak = peak
        peakBits.withLock { $0 = max($0, framePeak) }
    }
}
