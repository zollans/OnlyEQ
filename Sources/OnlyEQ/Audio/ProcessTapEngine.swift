import Foundation
import CoreAudio
import AudioToolbox

/// System-wide EQ engine built on Core Audio process taps (macOS 14.4+).
///
/// Signal path: muted global tap (silences original output) → aggregate device
/// wrapping the real output + tap → IOProc reads tapped audio, runs the EQ
/// chain, and re-renders to the real output. No drivers, no BlackHole.
final class ProcessTapEngine {

    enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    let processor = EQProcessor()
    let spectrum = SpectrumAnalyzer()

    private(set) var state: State = .stopped
    private(set) var targetDeviceID: AudioObjectID = 0
    private(set) var ioBufferFrames: Int = 512

    /// Approximate added latency in seconds (tap + one IO buffer round trip).
    var estimatedLatency: Double {
        Double(ioBufferFrames) * 2 / max(processor.sampleRate, 1)
    }

    /// True once the tap has delivered at least one non-empty buffer — used to
    /// distinguish "no permission" (silent tap) from "no audio playing".
    private(set) var hasReceivedAudio = false

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var channelScratch: [UnsafeMutablePointer<Float>] = []

    var onStateChange: ((State) -> Void)?

    // MARK: - Lifecycle

    /// Start (or restart) tapping the given output device — pass nil for the
    /// current system default output.
    func start(outputDeviceID explicitDevice: AudioObjectID? = nil, excludedBundleIDs: Set<String> = []) {
        stop()

        guard let deviceID = explicitDevice ?? AudioDeviceManager.defaultOutputDeviceID(),
              let deviceUID = AudioDeviceManager.stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else {
            transition(to: .failed("No output device found."))
            return
        }
        targetDeviceID = deviceID

        // 1. Create the muted global tap, excluding opted-out apps (and ourselves —
        //    re-rendered audio must not be re-captured).
        var excluded = AudioDeviceManager.processObjects(forBundleIDs: excludedBundleIDs)
        let ownProcess = AudioDeviceManager.processObjects(forBundleIDs: [Bundle.main.bundleIdentifier ?? "com.onlyeq.app"])
        excluded.append(contentsOf: ownProcess)

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "OnlyEQ Tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var newTapID = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != 0 else {
            transition(to: .failed("Couldn’t create audio tap (error \(status))."))
            return
        }
        tapID = newTapID

        let sampleRate = AudioDeviceManager.nominalSampleRate(deviceID)
        processor.configure(sampleRate: sampleRate)
        spectrum.configure(sampleRate: sampleRate)

        // 2. Wrap the real output device + tap in a private aggregate.
        let aggregateUID = "OnlyEQ-Aggregate-\(deviceUID)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OnlyEQ",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: deviceUID,
                    // Exclude the device's input side (e.g. a Bluetooth
                    // headset's mic) from the aggregate — otherwise running
                    // our IOProc counts as microphone access and macOS shows
                    // a mic permission prompt when such a device connects.
                    kAudioSubDeviceInputChannelsKey: 0,
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        var newAggregateID = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != 0 else {
            cleanupTap()
            transition(to: .failed("Couldn’t create aggregate device (error \(status))."))
            return
        }
        aggregateID = newAggregateID

        // 3. IOProc: tapped audio arrives as input, processed audio leaves as output.
        hasReceivedAudio = false
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, _, outOutputData, _ in
            self?.render(input: inInputData, output: outOutputData)
        }
        guard status == noErr, let ioProcID else {
            cleanup()
            transition(to: .failed("Couldn’t create audio IO proc (error \(status))."))
            return
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup()
            transition(to: .failed("Couldn’t start audio device (error \(status))."))
            return
        }

        readIOBufferSize()
        transition(to: .running)
    }

    func stop() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        cleanup()
        if state != .stopped { transition(to: .stopped) }
    }

    deinit {
        stop()
    }

    private func cleanup() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        cleanupTap()
    }

    private func cleanupTap() {
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    private func transition(to newState: State) {
        state = newState
        Log.write("engine: \(newState)")
        let callback = onStateChange
        DispatchQueue.main.async { callback?(newState) }
    }

    private func readIOBufferSize() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &frames) == noErr, frames > 0 {
            ioBufferFrames = Int(frames)
        }
    }

    /// Request a specific IO buffer size (latency/stability trade-off).
    func setIOBufferFrames(_ frames: Int) {
        guard aggregateID != 0 else { ioBufferFrames = frames; return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(frames)
        if AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
            ioBufferFrames = frames
        }
    }

    // MARK: - Render path (audio thread)

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        guard inputList.count > 0, outputList.count > 0 else { return }

        // Gather input channel pointers (tap side). The tap delivers Float32;
        // buffers may be interleaved-stereo-in-one or split per channel.
        var inChannels: [(ptr: UnsafeMutablePointer<Float>, stride: Int, count: Int)] = []
        for buffer in inputList {
            guard let data = buffer.mData else { continue }
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channelCount
            let floatPtr = data.assumingMemoryBound(to: Float.self)
            for ch in 0..<channelCount {
                inChannels.append((floatPtr + ch, channelCount, frames))
            }
        }
        guard let frameCount = inChannels.map(\.count).min(), frameCount > 0 else { return }

        if !hasReceivedAudio {
            outer: for c in inChannels {
                for i in 0..<min(frameCount, 64) where c.ptr[i * c.stride] != 0 {
                    hasReceivedAudio = true
                    break outer
                }
            }
        }

        // De-interleave into scratch, process, then write to the output buffers.
        prepareScratch(channels: max(inChannels.count, 1), frames: frameCount)
        for (i, c) in inChannels.enumerated() {
            if c.stride == 1 {
                channelScratch[i].update(from: c.ptr, count: frameCount)
            } else {
                for f in 0..<frameCount { channelScratch[i][f] = c.ptr[f * c.stride] }
            }
        }
        let active = Array(channelScratch.prefix(inChannels.count))
        processor.process(channels: active, frameCount: frameCount)
        spectrum.push(channels: active, frameCount: frameCount)

        // Write processed audio out, cycling tap channels across device channels.
        var sourceIndex = 0
        for buffer in outputList {
            guard let data = buffer.mData else { continue }
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channelCount
            let floatPtr = data.assumingMemoryBound(to: Float.self)
            let n = min(frames, frameCount)
            for ch in 0..<channelCount {
                let source = active[sourceIndex % active.count]
                for f in 0..<n { floatPtr[f * channelCount + ch] = source[f] }
                sourceIndex += 1
            }
            if frames > n {
                for ch in 0..<channelCount {
                    for f in n..<frames { floatPtr[f * channelCount + ch] = 0 }
                }
            }
        }
    }

    private func prepareScratch(channels: Int, frames: Int) {
        let needed = channels
        if channelScratch.count < needed || (channelScratch.first != nil && scratchCapacity < frames) {
            for ptr in channelScratch { ptr.deallocate() }
            scratchCapacity = max(frames, 4096)
            channelScratch = (0..<needed).map { _ in
                UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
            }
        }
    }

    private var scratchCapacity = 0
}
