import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (no accessibility permission
/// needed). Fixed default chords, individually toggleable in Settings.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    enum Action: UInt32, CaseIterable, Identifiable {
        case toggleEQ = 1
        case cycleOutput = 2
        case nextPreset = 3
        case flat = 4

        var id: UInt32 { rawValue }

        var title: String {
            switch self {
            case .toggleEQ: "Toggle EQ"
            case .cycleOutput: "Cycle output device"
            case .nextPreset: "Next preset"
            case .flat: "Flat / bypass"
            }
        }

        var chordDescription: String {
            switch self {
            case .toggleEQ: "⌥ ⌘ E"
            case .cycleOutput: "⌃ ⌥ ⌘ O"
            case .nextPreset: "⌘ ]"
            case .flat: "⌘ \\"
            }
        }

        var keyCode: UInt32 {
            switch self {
            case .toggleEQ: UInt32(kVK_ANSI_E)
            case .cycleOutput: UInt32(kVK_ANSI_O)
            case .nextPreset: UInt32(kVK_ANSI_RightBracket)
            case .flat: UInt32(kVK_ANSI_Backslash)
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .toggleEQ: UInt32(optionKey | cmdKey)
            case .cycleOutput: UInt32(controlKey | optionKey | cmdKey)
            case .nextPreset: UInt32(cmdKey)
            case .flat: UInt32(cmdKey)
            }
        }

        var defaultsKey: String { "hotkey.\(rawValue)" }
    }

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    func install() {
        if !handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                Task { @MainActor in
                    HotKeyManager.shared.handle(id: hotKeyID.id)
                }
                return noErr
            }, 1, &eventType, nil, nil)
            handlerInstalled = true
        }
        for action in Action.allCases where isEnabled(action) {
            register(action)
        }
    }

    func isEnabled(_ action: Action) -> Bool {
        UserDefaults.standard.object(forKey: action.defaultsKey) as? Bool ?? (action == .toggleEQ || action == .cycleOutput)
    }

    func setEnabled(_ action: Action, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: action.defaultsKey)
        if enabled { register(action) } else { unregister(action) }
    }

    private func register(_ action: Action) {
        guard hotKeyRefs[action.rawValue] == nil else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F455121 /* 'OEQ!' */), id: action.rawValue)
        if RegisterEventHotKey(action.keyCode, action.modifiers, hotKeyID,
                               GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            hotKeyRefs[action.rawValue] = ref
        }
    }

    private func unregister(_ action: Action) {
        if let ref = hotKeyRefs.removeValue(forKey: action.rawValue) {
            UnregisterEventHotKey(ref)
        }
    }

    private func handle(id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        let state = AppState.shared
        switch action {
        case .toggleEQ:
            state.isEnabled.toggle()
        case .cycleOutput:
            state.cycleOutputDevice()
        case .nextPreset:
            let all = state.store.allPresets
            guard !all.isEmpty else { return }
            let idx = all.firstIndex { $0.id == state.preset.id } ?? -1
            state.apply(all[(idx + 1) % all.count])
        case .flat:
            state.applyFlat()
        }
    }
}
