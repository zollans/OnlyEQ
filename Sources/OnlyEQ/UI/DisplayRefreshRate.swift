import AppKit
import QuartzCore

/// Keeps interactive UI work synchronized with the display that owns the
/// active window. A 120 Hz ProMotion screen gets 120 Hz presentation while a
/// conventional screen remains at 60 Hz.
@MainActor
enum DisplayRefreshRate {
    static func maximum(for window: NSWindow? = nil) -> Double {
        let screen = window?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        return Double(max(screen?.maximumFramesPerSecond ?? 60, 1))
    }

    static func interval(for window: NSWindow? = nil) -> TimeInterval {
        1.0 / maximum(for: window)
    }

    static func configure(_ link: CADisplayLink, for window: NSWindow?) {
        // Allow the fastest connected display. The NSView-owned display link
        // is still physically paced by its current screen, so a 60 Hz screen
        // receives 60 callbacks while moving to ProMotion can reach 120 Hz
        // without recreating the link.
        let connectedMaximum = NSScreen.screens.map(\.maximumFramesPerSecond).max()
        let maximum = Float(max(connectedMaximum ?? Int(maximum(for: window)), 1))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximum), maximum: maximum, preferred: maximum
        )
    }
}
