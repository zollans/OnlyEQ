import AppKit
import SwiftUI

/// `OnlyEQ --screenshots <dir>` — renders the app's own views into offscreen
/// windows and saves PNGs. Used to generate README screenshots; needs no
/// screen-recording permission because it never captures the actual screen.
@MainActor
enum ScreenshotRenderer {

    static func run(outputDir: String) -> Int32 {
        AppState.screenshotMode = true
        let state = AppState.shared
        state.engineState = .running
        state.refreshDevices()

        // Demo preset: the HD 650 AutoEq fixture.
        if let url = Bundle.module.url(forResource: "Fixtures/autoeq_parametric.txt", withExtension: nil),
           var demo = try? PresetImporter.importFile(at: url).preset {
            demo.name = "HD 650 · oratory1990"
            demo.source = "AutoEq"
            state.preset = demo
        }
        state.volumePercent = 65

        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var failures = 0
        failures += capture(
            canvas(PopoverView().environmentObject(state).frame(width: 360), panelRadius: 16),
            size: NSSize(width: 560, height: 620),
            to: dir.appendingPathComponent("popover.png")
        ) ? 0 : 1

        failures += capture(
            canvas(windowChrome(EditorView().environmentObject(state).frame(width: 840, height: 540)), panelRadius: 12),
            size: NSSize(width: 960, height: 680),
            to: dir.appendingPathComponent("editor.png")
        ) ? 0 : 1

        failures += capture(
            canvas(windowChrome(ImportSheet().environmentObject(state)), panelRadius: 12),
            size: NSSize(width: 720, height: 620),
            to: dir.appendingPathComponent("import.png")
        ) ? 0 : 1

        print(failures == 0 ? "Saved 3 screenshots to \(dir.path)" : "\(failures) screenshot(s) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Styling

    /// Gradient backdrop with the content floating on a shadowed panel.
    private static func canvas(_ content: some View, panelRadius: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.19, green: 0.20, blue: 0.24), Color(red: 0.10, green: 0.10, blue: 0.13)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            content
                .background(
                    RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                        .fill(Color(red: 0.115, green: 0.115, blue: 0.125))
                )
                .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
        }
    }

    /// Fake macOS title bar (traffic lights) above the content.
    private static func windowChrome(_ content: some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 1.0, green: 0.75, blue: 0.18)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 0.22, green: 0.78, blue: 0.25)).frame(width: 11, height: 11)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            content
        }
    }

    // MARK: - Offscreen capture

    /// Borderless windows refuse key status by default; controls in non-key
    /// windows draw untinted (gray switches), so allow it.
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// Render in a real NSWindow (positioned far off-screen, but key, so
    /// AppKit-backed controls draw with their active tint), then snapshot the
    /// view hierarchy at Retina scale.
    private static func capture(_ view: some View, size: NSSize, to url: URL) -> Bool {
        let window = KeyableWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: view.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height)
        )
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Let SwiftUI settle its layout and control states.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        window.contentView?.needsDisplay = true
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        // Off-screen windows render at 1x; build an explicit 2x rep for Retina.
        guard let contentView = window.contentView,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return false }
        rep.size = size
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            window.close()
            return true
        } catch {
            window.close()
            return false
        }
    }
}
