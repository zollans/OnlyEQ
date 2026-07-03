import AppKit
import SwiftUI
import CoreAudio

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("app: didFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        let state = AppState.shared
        Log.write("app: state ready")

        popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: PopoverView().environmentObject(state))
        // Keep preferredContentSize in sync with the SwiftUI layout — without
        // this the popover mis-sizes and can render clipped past the menu bar.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        Log.write("app: popover ready")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "OnlyEQ")
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        Log.write("app: status item ready (visible: \(statusItem.isVisible))")

        HotKeyManager.shared.install()

        if !UserDefaults.standard.bool(forKey: "onboarded") {
            WindowManager.shared.showOnboarding()
            Log.write("app: onboarding shown")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.engine.stop()
    }

    // MARK: - Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            AppState.shared.refreshDevices()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu() {
        let state = AppState.shared
        let menu = NSMenu()

        let statusLine = NSMenuItem(title: state.isEnabled ? "OnlyEQ: Active" : "OnlyEQ: Inactive", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let enable = NSMenuItem(title: "Enable EQ", action: #selector(toggleEnabled), keyEquivalent: "")
        enable.target = self
        enable.state = state.isEnabled ? .on : .off
        menu.addItem(enable)
        menu.addItem(.separator())

        // Preset submenu.
        let presetItem = NSMenuItem(title: "Preset", action: nil, keyEquivalent: "")
        let presetMenu = NSMenu()
        for preset in state.store.allPresets {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = preset.id == state.preset.id ? .on : .off
            presetMenu.addItem(item)
        }
        presetMenu.addItem(.separator())
        let importItem = NSMenuItem(title: "Import…", action: #selector(openImport), keyEquivalent: "")
        importItem.target = self
        presetMenu.addItem(importItem)
        presetItem.submenu = presetMenu
        menu.addItem(presetItem)

        // Output device submenu.
        let deviceItem = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        let deviceMenu = NSMenu()
        for device in state.devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == state.currentDevice?.id ? .on : .off
            deviceMenu.addItem(item)
        }
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)
        menu.addItem(.separator())

        let editor = NSMenuItem(title: "Open Editor…", action: #selector(openEditor), keyEquivalent: "")
        editor.target = self
        menu.addItem(editor)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OnlyEQ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // restore click handling
    }

    // MARK: - Menu actions

    @objc private func toggleEnabled() { AppState.shared.isEnabled.toggle() }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let preset = AppState.shared.store.preset(withID: id) else { return }
        AppState.shared.apply(preset)
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioObjectID,
              let device = AppState.shared.devices.first(where: { $0.id == id }) else { return }
        AppState.shared.selectOutputDevice(device)
    }

    @objc private func openEditor() { WindowManager.shared.showEditor() }
    @objc private func openImport() { WindowManager.shared.showEditor(importing: true) }
    @objc private func openSettings() { WindowManager.shared.showSettings() }
}

/// Owns the editor, settings, and onboarding windows.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var editorWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func showEditor(importing: Bool = false) {
        if editorWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "OnlyEQ"
            window.minSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: EditorView().environmentObject(AppState.shared)
            )
            // Restore the saved frame if there is one; otherwise center.
            if !window.setFrameUsingName("EditorWindow") { window.center() }
            window.setFrameAutosaveName("EditorWindow")
            editorWindow = window
        }
        if importing { EditorView.importRequested.send() }
        editorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "OnlyEQ Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView().environmentObject(AppState.shared)
            )
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "OnlyEQ"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: OnboardingView().environmentObject(AppState.shared)
            )
            window.center()
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }
}
