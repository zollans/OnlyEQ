import AppKit
import Combine
import CoreAudio
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
            try exporterTests()
            textEditingShortcutTests()
            dspTests()
            watchdogTests()
            engineRenderTests()
            appStateTests()
            storeTests()
        } catch {
            failures.append("Uncaught error: \(error)")
        }
        print("\(passed) checks passed, \(failures.count) failed")
        for f in failures { print("  FAIL: \(f)") }
        return failures.isEmpty ? 0 : 1
    }

    private static func textEditingShortcutTests() {
        final class PasteProbeTextView: NSTextView {
            var receivedPaste = false

            override func paste(_ sender: Any?) {
                receivedPaste = true
            }
        }

        let command: NSEvent.ModifierFlags = .command
        expect(AppShortcutMonitor.editingAction(characters: "a", modifiers: command)
               == #selector(NSText.selectAll(_:)), "Command-A maps to Select All")
        expect(AppShortcutMonitor.editingAction(characters: "v", modifiers: command)
               == #selector(NSText.paste(_:)), "Command-V maps to Paste")
        expect(AppShortcutMonitor.editingAction(characters: "z", modifiers: [.command, .shift])
               == Selector(("redo:")), "Command-Shift-Z maps to Redo")
        expect(AppShortcutMonitor.editingAction(characters: "v", modifiers: [.command, .option]) == nil,
               "modified Command-V is not intercepted")
        expect(AppShortcutMonitor.editingAction(characters: "v", modifiers: []) == nil,
               "plain V is not intercepted")
        expect(AppShortcutMonitor.isCloseWindowShortcut(characters: "w", modifiers: command),
               "Command-W maps to Close Window")
        expect(!AppShortcutMonitor.isCloseWindowShortcut(characters: "w", modifiers: [.command, .shift]),
               "modified Command-W is not intercepted")

        let textView = PasteProbeTextView()
        let action = AppShortcutMonitor.editingAction(characters: "v", modifiers: command)
        let delivered = action.map { textView.tryToPerform($0, with: nil) } ?? false
        expect(delivered && textView.receivedPaste, "Paste selector is handled by a text responder")
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
        expect(r.preset.bands.count == 10, "graphiceq 10 bands")
        expect(r.preset.bands.allSatisfy { $0.type == .peak && $0.q == 1.41 }, "graphiceq peaking Q1.41")
        expect(r.preset.preampDB == 0, "graphiceq no preamp for negative gains")
        if let b125 = r.preset.bands.first(where: { $0.frequency == 125 }) {
            expect(b125.gain < -2.0 && b125.gain > -3.0, "graphiceq interpolation")
        } else { expect(false, "graphiceq 125 Hz band exists") }

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

    private static func exporterTests() throws {
        let fixtureText = String(decoding: try fixture("autoeq_parametric.txt"), as: UTF8.self)
        let exported = PresetExporter.parametricText(try PresetImporter.importData(fixture("autoeq_parametric.txt")).preset)
        expect(exported.trimmingCharacters(in: .whitespacesAndNewlines)
               == fixtureText.trimmingCharacters(in: .whitespacesAndNewlines), "exporter matches autoeq fixture")
        expect(exported.hasPrefix("Preamp: "), "exporter preamp first")
        expect(exported.components(separatedBy: "\n")[1].hasPrefix("Filter 1: ON"), "exporter filter 1 second")

        let allTypes = EQPreset(name: "Types", bands: FilterType.allCases.enumerated().map { i, type in
            EQBand(type: type, frequency: 1000 + Double(i), gain: 1.5, q: 0.9)
        })
        var r = try PresetImporter.importText(PresetExporter.parametricText(allTypes))
        expect(r.preset.bands.count == FilterType.allCases.count, "exporter all types count")
        expect(r.preset.bands.map(\.type) == FilterType.allCases, "exporter all types round trip")

        let precise = EQPreset(name: "Precise", preampDB: -3.35, bands: [
            EQBand(type: .peak, frequency: 22.2, gain: 1.24, q: 1.414),
        ])
        r = try PresetImporter.importText(PresetExporter.parametricText(precise))
        expect(r.preset.preampDB == -3.35, "exporter preamp precision")
        expect(r.preset.bands[0].frequency == 22.2 && r.preset.bands[0].gain == 1.24 && r.preset.bands[0].q == 1.414,
               "exporter band precision")

        let disabled = EQPreset(name: "Off", bands: [
            EQBand(type: .peak, frequency: 3000, gain: -2, q: 2, isEnabled: false),
        ])
        let disabledText = PresetExporter.parametricText(disabled)
        expect(disabledText.contains("OFF PK"), "exporter OFF band")
        r = try PresetImporter.importText(disabledText)
        expect(r.preset.bands[0].isEnabled == false, "exporter OFF band round trip")
    }

    private static func storeTests() {
        // `--test` runs on the main thread (see main.swift), so touching the
        // MainActor-isolated PresetStore directly is safe.
        MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("OnlyEQ-tests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let edited = EQPreset(name: "Working", preampDB: -3, bands: [
                EQBand(type: .peak, frequency: 3000, gain: -4, q: 2),
            ])
            let store = PresetStore(directory: dir)
            expect(store.workingPreset(forDevice: "uid-a") == nil, "no working preset for unknown device")
            store.stashWorkingPreset(edited, forDevice: "uid-a")
            expect(store.workingPreset(forDevice: "uid-a") == edited, "working preset stash round trip")
            expect(store.workingPreset(forDevice: "uid-b") == nil, "stash is keyed by device UID")

            let reloaded = PresetStore(directory: dir)
            expect(reloaded.workingPreset(forDevice: "uid-a") == edited, "working preset stash persists to disk")
        }
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

    /// Every objectWillChange re-layouts each alive (hidden) window's SwiftUI
    /// tree, so steady-state watchdog ticks must not publish.
    private static func watchdogTests() {
        MainActor.assumeIsolated {
            AppState.screenshotMode = true  // no engine, no persistence
            let state = AppState.shared
            state.engineState = .stopped

            var publishes = 0
            let subscription = state.objectWillChange.sink { _ in publishes += 1 }
            withExtendedLifetime(subscription) {
                state.silenceWatchdogTick()
                state.silenceWatchdogTick()
            }
            expect(publishes == 0, "watchdog ticks publish only on change")
        }
    }

    /// Wraps interleaved sample storage in single-buffer AudioBufferLists and
    /// drives the engine's render callback directly, without Core Audio.
    private static func renderOnce(_ engine: ProcessTapEngine, channels: Int,
                                   input: inout [Float], output: inout [Float]) {
        input.withUnsafeMutableBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                var inputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                          mDataByteSize: UInt32(inBuf.count * MemoryLayout<Float>.size),
                                          mData: UnsafeMutableRawPointer(inBuf.baseAddress)))
                var outputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                          mDataByteSize: UInt32(outBuf.count * MemoryLayout<Float>.size),
                                          mData: UnsafeMutableRawPointer(outBuf.baseAddress)))
                engine.render(input: &inputList, output: &outputList)
            }
        }
    }

    private static func withAudioBufferList(_ buffers: [AudioBuffer], _ body: (UnsafeMutablePointer<AudioBufferList>) -> Void) {
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        let storage = UnsafeMutableRawPointer.allocate(byteCount: offset + buffers.count * MemoryLayout<AudioBuffer>.size,
                                                        alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        list.pointee.mNumberBuffers = UInt32(buffers.count)
        let destination = storage.advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self)
        destination.initialize(from: buffers, count: buffers.count)
        body(list)
    }

    private static func engineRenderTests() {
        let frames = 512, channels = 2

        let stereo = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                  mFormatFlags: kAudioFormatFlagIsFloat, mBytesPerPacket: 8,
                                                  mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                                  mBitsPerChannel: 32, mReserved: 0)
        var physical = stereo
        physical.mChannelsPerFrame = 4
        physical.mBytesPerPacket = 16
        physical.mBytesPerFrame = 16
        var mono = stereo
        mono.mChannelsPerFrame = 1
        mono.mBytesPerPacket = 4
        mono.mBytesPerFrame = 4
        var nonInterleaved = stereo
        nonInterleaved.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        expect(TapInputSelection.select(tapFormat: stereo, aggregateInputFormats: [physical, stereo], aggregateInputChannels: [4, 2]) == TapInputSelection(bufferIndex: 1, channels: 2), "tap selection finds trailing stereo stream")
        expect(TapInputSelection.select(tapFormat: stereo, aggregateInputFormats: [stereo, physical], aggregateInputChannels: [2, 4]) == TapInputSelection(bufferIndex: 0, channels: 2), "tap selection follows queried stream order")
        expect(TapInputSelection.select(tapFormat: stereo, aggregateInputFormats: [stereo], aggregateInputChannels: [2]) == TapInputSelection(bufferIndex: 0, channels: 2), "tap selection supports built-in stereo")
        expect(TapInputSelection.select(tapFormat: stereo, aggregateInputFormats: [physical, mono, mono], aggregateInputChannels: [4, 1, 1]) == nil, "tap selection rejects adjacent mono candidates")
        expect(TapInputSelection.select(tapFormat: nonInterleaved, aggregateInputFormats: [nonInterleaved], aggregateInputChannels: [2]) == nil, "tap selection rejects non-interleaved tap format")
        expect(TapInputSelection.select(tapFormat: stereo, aggregateInputFormats: [physical], aggregateInputChannels: [4]) == nil, "tap selection rejects missing stereo stream")
        expect(TapInputSelection.select(tapFormat: stereo, aggregateInputFormats: [stereo, stereo], aggregateInputChannels: [2, 2]) == nil, "tap selection rejects ambiguous stereo streams")
        expect(TapInputSelection.select(tapFormat: stereo,
                                        aggregateInputFormats: [stereo, stereo],
                                        aggregateInputChannels: [2, 2],
                                        aggregateInputStartingChannels: [1, 3],
                                        physicalInputChannelCount: 2) == TapInputSelection(bufferIndex: 1, channels: 2),
               "tap selection resolves Scarlett-style matching stereo input at channel boundary")
        expect(TapInputSelection.select(tapFormat: stereo,
                                        aggregateInputFormats: [stereo, stereo],
                                        aggregateInputChannels: [2, 2],
                                        aggregateInputStartingChannels: [3, 1],
                                        physicalInputChannelCount: 2) == TapInputSelection(bufferIndex: 0, channels: 2),
               "tap selection uses channel provenance rather than stream-array order")
        expect(TapInputSelection.select(tapFormat: stereo,
                                        aggregateInputFormats: [stereo, stereo],
                                        aggregateInputChannels: [2, 2],
                                        aggregateInputStartingChannels: [1, 3],
                                        physicalInputChannelCount: 4) == nil,
               "tap selection rejects matching streams without the expected channel boundary")

        let reversedEngine = ProcessTapEngine(preparedInput: TapInputSelection(bufferIndex: 0, channels: 2))
        var reversedTapInput = (0..<frames).flatMap { _ in [Float(0.125), Float(-0.25)] }
        var reversedPhysicalInput = [Float](repeating: 77, count: frames * 4)
        var reversedOutput = [Float](repeating: 0, count: frames * 4)
        reversedTapInput.withUnsafeMutableBufferPointer { tapBuffer in
            reversedPhysicalInput.withUnsafeMutableBufferPointer { physicalBuffer in
                reversedOutput.withUnsafeMutableBufferPointer { outputBuffer in
                    withAudioBufferList([
                        AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBuffer.count * MemoryLayout<Float>.size), mData: tapBuffer.baseAddress),
                        AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(physicalBuffer.count * MemoryLayout<Float>.size), mData: physicalBuffer.baseAddress),
                    ]) { input in
                        withAudioBufferList([
                            AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(outputBuffer.count * MemoryLayout<Float>.size), mData: outputBuffer.baseAddress),
                        ]) { output in
                            reversedEngine.render(input: input, output: output)
                        }
                    }
                }
            }
        }
        expect((0..<frames).allSatisfy { frame in
            let base = frame * 4
            return reversedOutput[base] == 0.125 && reversedOutput[base + 1] == -0.25
                && reversedOutput[base + 2] == 0.125 && reversedOutput[base + 3] == -0.25
        }, "render consumes selected tap at index 0 before physical stream")
        expect(!reversedOutput.contains(77), "reversed render never outputs physical sentinel")

        let routingEngine = ProcessTapEngine(preparedInput: TapInputSelection(bufferIndex: 1, channels: 2))
        var physicalInput = [Float](repeating: 99, count: frames * 4)
        var tapInput = (0..<frames).flatMap { _ in [Float(0.25), Float(-0.5)] }
        var fourChannelOutput = [Float](repeating: 0, count: frames * 4)
        physicalInput.withUnsafeMutableBufferPointer { physicalBuffer in
            tapInput.withUnsafeMutableBufferPointer { tapBuffer in
                fourChannelOutput.withUnsafeMutableBufferPointer { outputBuffer in
                    withAudioBufferList([
                        AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(physicalBuffer.count * MemoryLayout<Float>.size), mData: physicalBuffer.baseAddress),
                        AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBuffer.count * MemoryLayout<Float>.size), mData: tapBuffer.baseAddress),
                    ]) { input in
                        withAudioBufferList([
                            AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(outputBuffer.count * MemoryLayout<Float>.size), mData: outputBuffer.baseAddress),
                        ]) { output in
                            routingEngine.render(input: input, output: output)
                        }
                    }
                }
            }
        }
        expect((0..<frames).allSatisfy { frame in
            let base = frame * 4
            return fourChannelOutput[base] == 0.25 && fourChannelOutput[base + 1] == -0.5
                && fourChannelOutput[base + 2] == 0.25 && fourChannelOutput[base + 3] == -0.5
        }, "render routes only selected tap stereo as L/R/L/R")
        expect(!fourChannelOutput.contains(99), "iD4 render never outputs physical sentinel")

        var disabledOutput = [Float](repeating: 0, count: frames * 4)
        tapInput.withUnsafeMutableBufferPointer { tapBuffer in
            disabledOutput.withUnsafeMutableBufferPointer { outputBuffer in
                withAudioBufferList([
                    AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(frames * 4 * MemoryLayout<Float>.size), mData: nil),
                    AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBuffer.count * MemoryLayout<Float>.size), mData: tapBuffer.baseAddress),
                ]) { input in
                    withAudioBufferList([
                        AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(outputBuffer.count * MemoryLayout<Float>.size), mData: outputBuffer.baseAddress),
                    ]) { output in
                        routingEngine.render(input: input, output: output)
                    }
                }
            }
        }
        expect(disabledOutput == fourChannelOutput, "disabled physical input with null data does not affect selected tap")

        let mismatchEngine = ProcessTapEngine(preparedInput: TapInputSelection(bufferIndex: 1, channels: 2))
        var mismatchOutput = [Float](repeating: 1, count: frames * 4)
        tapInput.withUnsafeMutableBufferPointer { tapBuffer in
            mismatchOutput.withUnsafeMutableBufferPointer { outputBuffer in
                withAudioBufferList([
                    AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(frames * 4 * MemoryLayout<Float>.size), mData: nil),
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(tapBuffer.count * MemoryLayout<Float>.size / 2), mData: tapBuffer.baseAddress),
                ]) { input in
                    withAudioBufferList([
                        AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(outputBuffer.count * MemoryLayout<Float>.size), mData: outputBuffer.baseAddress),
                    ]) { output in
                        mismatchEngine.render(input: input, output: output)
                    }
                }
            }
        }
        expect(mismatchOutput.allSatisfy { $0 == 0 }, "selected-buffer shape mismatch zeros output")

        let nullEngine = ProcessTapEngine(preparedInput: TapInputSelection(bufferIndex: 1, channels: 2))
        var nullOutput = [Float](repeating: 1, count: frames * 2)
        nullOutput.withUnsafeMutableBufferPointer { outputBuffer in
            withAudioBufferList([
                AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(frames * 4 * MemoryLayout<Float>.size), mData: nil),
                AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size), mData: nil),
            ]) { input in
                withAudioBufferList([
                    AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outputBuffer.count * MemoryLayout<Float>.size), mData: outputBuffer.baseAddress),
                ]) { output in
                    nullEngine.render(input: input, output: output)
                }
            }
        }
        expect(nullOutput.allSatisfy { $0 == 0 }, "null selected tap buffer zeros output")

        let missingEngine = ProcessTapEngine(preparedInput: TapInputSelection(bufferIndex: 2, channels: 2))
        var missingOutput = [Float](repeating: 1, count: frames * 2)
        tapInput.withUnsafeMutableBufferPointer { tapBuffer in
            missingOutput.withUnsafeMutableBufferPointer { outputBuffer in
                withAudioBufferList([
                    AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBuffer.count * MemoryLayout<Float>.size), mData: tapBuffer.baseAddress),
                ]) { input in
                    withAudioBufferList([
                        AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outputBuffer.count * MemoryLayout<Float>.size), mData: outputBuffer.baseAddress),
                    ]) { output in
                        missingEngine.render(input: input, output: output)
                    }
                }
            }
        }
        expect(missingOutput.allSatisfy { $0 == 0 }, "missing selected tap buffer zeros output")

        // Audio starting later in the buffer must still mark the tap as live.
        let lateEngine = ProcessTapEngine()
        var lateInput = [Float](repeating: 0, count: frames * channels)
        for frame in 100..<frames { lateInput[frame * channels] = 0.5 }
        var output = [Float](repeating: 0, count: frames * channels)
        renderOnce(lateEngine, channels: channels, input: &lateInput, output: &output)
        expect(lateEngine.hasReceivedAudio, "render detects audio past the first 64 frames")

        // After a full ring-out window of exact silence the output stays zeroed
        // and the tap is still not considered live.
        let engine = ProcessTapEngine()
        var silence = [Float](repeating: 0, count: frames * channels)
        for _ in 0...(Int(engine.processor.sampleRate) / frames + 1) {
            renderOnce(engine, channels: channels, input: &silence, output: &output)
        }
        var staleOutput = [Float](repeating: 0.7, count: frames * channels)
        renderOnce(engine, channels: channels, input: &silence, output: &staleOutput)
        expect(staleOutput.allSatisfy { $0 == 0 }, "silent input renders silent output after ring-out")
        expect(!engine.hasReceivedAudio, "pure silence never marks the tap as live")

        // Entering the idle path must discard filter/limiter history. Otherwise
        // stale state from a second earlier can leak into the first resumed buffer.
        let stateProcessor = EQProcessor()
        stateProcessor.configure(sampleRate: 48_000)
        stateProcessor.update(
            bands: [EQBand(type: .peak, frequency: 40, gain: 12, q: 20)],
            preampDB: 0, limiterEnabled: true, limiterCeilingDB: -1, bypassed: false
        )
        var primingTone = (0..<512).map { Float(sin(Double($0) * 2 * .pi * 40 / 48_000)) }
        primingTone.withUnsafeMutableBufferPointer {
            stateProcessor.process(channels: [$0.baseAddress!], frameCount: $0.count)
        }
        stateProcessor.resetRenderState()
        var resetSilence = [Float](repeating: 0, count: 512)
        resetSilence.withUnsafeMutableBufferPointer {
            stateProcessor.process(channels: [$0.baseAddress!], frameCount: $0.count)
        }
        expect(resetSilence.allSatisfy { $0 == 0 }, "silence gate clears realtime DSP history")

        // The first non-silent buffer after prolonged silence passes through
        // immediately (no dropout from the idle path).
        var tone = (0..<frames * channels).map {
            Float(0.5 * sin(Double($0 / channels) * 2 * .pi * 440 / 48000))
        }
        var resumed = [Float](repeating: 0, count: frames * channels)
        renderOnce(engine, channels: channels, input: &tone, output: &resumed)
        expect((resumed.map(abs).max() ?? 0) > 0.4, "audio resumes immediately after prolonged silence")
        expect(engine.hasReceivedAudio, "resumed audio marks the tap as live")
    }

    private static func appStateTests() {
        expect(
            BoostSlider.valueAfterScroll(50, deltaY: 1, isPrecise: false, maxPercent: 200) == 52,
            "volume mouse wheel uses two-percent steps"
        )
        expect(
            near(BoostSlider.valueAfterScroll(50, deltaY: 5, isPrecise: true, maxPercent: 200), 51),
            "volume trackpad scroll uses fine-grained steps"
        )
        expect(
            BoostSlider.valueAfterScroll(199, deltaY: 3, isPrecise: false, maxPercent: 200) == 200
                && BoostSlider.valueAfterScroll(1, deltaY: -3, isPrecise: false, maxPercent: 200) == 0,
            "volume scrolling clamps to its configured range"
        )

        expect(
            !AppState.shouldSuggestAudioAccessCheck(
                isEnabled: true,
                engineIsRunning: true,
                hasReceivedAudio: false,
                audioAccessConfirmed: true
            ),
            "confirmed audio access stays valid while playback is idle"
        )
        expect(
            AppState.shouldSuggestAudioAccessCheck(
                isEnabled: true,
                engineIsRunning: true,
                hasReceivedAudio: false,
                audioAccessConfirmed: false
            ),
            "unconfirmed running tap suggests an audio access check"
        )

        expect(
            AppState.topologyAction(
                isEnabled: true, engineIsRunning: true,
                engineTargetID: 41, defaultDeviceID: 52, defaultDeviceIsReady: true
            ) == .rebuild,
            "route rebuild follows engine target after UI device refresh"
        )
        expect(
            AppState.topologyAction(
                isEnabled: true, engineIsRunning: true,
                engineTargetID: 52, defaultDeviceID: 52, defaultDeviceIsReady: true
            ) == .none,
            "route rebuild skips matching engine target"
        )
        expect(
            AppState.topologyAction(
                isEnabled: false, engineIsRunning: true,
                engineTargetID: 41, defaultDeviceID: 52, defaultDeviceIsReady: true
            ) == .none,
            "disabled engine ignores route changes"
        )
        expect(
            AppState.topologyAction(
                isEnabled: true, engineIsRunning: true,
                engineTargetID: 41, defaultDeviceID: nil, defaultDeviceIsReady: false
            ) == .stop,
            "missing output tears down the muted tap"
        )
        expect(
            AppState.topologyAction(
                isEnabled: true, engineIsRunning: false,
                engineTargetID: 0, defaultDeviceID: nil, defaultDeviceIsReady: false
            ) == .none,
            "missing output leaves an already stopped engine alone"
        )
        expect(
            AppState.topologyAction(
                isEnabled: true, engineIsRunning: false,
                engineTargetID: 0, defaultDeviceID: 52, defaultDeviceIsReady: true
            ) == .rebuild,
            "restored output restarts a fail-safe stopped engine"
        )

        MainActor.assumeIsolated {
            AppState.screenshotMode = true  // no engine, no persistence
            let state = AppState.shared
            let savedPreset = state.preset
            let savedAuto = state.autoPreampEnabled
            let savedVolume = state.userVolumePercent
            defer {
                state.preset = savedPreset
                state.autoPreampEnabled = savedAuto
                state.userVolumePercent = savedVolume
            }

            var volumePublishes = 0
            let volumeSubscription = state.objectWillChange.sink { _ in volumePublishes += 1 }
            state.beginVolumeAdjustment()
            state.previewVolumeAdjustment(min(savedVolume + 1, state.maxBoostPercent))
            expect(volumePublishes == 0, "live volume preview does not invalidate the whole app")
            state.userVolumePercent = min(savedVolume + 1, state.maxBoostPercent)
            state.endVolumeAdjustment()
            expect(volumePublishes == 1, "finished volume adjustment publishes once")
            withExtendedLifetime(volumeSubscription) {}

            state.autoPreampEnabled = true
            state.preset = EQPreset(name: "Auto A", bands: [EQBand(type: .peak, frequency: 1000, gain: 5, q: 1.41)])
            expect(near(state.effectivePreampDB, -5, 0.1), "effective preamp follows auto preamp")
            expect(near(state.effectivePreampDB, state.effectivePreampDB), "repeated reads are stable")
            state.preset = EQPreset(name: "Auto B", bands: [EQBand(type: .peak, frequency: 1000, gain: 8, q: 1.41)])
            expect(near(state.effectivePreampDB, -8, 0.1), "effective preamp tracks band edits")

            state.autoPreampEnabled = false
            state.preset.preampDB = -3
            expect(state.effectivePreampDB == -3, "manual preamp used when auto is off")
        }
    }
}
