import Foundation
import Accelerate
import os.lock

/// Collects post-EQ samples on the audio thread and computes log-spaced
/// spectrum bars on demand from the UI thread.
final class SpectrumAnalyzer {
    static let barCount = 48
    private static let fftSize = 2048

    private let ring = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: SpectrumAnalyzer.fftSize))
    private var writeIndex = 0
    private let fftSetup = vDSP.FFT(log2n: vDSP_Length(log2(Double(SpectrumAnalyzer.fftSize))),
                                    radix: .radix2, ofType: DSPSplitComplex.self)
    private var sampleRate: Double = 48000

    // Scratch buffers reused across `bars()` calls (UI thread only), so the
    // periodic spectrum refresh never allocates.
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    private var barsOut: [Float]

    init() {
        let n = Self.fftSize
        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        window = hann
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)
        barsOut = [Float](repeating: 0, count: Self.barCount)
    }

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Audio thread: push a mono mixdown of the processed buffer.
    func push(channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        guard !channels.isEmpty else { return }
        ring.withLockIfAvailable { buffer in
            var idx = writeIndex
            let scale = 1.0 / Float(channels.count)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in channels { sum += ch[frame] }
                buffer[idx] = sum * scale
                idx = (idx + 1) % Self.fftSize
            }
            writeIndex = idx
        }
    }

    /// UI thread: 0…1 magnitudes for `barCount` log-spaced bands, 20 Hz – 20 kHz.
    func bars() -> [Float] {
        guard let fftSetup else { return [] }

        let n = Self.fftSize
        ring.withLock { samples in
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    raw.baseAddress!.assumingMemoryBound(to: DSPComplex.self).withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fftSetup.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        let binWidth = Float(sampleRate) / Float(n)
        let logLo = log10(Float(20)), logHi = log10(Float(20000))
        for bar in 0..<Self.barCount {
            let f0 = pow(10, logLo + (logHi - logLo) * Float(bar) / Float(Self.barCount))
            let f1 = pow(10, logLo + (logHi - logLo) * Float(bar + 1) / Float(Self.barCount))
            let lo = max(1, Int(f0 / binWidth)), hi = min(n / 2 - 1, max(lo, Int(f1 / binWidth)))
            var peak: Float = 0
            for bin in lo...hi { peak = max(peak, magnitudes[bin]) }
            // Map to dBFS, normalized -60…0 dB → 0…1.
            let db = 20 * log10(max(peak / Float(n), 1e-9))
            barsOut[bar] = min(max((db + 60) / 60, 0), 1)
        }
        return barsOut
    }
}
