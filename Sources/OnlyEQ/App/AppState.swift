import Foundation
import CoreAudio
import SwiftUI
import Combine

/// Central observable state: owns the engine, presets, devices, and settings.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Set before first `shared` access by the --screenshots CLI mode: skips
    /// the engine, hardware volume writes, and persistence so rendering the
    /// UI has no side effects on the running app or the user's settings.
    static var screenshotMode = false

    let engine = ProcessTapEngine()
    let store = PresetStore()
    let onlineDB = OnlineDatabase()
    private let hardwareVolumeWriter = HardwareVolumeWriter()

    /// Installed by the app delegate so device detection can request UI without
    /// coupling the audio/state layer to a particular window implementation.
    var onProfileSuggestion: ((ProfileSuggestion) -> Void)?

    // MARK: - Published state

    @Published var isEnabled: Bool = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "enabled")
            rebuildEngine()
            updateVisualizationState()
        }
    }

    /// The working EQ (live-editable; may be an unsaved copy of a preset).
    @Published var preset: EQPreset = .flat {
        didSet { pushToProcessor(); persistWorkingPreset() }
    }

    @Published var bypassed = false { didSet { pushToProcessor() } }
    @Published var autoPreampEnabled = UserDefaults.standard.object(forKey: "autoPreamp") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPreampEnabled, forKey: "autoPreamp"); pushToProcessor() }
    }
    @Published var limiterEnabled = UserDefaults.standard.object(forKey: "limiter") as? Bool ?? true {
        didSet { UserDefaults.standard.set(limiterEnabled, forKey: "limiter"); pushToProcessor() }
    }
    @Published var limiterCeilingDB = UserDefaults.standard.object(forKey: "limiterCeiling") as? Double ?? -1.0 {
        didSet { UserDefaults.standard.set(limiterCeilingDB, forKey: "limiterCeiling"); pushToProcessor() }
    }

    /// Volume as 0…maxBoost percent. ≤100 uses hardware volume when available;
    /// the portion above 100 % (or everything, for HDMI-style outputs) is software gain.
    @Published var volumePercent: Double = 100 { didSet { applyVolume() } }
    @Published var maxBoostPercent: Double = UserDefaults.standard.object(forKey: "maxBoost") as? Double ?? 200 {
        didSet { UserDefaults.standard.set(maxBoostPercent, forKey: "maxBoost") }
    }

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var currentDevice: AudioOutputDevice?
    @Published var engineState: ProcessTapEngine.State = .stopped

    /// True when the engine runs but has never seen a sample — the strongest
    /// signal we have that System Audio Recording permission is missing.
    @Published private(set) var suspectedPermissionIssue = false

    @Published var excludedBundleIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "excludedApps") ?? ["com.apple.garageband10", "us.zoom.xos"]) {
        didSet { UserDefaults.standard.set(Array(excludedBundleIDs), forKey: "excludedApps"); rebuildEngine() }
    }

    @Published var bufferFrames: Int = UserDefaults.standard.object(forKey: "bufferFrames") as? Int ?? 256 {
        didSet { UserDefaults.standard.set(bufferFrames, forKey: "bufferFrames"); engine.setIOBufferFrames(bufferFrames) }
    }

    @Published var autoSuggestHeadphoneProfiles: Bool = UserDefaults.standard.object(forKey: "autoSuggestHeadphoneProfiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSuggestHeadphoneProfiles, forKey: "autoSuggestHeadphoneProfiles") }
    }

    /// A/B comparison slots.
    @Published var abSlot: Int = 0
    private var abPresets: [EQPreset?] = [nil, nil]

    /// Set when the current preset was auto-applied by a device profile.
    @Published private(set) var presetWasAutoApplied = false

    /// True only while the popover / editor window is actually on screen.
    /// The popover's content controller and the editor window both outlive
    /// their close (they're just ordered out), so spectrum/meter animations
    /// gate on these to stop ticking once nothing is visible.
    @Published var popoverIsVisible = false { didSet { updateVisualizationState() } }
    @Published var editorIsVisible = false { didSet { updateVisualizationState() } }

    /// autoPreamp scans a 512-point response curve; during a band drag this is
    /// read ~120×/s with unchanged bands, so memoize on the band values.
    private var autoPreampCache: (bands: [EQBand], sampleRate: Double, value: Double)?

    var effectivePreampDB: Double {
        guard autoPreampEnabled else { return preset.preampDB }
        let sampleRate = engine.processor.sampleRate
        if let cache = autoPreampCache,
           cache.bands == preset.bands, cache.sampleRate == sampleRate { return cache.value }
        let value = EQResponse.autoPreamp(bands: preset.bands, sampleRate: sampleRate)
        autoPreampCache = (preset.bands, sampleRate, value)
        return value
    }

    var latencyMilliseconds: Int { Int((engine.estimatedLatency * 1000).rounded()) }

    private var deviceListenerInstalled = false
    private var silenceCheckTimer: Timer?
    private var pendingPresetPersistence: DispatchWorkItem?
    private var pendingPresetSnapshot: (deviceUID: String, preset: EQPreset)?
    private var isRestoringWorkingPreset = false
    private var sampleRateRebuildScheduled = false
    private var suggestedDeviceUIDs = Set(UserDefaults.standard.stringArray(forKey: "profileSuggestion.seenDeviceUIDs") ?? [])
    private var currentDeviceHasHardwareVolume = false
    private var lastPushedSoftwareGainDB = Double.nan
    private struct HardwareVolumeListener {
        let deviceID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var hardwareVolumeListeners: [HardwareVolumeListener] = []
    private var observedVolumeDeviceID: AudioObjectID = 0

    /// Sticky per-session flag: once the tap has delivered audio we know the
    /// permission is granted, so engine restarts (device switches, settings
    /// changes) while playback is paused must not re-raise the banner.
    private var audioConfirmedThisSession = false

    // MARK: - Setup

    private init() {
        refreshDevices()
        restoreWorkingPresetForCurrentDevice(migrateLegacyPreset: true)
        installDeviceListeners()
        engine.onStateChange = { [weak self] state in
            Task { @MainActor in self?.engineState = state }
        }
        // A nominal sample-rate change (Bluetooth codec renegotiation, Audio
        // MIDI Setup) invalidates the biquad coefficients; rebuild everything
        // at the new rate.
        engine.onSampleRateChange = { [weak self] in
            Task { @MainActor in self?.scheduleSampleRateRebuild() }
        }
        rebuildEngine()
        startSilenceWatchdog()
    }

    // MARK: - Engine control

    func rebuildEngine() {
        guard !Self.screenshotMode else { return }
        if isEnabled {
            engine.start(excludedBundleIDs: excludedBundleIDs)
            engine.setIOBufferFrames(bufferFrames)
            pushToProcessor()
            applyVolume()
        } else {
            engine.stop()
        }
        refreshDevices()
    }

    private func scheduleSampleRateRebuild() {
        guard !sampleRateRebuildScheduled else { return }
        sampleRateRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleRateRebuildScheduled = false
            let deviceID = self.engine.targetDeviceID
            guard self.isEnabled, self.engine.state == .running, deviceID != 0,
                  AudioDeviceManager.nominalSampleRate(deviceID) != self.engine.processor.sampleRate else { return }
            self.rebuildEngine()
        }
    }

    private func pushToProcessor() {
        let outputGainDB = softwareGainDB
        engine.processor.update(
            bands: preset.bands,
            preampDB: effectivePreampDB,
            outputGainDB: outputGainDB,
            limiterEnabled: limiterEnabled,
            limiterCeilingDB: limiterCeilingDB,
            bypassed: bypassed || !isEnabled
        )
        lastPushedSoftwareGainDB = outputGainDB
    }

    /// Keep visualization work off the realtime thread unless a consumer is
    /// actually on screen. The editor alone owns the peak meter; either visible
    /// surface can consume spectrum samples.
    private func updateVisualizationState() {
        engine.spectrum.setActive(isEnabled && (popoverIsVisible || editorIsVisible))
        engine.processor.setMeteringActive(isEnabled && editorIsVisible)
    }

    private func startSilenceWatchdog() {
        guard !Self.screenshotMode else { return }
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.silenceWatchdogTick() }
        }
        silenceCheckTimer?.tolerance = 1
    }

    func silenceWatchdogTick() {
        if engine.hasReceivedAudio { audioConfirmedThisSession = true }
        let suspected = isEnabled
            && engineState == .running
            && !engine.hasReceivedAudio
            && !audioConfirmedThisSession
        // @Published republishes unchanged values, and every publish re-layouts
        // each alive (hidden) window's SwiftUI tree — a visible CPU blip per tick.
        if suspected != suspectedPermissionIssue { suspectedPermissionIssue = suspected }
    }

    // MARK: - Devices

    func refreshDevices() {
        devices = AudioDeviceManager.outputDevices()
        if let defaultID = AudioDeviceManager.defaultOutputDeviceID() {
            currentDevice = devices.first { $0.id == defaultID }
        } else {
            currentDevice = nil
        }
        updateHardwareVolumeListeners()
        syncVolumeFromDevice()
    }

    func selectOutputDevice(_ device: AudioOutputDevice) {
        AudioDeviceManager.setDefaultOutputDevice(device.id)
        // The default-device listener restarts the engine and applies the profile.
    }

    func cycleOutputDevice() {
        guard !devices.isEmpty else { return }
        let idx = devices.firstIndex { $0.id == currentDevice?.id } ?? -1
        selectOutputDevice(devices[(idx + 1) % devices.count])
    }

    private func installDeviceListeners() {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true

        var defaultAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main) { [weak self] _, _ in
            Task { @MainActor in self?.handleDefaultDeviceChanged() }
        }

        var listAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddr, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    private func updateHardwareVolumeListeners() {
        guard !Self.screenshotMode else { return }
        let deviceID = currentDevice?.id ?? 0
        guard deviceID != observedVolumeDeviceID else { return }

        for listener in hardwareVolumeListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                listener.deviceID, &address, .main, listener.block
            )
        }
        hardwareVolumeListeners.removeAll(keepingCapacity: true)
        observedVolumeDeviceID = deviceID
        guard deviceID != 0 else { return }

        for var address in AudioDeviceManager.hardwareVolumeAddresses(deviceID) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.currentDevice?.id == deviceID else { return }
                    self.syncVolumeFromDevice(externalChange: true)
                }
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
                hardwareVolumeListeners.append(
                    HardwareVolumeListener(deviceID: deviceID, address: address, block: block)
                )
            }
        }
    }

    private func handleDefaultDeviceChanged() {
        let previousID = currentDevice?.id
        let previousUID = currentDevice?.uid
        // Commit the outgoing device snapshot before refresh changes the UID
        // that future edits belong to.
        flushWorkingPresetPersistence()
        refreshDevices()
        if isEnabled, previousID != currentDevice?.id { rebuildEngine() }
        if previousUID != currentDevice?.uid {
            restoreWorkingPresetForCurrentDevice()
            suggestProfileForCurrentDeviceIfNeeded()
        }
    }

    private func suggestProfileForCurrentDeviceIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "onboarded"),
              autoSuggestHeadphoneProfiles,
              let device = currentDevice,
              device.isBluetooth,
              store.deviceProfiles[device.uid] == nil,
              !suggestedDeviceUIDs.contains(device.uid),
              let onProfileSuggestion else { return }

        let query = HeadphoneNameMatcher.searchQuery(for: device.name)
        guard !query.isEmpty else { return }
        suggestedDeviceUIDs.insert(device.uid)
        UserDefaults.standard.set(Array(suggestedDeviceUIDs), forKey: "profileSuggestion.seenDeviceUIDs")
        onProfileSuggestion(ProfileSuggestion(deviceUID: device.uid, deviceName: device.name,
                                              searchQuery: query))
    }

    private func restoreWorkingPresetForCurrentDevice(migrateLegacyPreset: Bool = false) {
        guard !Self.screenshotMode else { return }
        guard let device = currentDevice else { return }
        let restored: EQPreset
        let wasAutoApplied: Bool
        if let working = store.workingPreset(forDevice: device.uid) {
            restored = working
            wasAutoApplied = false
        } else if migrateLegacyPreset,
                  let data = UserDefaults.standard.data(forKey: "workingPreset"),
                  let legacy = try? JSONDecoder().decode(EQPreset.self, from: data) {
            // Build 14 and earlier stored one global snapshot. Associate it
            // with the device active during the one-time migration.
            restored = legacy
            wasAutoApplied = false
            store.stashWorkingPreset(legacy, forDevice: device.uid)
            UserDefaults.standard.removeObject(forKey: "workingPreset")
        } else if let profile = store.deviceProfiles[device.uid], profile.autoApply,
                  let saved = store.resolveProfilePreset(profile) {
            restored = saved
            wasAutoApplied = true
        } else {
            // Never carry a headphone correction curve onto another output.
            restored = .flat
            wasAutoApplied = true
        }
        isRestoringWorkingPreset = true
        preset = restored
        isRestoringWorkingPreset = false
        presetWasAutoApplied = wasAutoApplied
    }

    // MARK: - Presets

    func apply(_ newPreset: EQPreset, autoApplied: Bool = false) {
        preset = newPreset
        presetWasAutoApplied = autoApplied
        if !autoApplied, let device = currentDevice {
            store.setProfile(deviceUID: device.uid, deviceName: device.name, preset: newPreset,
                             autoApply: store.deviceProfiles[device.uid]?.autoApply ?? true)
        }
    }

    func applyFlat() { apply(.flat) }

    func saveCurrentAsPreset(named name: String) {
        var toSave = preset
        toSave.id = UUID()
        toSave.name = name
        store.save(toSave)
        preset = toSave
        presetWasAutoApplied = false
    }

    func assignSuggestedPreset(_ preset: EQPreset, to suggestion: ProfileSuggestion) {
        store.save(preset)
        store.setProfile(deviceUID: suggestion.deviceUID, deviceName: suggestion.deviceName,
                         preset: preset, autoApply: true)
        // An explicit assignment beats whatever working state was stashed for
        // the device — otherwise the stash would shadow it on next connect.
        store.stashWorkingPreset(preset, forDevice: suggestion.deviceUID)
        if currentDevice?.uid == suggestion.deviceUID {
            self.preset = preset
            presetWasAutoApplied = true
        }
    }

    // MARK: - A/B

    func storeABAndSwitch(to slot: Int) {
        abPresets[abSlot] = preset
        abSlot = slot
        if let other = abPresets[slot] { preset = other }
    }

    // MARK: - Volume

    private var softwareGainDB: Double {
        let percent = max(volumePercent, 1)
        if hasHardwareVolume {
            return percent > 100 ? 20 * log10(percent / 100) : 0
        }
        return 20 * log10(percent / 100)
    }

    private var hasHardwareVolume: Bool {
        currentDeviceHasHardwareVolume
    }

    private func applyVolume() {
        guard !Self.screenshotMode, let device = currentDevice else { return }
        if hasHardwareVolume {
            hardwareVolumeWriter.submit(deviceID: device.id,
                                        volume: Float(min(volumePercent, 100) / 100))
        }
        let outputGainDB = softwareGainDB
        if !outputGainDB.isApproximatelyEqual(to: lastPushedSoftwareGainDB) {
            pushToProcessor()
        }
    }

    private func syncVolumeFromDevice(externalChange: Bool = false) {
        guard let device = currentDevice else {
            currentDeviceHasHardwareVolume = false
            return
        }
        guard let hw = AudioDeviceManager.hardwareVolume(device.id) else {
            currentDeviceHasHardwareVolume = false
            return
        }
        currentDeviceHasHardwareVolume = true
        // Preserve intentional software boost during routine refreshes. A real
        // hardware-volume event is an explicit user adjustment, so reflect it
        // even when the UI was previously above 100%.
        if externalChange || volumePercent <= 100 {
            let percent = Double(hw) * 100
            if abs(percent - volumePercent) > 0.5 {
                if externalChange { Log.write("volume: external \(percent.rounded())%") }
                volumePercent = percent
            }
        }
    }

    // MARK: - Working preset persistence

    private func persistWorkingPreset() {
        guard !Self.screenshotMode, !isRestoringWorkingPreset,
              let deviceUID = currentDevice?.uid else { return }
        pendingPresetPersistence?.cancel()
        let snapshot = preset
        pendingPresetSnapshot = (deviceUID, snapshot)
        let work = DispatchWorkItem { [weak self] in
            self?.store.stashWorkingPreset(snapshot, forDevice: deviceUID)
        }
        pendingPresetPersistence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Dragging can publish many preset snapshots per second. Persist only the
    /// final value, and expose an explicit flush for drag-end and app shutdown.
    func flushWorkingPresetPersistence() {
        guard !Self.screenshotMode else { return }
        pendingPresetPersistence?.cancel()
        pendingPresetPersistence = nil
        if let pendingPresetSnapshot {
            store.stashWorkingPreset(pendingPresetSnapshot.preset,
                                     forDevice: pendingPresetSnapshot.deviceUID)
            self.pendingPresetSnapshot = nil
        } else if let deviceUID = currentDevice?.uid {
            store.stashWorkingPreset(preset, forDevice: deviceUID)
        }
    }
}

private extension Double {
    func isApproximatelyEqual(to other: Double) -> Bool {
        isFinite && other.isFinite && abs(self - other) < 0.000_001
    }
}
