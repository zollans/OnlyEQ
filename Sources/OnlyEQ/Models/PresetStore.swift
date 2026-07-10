import Foundation

/// Persists custom presets and per-device profiles as JSON files in
/// ~/Library/Application Support/OnlyEQ/.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var customPresets: [EQPreset] = []
    @Published var deviceProfiles: [String: DeviceProfile] = [:]  // keyed by device UID

    /// Working (possibly unsaved) EQ state per device UID, stashed on output
    /// switches so returning to a device restores manual edits instead of
    /// discarding them.
    private var workingPresets: [String: EQPreset] = [:]

    private let directory: URL
    private var presetsURL: URL { directory.appendingPathComponent("presets.json") }
    private var profilesURL: URL { directory.appendingPathComponent("profiles.json") }
    private var workingURL: URL { directory.appendingPathComponent("working-presets.json") }

    var allPresets: [EQPreset] { EQPreset.builtIns + customPresets }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnlyEQ", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    func preset(withID id: UUID?) -> EQPreset? {
        guard let id else { return nil }
        return allPresets.first { $0.id == id }
    }

    /// Resolve a device profile's preset: by ID first, then by name — profiles
    /// saved before built-ins had stable IDs reference UUIDs that no longer exist.
    func resolveProfilePreset(_ profile: DeviceProfile) -> EQPreset? {
        if let byID = preset(withID: profile.presetID) { return byID }
        guard let name = profile.presetName else { return nil }
        return allPresets.first { $0.name == name }
    }

    func save(_ preset: EQPreset) {
        if let i = customPresets.firstIndex(where: { $0.id == preset.id }) {
            customPresets[i] = preset
        } else if let i = customPresets.firstIndex(where: { $0.name == preset.name }) {
            var updated = preset
            updated.id = customPresets[i].id
            customPresets[i] = updated
        } else {
            customPresets.append(preset)
        }
        persist()
    }

    func delete(_ preset: EQPreset) {
        customPresets.removeAll { $0.id == preset.id }
        for (uid, profile) in deviceProfiles where profile.presetID == preset.id {
            deviceProfiles[uid]?.presetID = nil
            deviceProfiles[uid]?.presetName = nil
        }
        persist()
    }

    func stashWorkingPreset(_ preset: EQPreset, forDevice uid: String) {
        guard workingPresets[uid] != preset else { return }
        workingPresets[uid] = preset
        persistWorkingPresets()
    }

    func workingPreset(forDevice uid: String) -> EQPreset? {
        workingPresets[uid]
    }

    func setProfile(deviceUID: String, deviceName: String, preset: EQPreset?, autoApply: Bool = true) {
        deviceProfiles[deviceUID] = DeviceProfile(
            deviceUID: deviceUID, deviceName: deviceName,
            presetID: preset?.id, presetName: preset?.name, autoApply: autoApply
        )
        persist()
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: presetsURL),
           let presets = try? JSONDecoder().decode([EQPreset].self, from: data) {
            customPresets = presets
        }
        if let data = try? Data(contentsOf: profilesURL),
           let profiles = try? JSONDecoder().decode([String: DeviceProfile].self, from: data) {
            deviceProfiles = profiles
        }
        if let data = try? Data(contentsOf: workingURL),
           let working = try? JSONDecoder().decode([String: EQPreset].self, from: data) {
            workingPresets = working
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(customPresets).write(to: presetsURL, options: .atomic)
        try? encoder.encode(deviceProfiles).write(to: profilesURL, options: .atomic)
        try? encoder.encode(workingPresets).write(to: workingURL, options: .atomic)
    }

    private func persistWorkingPresets() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(workingPresets).write(to: workingURL, options: .atomic)
    }
}
