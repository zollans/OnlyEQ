import AppKit
import SwiftUI
import CoreAudio
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("app: didFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        let state = AppState.shared
        state.onProfileSuggestion = { suggestion in
            WindowManager.shared.showEditor(importing: true, profileSuggestion: suggestion)
        }
        Log.write("app: state ready")

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView().environmentObject(state))
        // PopoverView has a stable frame, so size the popover once. Continuously
        // publishing preferredContentSize makes every spectrum tick remeasure
        // and lay out the entire popover instead of redrawing just its Canvas.
        hosting.sizingOptions = .standardBounds
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
        AppState.shared.flushWorkingPresetPersistence()
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
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
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
    @objc private func checkForUpdates() { updaterController.checkForUpdates(nil) }
}

// Closing the popover only orders its window out — the hosting controller
// (and the SwiftUI tree inside) stays alive, so PopoverView gates its
// spectrum animation on this visibility flag to stop it from refreshing
// forever after the first show.
extension AppDelegate: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        AppState.shared.popoverIsVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        AppState.shared.popoverIsVisible = false
    }
}

/// Owns the editor, settings, and onboarding windows.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var editorWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func showEditor(importing: Bool = false, profileSuggestion: ProfileSuggestion? = nil) {
        let isCreatingWindow = editorWindow == nil
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
                rootView: EditorView(initialImportRequested: importing,
                                     initialProfileSuggestion: profileSuggestion)
                    .environmentObject(AppState.shared)
            )
            // Restore the saved frame if there is one; otherwise center.
            if !window.setFrameUsingName("EditorWindow") { window.center() }
            window.setFrameAutosaveName("EditorWindow")
            // The window survives close (isReleasedWhenClosed = false, just
            // ordered out), so EditorView gates its spectrum/clip refresh work
            // on real visibility. Occlusion state also covers "fully covered
            // by another window" and "on another Space", not just close.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { note in
                guard let window = note.object as? NSWindow else { return }
                let visible = window.occlusionState.contains(.visible)
                Task { @MainActor in AppState.shared.editorIsVisible = visible }
            }
            editorWindow = window
        }
        if let editorWindow { focus(editorWindow) }
        if importing, !isCreatingWindow {
            EditorView.importRequested.send(profileSuggestion)
        }
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
        if let settingsWindow { focus(settingsWindow) }
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
        if let onboardingWindow { focus(onboardingWindow) }
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    /// Accessory/menu-bar apps must activate before asking a window to become
    /// key. Retry on the next run-loop turn because a closing transient popover
    /// can otherwise return focus to the previous application.
    private func focus(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            if !NSApp.isActive || !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
