import Foundation
import CoreAudio
import AppKit

struct AudioOutputDevice: Identifiable, Hashable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var transportType: UInt32

    var icon: String {
        // The device name is a better signal than the transport (e.g. the
        // 3.5 mm jack reports transport "built-in" but is named "External Headphones").
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("headphone") || lower.contains("buds") || lower.contains("wh-") || lower.contains("headset") {
            return "headphones"
        }
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return "tv"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return "hifispeaker"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        default:
            return "speaker.wave.2"
        }
    }

    /// HDMI/DisplayPort outputs generally have no hardware volume control.
    var likelyNoHardwareVolume: Bool {
        transportType == kAudioDeviceTransportTypeHDMI || transportType == kAudioDeviceTransportTypeDisplayPort
    }
}

/// Core Audio device enumeration, default-device control, and volume.
enum AudioDeviceManager {

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func outputDevices() -> [AudioOutputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard outputChannelCount(id) > 0 else { return nil }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            // Skip private/virtual aggregates (including our own).
            if uid.hasPrefix("OnlyEQ-") { return nil }
            guard !uid.isEmpty, let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name, transportType: transportType(id))
        }
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultOutputDevice(_ id: AudioObjectID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &deviceID) == noErr
    }

    // MARK: - Device properties

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func transportType(_ id: AudioObjectID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    static func outputChannelCount(_ id: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), size > 0 else { return 0 }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return 0 }
        let list = ptr.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 48000 }
        return value
    }

    // MARK: - Volume

    /// Hardware volume 0…1, or nil if the device has none (e.g. HDMI).
    static func hardwareVolume(_ id: AudioObjectID) -> Float? {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            if AudioObjectHasProperty(id, &addr) {
                var value: Float = 0
                var size = UInt32(MemoryLayout<Float>.size)
                if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr { return value }
            }
        }
        return nil
    }

    @discardableResult
    static func setHardwareVolume(_ id: AudioObjectID, _ volume: Float) -> Bool {
        var ok = false
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(id, &addr),
                  AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { continue }
            var value = min(max(volume, 0), 1)
            if AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr { ok = true }
        }
        return ok
    }

    // MARK: - Process translation (for tap exclusion)

    /// Translate running-app bundle IDs into Core Audio process objects.
    static func processObjects(forBundleIDs bundleIDs: Set<String>) -> [AudioObjectID] {
        guard !bundleIDs.isEmpty else { return [] }
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(bundleIDs.contains) ?? false }
            .map(\.processIdentifier)
        return pids.compactMap { pid in
            var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var processObject = AudioObjectID(0)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var pidValue = pid
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                    UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &processObject)
            return status == noErr && processObject != 0 ? processObject : nil
        }
    }
}

private func AudioObjectGetPropertyDataSize(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress,
                                            _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ size: inout UInt32) -> Bool {
    CoreAudio.AudioObjectGetPropertyDataSize(id, &addr, qualifierSize, qualifier, &size) == noErr
}
