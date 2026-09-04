import AppKit

/// Accessory applications have no active main-menu command chain. Route
/// standard window and editing shortcuts explicitly so OnlyEQ behaves like a
/// normal Mac app while remaining a menu-bar accessory.
@MainActor
final class AppShortcutMonitor {
    private var eventMonitor: Any?

    func start() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Like NSMenu, match the layout's own character first and the
            // Command-layer Latin fallback second, so Cmd-V works on
            // Cyrillic, Greek, or Hebrew layouts where the key yields "м".
            let candidates = [event.charactersIgnoringModifiers, event.characters]
            let modifiers = event.modifierFlags
            if candidates.contains(where: { Self.isCloseWindowShortcut(characters: $0, modifiers: modifiers) }) {
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                      window.styleMask.contains(.closable) else { return event }
                window.performClose(nil)
                return nil
            }

            guard let action = candidates.lazy.compactMap({ Self.editingAction(characters: $0, modifiers: modifiers) }).first,
                  let responder = NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder,
                  responder.tryToPerform(action, with: nil) else {
                return event
            }
            return nil
        }
    }

    func stop() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    nonisolated static func isCloseWindowShortcut(
        characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        normalizedModifiers(modifiers) == .command && characters?.lowercased() == "w"
    }

    nonisolated static func editingAction(
        characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> Selector? {
        let flags = normalizedModifiers(modifiers)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
              let character = characters?.lowercased() else { return nil }

        switch (character, flags.contains(.shift)) {
        case ("a", false): return #selector(NSText.selectAll(_:))
        case ("x", false): return #selector(NSText.cut(_:))
        case ("c", false): return #selector(NSText.copy(_:))
        case ("v", false): return #selector(NSText.paste(_:))
        case ("z", false): return Selector(("undo:"))
        case ("z", true): return Selector(("redo:"))
        default: return nil
        }
    }

    private nonisolated static func normalizedModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifiers.intersection([.command, .shift, .option, .control])
    }
}
