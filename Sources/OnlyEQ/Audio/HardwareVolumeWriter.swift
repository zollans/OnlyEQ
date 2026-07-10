import CoreAudio
import Foundation

/// Core Audio property writes can block briefly, especially for Bluetooth
/// devices. Keep them off the main actor and retain only the newest request so
/// a fast pointer drag never creates a queue of stale volume changes.
final class HardwareVolumeWriter: @unchecked Sendable {
    private struct Request: Sendable {
        var deviceID: AudioObjectID
        var volume: Float
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "OnlyEQ.hardware-volume", qos: .userInteractive)
    private var pending: Request?
    private var workerIsRunning = false

    func submit(deviceID: AudioObjectID, volume: Float) {
        lock.lock()
        pending = Request(deviceID: deviceID, volume: volume)
        let shouldStart = !workerIsRunning
        if shouldStart { workerIsRunning = true }
        lock.unlock()

        if shouldStart {
            queue.async { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else {
                workerIsRunning = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            AudioDeviceManager.setHardwareVolume(request.deviceID, request.volume)
        }
    }
}
