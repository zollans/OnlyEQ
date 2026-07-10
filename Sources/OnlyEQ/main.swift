import AppKit
import CoreAudio
import SwiftUI

if CommandLine.arguments.contains("--test") {
    exit(TestRunner.run())
}

if let flagIndex = CommandLine.arguments.firstIndex(of: "--screenshots") {
    let outputDir = CommandLine.arguments.indices.contains(flagIndex + 1)
        ? CommandLine.arguments[flagIndex + 1] : "screenshots"
    MainActor.assumeIsolated {
        // AppKit needs an initialized app to render controls offscreen, and
        // accessory policy lets the offscreen window become key (active tint).
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        exit(ScreenshotRenderer.run(outputDir: outputDir))
    }
}

// Opens the real editor view for a short, side-effect-free UI profiling run.
// The engine stays off; the process exits automatically after 15 seconds.
let editorProbe = CommandLine.arguments.contains("--editor-probe")
let profileSuggestionProbe = CommandLine.arguments.contains("--profile-suggestion-probe")
if editorProbe || profileSuggestionProbe {
    MainActor.assumeIsolated {
        AppState.screenshotMode = true
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()

        let state = AppState.shared
        state.engineState = .running
        state.editorIsVisible = true
        WindowManager.shared.showEditor(
            importing: profileSuggestionProbe,
            profileSuggestion: profileSuggestionProbe ? ProfileSuggestion(
                deviceUID: "probe.bluetooth.headphones",
                deviceName: "Aaron’s WH-1000XM5 Stereo",
                searchQuery: "WH-1000XM5"
            ) : nil
        )
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { app.terminate(nil) }
        app.run()
        exit(0)
    }
}

// Headless engine check: start the tap engine, report status as JSON, exit.
if CommandLine.arguments.contains("--engine-probe") {
    MainActor.assumeIsolated {
        let engine = ProcessTapEngine()
        engine.processor.update(bands: [], preampDB: 0, limiterEnabled: true, limiterCeilingDB: -1, bypassed: false)
        engine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let status: [String: Any] = [
                "state": "\(engine.state)",
                "hasReceivedAudio": engine.hasReceivedAudio,
                "sampleRate": engine.processor.sampleRate,
                "ioBufferFrames": engine.ioBufferFrames,
                "estimatedLatencyMs": engine.estimatedLatency * 1000,
                "defaultDevice": AudioDeviceManager.defaultOutputDeviceID().flatMap {
                    AudioDeviceManager.stringProperty($0, kAudioObjectPropertyName)
                } ?? "none",
                "outputDeviceCount": AudioDeviceManager.outputDevices().count,
            ]
            let data = try! JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            let wasRunning = engine.state == .running
            engine.stop()
            exit(wasRunning ? 0 : 1)
        }
        RunLoop.main.run()
    }
}

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--menu-panel-probe") {
        AppState.screenshotMode = true
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
