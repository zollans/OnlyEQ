import Foundation

/// Minimal self-test harness (CLT has no XCTest). Run with `swift run OnlyEQ --test`.
enum TestRunner {
    private static var failures: [String] = []
    private static var passed = 0

    private static func expect(_ condition: Bool, _ label: String,
                               file: String = #fileID, line: Int = #line) {
        if condition { passed += 1 }
        else { failures.append("\(label)  (\(file):\(line))") }
    }

    private static func near(_ a: Double, _ b: Double, _ tol: Double = 0.001) -> Bool { abs(a - b) <= tol }

    private static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.resourceURL.map({ $0.appendingPathComponent("Fixtures/\(name)") }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func run() -> Int32 {
        do {
            try importerTests()
            dspTests()
        } catch {
            failures.append("Uncaught error: \(error)")
        }
        print("\(passed) checks passed, \(failures.count) failed")
        for f in failures { print("  FAIL: \(f)") }
        return failures.isEmpty ? 0 : 1
    }

    private static func importerTests() throws {
        var r = try PresetImporter.importData(fixture("autoeq_parametric.txt"))
        expect(r.detectedFormat == "AutoEq / Equalizer APO parametric", "autoeq format")
        expect(near(r.preset.preampDB, -6.1), "autoeq preamp")
        expect(r.preset.bands.count == 10, "autoeq band count")
        expect(r.preset.bands[0].type == .lowShelf && r.preset.bands[0].frequency == 105, "autoeq LSC band")
        expect(near(r.preset.bands[0].gain, 6.4) && near(r.preset.bands[0].q, 0.70), "autoeq band values")
        expect(r.preset.bands[5].type == .highShelf, "autoeq HSC band")
        expect(near(r.preset.bands[9].q, 5.75), "autoeq high-Q band")

        r = try PresetImporter.importData(fixture("graphiceq.txt"))
        expect(r.detectedFormat == "GraphicEQ (Wavelet)", "graphiceq format")
        expect(r.preset.bands.count == 31, "graphiceq 31 ISO third-octave bands")
        expect(r.preset.bands.allSatisfy { $0.type == .peak && near($0.q, 4.318) }, "graphiceq third-octave Q")
        expect(r.preset.preampDB == 0, "graphiceq no preamp for negative gains")
        if let b125 = r.preset.bands.first(where: { $0.frequency == 125 }) {
            expect(near(b125.gain, -2.3), "graphiceq interpolation at 125 Hz")
        } else { expect(false, "graphiceq 125 Hz band exists") }
        if let b315 = r.preset.bands.first(where: { $0.frequency == 315 }) {
            expect(near(b315.gain, -2.7), "graphiceq interpolation at 315 Hz")
        } else { expect(false, "graphiceq 315 Hz band exists") }
        expect(r.preset.bands.first?.frequency == 20 && near(r.preset.bands.first?.gain ?? 0, -0.2),
               "graphiceq clamps below first point")
        expect(r.preset.bands.last?.frequency == 20000 && near(r.preset.bands.last?.gain ?? 0, -6.4),
               "graphiceq clamps above last point")

        r = try PresetImporter.importData(fixture("poweramp.json"))
        expect(r.detectedFormat == "Poweramp JSON", "poweramp format")
        expect(r.preset.name == "PA-CEQ 3 Parametric", "poweramp name")
        expect(near(r.preset.preampDB, -5.6), "poweramp preamp")
        expect(r.preset.bands.count == 3, "poweramp placeholders dropped")
        expect(r.preset.bands[1].type == .lowShelf && r.preset.bands[2].type == .highShelf, "poweramp types")

        r = try PresetImporter.importData(fixture("opra.json"))
        expect(r.detectedFormat == "OPRA JSON", "opra format")
        expect(near(r.preset.preampDB, -9.3), "opra preamp")
        expect(r.preset.bands.count == 4, "opra band count")
        expect(r.preset.bands[1].type == .lowShelf && r.preset.bands[3].type == .highShelf, "opra types")
        expect(r.preset.bands[3].frequency == 11000, "opra frequency")

        r = try PresetImporter.importData(fixture("eqmac.json"))
        expect(r.detectedFormat == "eqMac JSON", "eqmac format")
        expect(r.preset.name == "Sennheiser HD 650", "eqmac name")
        expect(near(r.preset.preampDB, -6.4), "eqmac preamp")
        expect(r.preset.bands.count == 10 && r.preset.bands[0].frequency == 32, "eqmac bands")
        expect(near(r.preset.bands[0].gain, 6.0), "eqmac gain")

        r = try PresetImporter.importData(fixture("peqdb.json"))
        expect(r.detectedFormat == "peqdb", "peqdb format")
        expect(r.preset.bands.count == 4, "peqdb band count")
        expect(r.preset.bands[0].type == .lowShelf && near(r.preset.bands[0].frequency, 22.2), "peqdb LSC")
        expect(r.preset.bands[3].type == .highShelf, "peqdb HSC")
        expect(near(r.preset.preampDB, -5.7), "peqdb preamp from APO text")

        r = try PresetImporter.importData(fixture("peace.peace"))
        expect(r.detectedFormat == "Peace (Equalizer APO)", "peace format")
        expect(r.preset.bands.count == 4, "peace band count")
        expect(r.preset.bands[0].type == .peak && r.preset.bands[1].type == .lowShelf
               && r.preset.bands[3].type == .highShelf, "peace types")
        expect(near(r.preset.bands[1].gain, 5.5), "peace gain")

        r = try PresetImporter.importData(fixture("rew.txt"))
        expect(r.detectedFormat == "REW filter settings", "rew format")
        expect(r.preset.bands.count == 3, "rew OFF filter dropped")
        expect(r.preset.bands[2].type == .lowShelf && near(r.preset.bands[2].q, 0.707), "rew shelf default Q")
        expect(near(r.preset.bands[0].q, 4.94), "rew Q parsed")

        r = try PresetImporter.importData(fixture("qudelix.txt"))
        expect(r.preset.bands.count == 3, "qudelix padding dropped")
        expect(near(r.preset.preampDB, -5.7), "qudelix preamp")

        r = try PresetImporter.importText("Filter 1: ON PK Fc 1000 Hz Gain -3.0 dB BW Oct 1")
        expect(near(r.preset.bands[0].q, 1.414, 0.01), "BW Oct → Q conversion")

        do {
            _ = try PresetImporter.importText("hello world, no EQ here")
            expect(false, "unrecognized input throws")
        } catch { expect(true, "unrecognized input throws") }

        let original = EQPreset(name: "Round Trip", preampDB: -4.2, bands: [
            EQBand(type: .peak, frequency: 1234, gain: -2.5, q: 2.2),
            EQBand(type: .highShelf, frequency: 9000, gain: 3, q: 0.71),
        ])
        let data = try JSONEncoder().encode(original)
        r = try PresetImporter.importData(data)
        expect(r.detectedFormat == "OnlyEQ preset" && r.preset == original, "native round trip")
    }

    private static func dspTests() {
        let c = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: 6, q: 1.41, sampleRate: 48000)
        expect(near(c.magnitudeDB(at: 1000, sampleRate: 48000), 6, 0.01), "peak magnitude at Fc")
        expect(near(c.magnitudeDB(at: 20, sampleRate: 48000), 0, 0.1), "peak magnitude at 20 Hz")
        expect(near(c.magnitudeDB(at: 20000, sampleRate: 48000), 0, 0.1), "peak magnitude at 20 kHz")

        expect(near(EQResponse.autoPreamp(bands: [EQBand(type: .peak, frequency: 1000, gain: 5, q: 1.41)]), -5, 0.1),
               "auto preamp for +5 dB peak")
        expect(EQResponse.autoPreamp(bands: [EQBand(type: .peak, frequency: 1000, gain: -5, q: 1.41)]) == 0,
               "auto preamp zero for cuts")

        let gainProc = EQProcessor()
        gainProc.configure(sampleRate: 48000)
        gainProc.update(bands: [], preampDB: -6.02, limiterEnabled: false, limiterCeilingDB: -1, bypassed: false)
        gainProc.setMeteringActive(true)
        var dc = [Float](repeating: 1.0, count: 512)
        dc.withUnsafeMutableBufferPointer { buf in
            gainProc.process(channels: [buf.baseAddress!], frameCount: 512)
        }
        expect(abs(dc[100] - 0.5) < 0.01, "processor applies preamp gain")
        expect(abs(gainProc.currentPeak - 0.5) < 0.01, "active peak meter reports processed level")
        expect(gainProc.currentPeak == 0, "reading peak meter resets it")

        gainProc.setMeteringActive(false)
        dc.withUnsafeMutableBufferPointer { buf in
            gainProc.process(channels: [buf.baseAddress!], frameCount: 512)
        }
        expect(gainProc.currentPeak == 0, "inactive peak meter does not accumulate")

        let filterProc = EQProcessor()
        filterProc.configure(sampleRate: 48000)
        filterProc.update(bands: [EQBand(type: .peak, frequency: 1000, gain: 6, q: 1.41)],
                          preampDB: 0, limiterEnabled: false, limiterCeilingDB: -1, bypassed: false)
        var filteredSine = (0..<4800).map { Float(0.1 * sin(Double($0) * 2 * .pi * 1000 / 48000)) }
        filteredSine.withUnsafeMutableBufferPointer { buffer in
            filterProc.process(channels: [buffer.baseAddress!], frameCount: buffer.count)
        }
        let filteredPeak = filteredSine[2400...].map(abs).max() ?? 0
        expect(abs(filteredPeak - 0.2) < 0.01, "processor applies biquad gain at center frequency")

        let limProc = EQProcessor()
        limProc.configure(sampleRate: 48000)
        limProc.update(bands: [], preampDB: 12, limiterEnabled: true, limiterCeilingDB: -1, bypassed: false)
        var sine = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) }
        sine.withUnsafeMutableBufferPointer { buf in
            limProc.process(channels: [buf.baseAddress!], frameCount: 4800)
        }
        let ceiling = pow(10, Float(-1.0) / 20) * 1.05
        expect(sine[2400...].map(abs).max()! <= ceiling, "limiter caps output at ceiling")

        let analyzer = SpectrumAnalyzer()
        analyzer.configure(sampleRate: 48000)
        analyzer.setActive(true)
        let exactBinFrequency = 42.0 * 48000 / 2048
        var tone = (0..<2048).map { Float(sin(Double($0) * 2 * .pi * exactBinFrequency / 48000)) }
        tone.withUnsafeMutableBufferPointer { buffer in
            analyzer.push(channels: [buffer.baseAddress!], frameCount: buffer.count)
        }
        let bars = analyzer.bars()
        let dominantBar = bars.indices.max(by: { bars[$0] < bars[$1] })
        expect(bars.count == SpectrumAnalyzer.barCount, "spectrum emits configured bar count")
        expect((26...28).contains(dominantBar ?? -1), "spectrum places 1 kHz tone in expected log band")
        expect(bars.max() ?? 0 > 0.5, "spectrum reports an audible tone")

        analyzer.setActive(false)
        analyzer.setActive(true)
        expect(analyzer.bars().allSatisfy { $0 == 0 }, "reactivating spectrum starts with a cleared ring")

        // Bluetooth device-name cleanup and deterministic catalog ranking.
        expect(HeadphoneNameMatcher.searchQuery(for: "Aaron’s WH-1000XM5 Stereo") == "WH-1000XM5",
               "headphone matcher strips owner and Bluetooth noise")
        expect(HeadphoneNameMatcher.searchQuery(for: "LE_AirPods Pro") == "AirPods Pro",
               "headphone matcher strips Bluetooth LE prefix")
        expect(HeadphoneNameMatcher.score(query: "WH-1000XM5", candidate: "Sony WH-1000XM5")
               > HeadphoneNameMatcher.score(query: "WH-1000XM5", candidate: "Sony WH-1000XM4"),
               "headphone matcher prioritizes exact model number")
    }
}
