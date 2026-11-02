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

    /// Saves the preset and returns the stored value. Saving under an existing
    /// name replaces that preset and keeps its id, so callers must use the
    /// returned preset rather than the one they passed in.
    @discardableResult
    func save(_ preset: EQPreset) -> EQPreset {
        var stored = preset
        if let i = customPresets.firstIndex(where: { $0.id == preset.id }) {
            customPresets[i] = preset
        } else if let i = customPresets.firstIndex(where: { $0.name == preset.name }) {
            stored.id = customPresets[i].id
            customPresets[i] = stored
        } else {
            customPresets.append(preset)
        }
        persist()
        return stored
    }

    func delete(_ preset: EQPreset) {
        customPresets.removeAll { $0.id == preset.id }
        for (uid, profile) in deviceProfiles where profile.presetID == preset.id {
            deviceProfiles[uid]?.presetID = nil
            deviceProfiles[uid]?.presetName = nil
        }
        persist()
    }

    func removeAll() {
        customPresets = []
        deviceProfiles = [:]
        workingPresets = [:]
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
        if let presets: [EQPreset] = loadFile(presetsURL) { customPresets = presets }
        if let profiles: [String: DeviceProfile] = loadFile(profilesURL) { deviceProfiles = profiles }
        if let working: [String: EQPreset] = loadFile(workingURL) { workingPresets = working }
    }

    /// A missing file is normal (first launch). A file that exists but does
    /// not decode is moved aside so the next persist() cannot overwrite it
    /// with the empty in-memory state.
    private func loadFile<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            Log.write("PresetStore: could not decode \(url.lastPathComponent), moved to \(backup.lastPathComponent): \(error)")
            return nil
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
