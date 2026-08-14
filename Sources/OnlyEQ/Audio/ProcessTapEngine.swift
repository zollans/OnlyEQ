import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

struct TapInputSelection: Equatable {
    let bufferIndex: Int
    let channels: Int

    init(bufferIndex: Int, channels: Int) {
        self.bufferIndex = bufferIndex
        self.channels = channels
    }

    static func select(tapFormat: AudioStreamBasicDescription,
                       aggregateInputFormats: [AudioStreamBasicDescription],
                       aggregateInputChannels: [UInt32],
                       aggregateInputStartingChannels: [UInt32] = [],
                       physicalInputChannelCount: UInt32? = nil) -> TapInputSelection? {
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              tapFormat.mBitsPerChannel == 32,
              tapFormat.mChannelsPerFrame == 2,
              aggregateInputFormats.count == aggregateInputChannels.count else { return nil }
        var matches: [TapInputSelection] = []
        for (index, format) in aggregateInputFormats.enumerated()
            where aggregateInputChannels[index] == 2 && compatible(format, tapFormat) {
            matches.append(TapInputSelection(bufferIndex: index, channels: 2))
        }
        if matches.count == 1 { return matches[0] }

        // Some interfaces expose a physical stereo input with the exact same
        // format as the stereo process tap. In the aggregate's input channel
        // space, the tap starts immediately after the physical device inputs.
        // Use that channel boundary to establish provenance without assuming
        // that Core Audio returns the streams in a particular array order.
        guard aggregateInputStartingChannels.count == aggregateInputFormats.count,
              let physicalInputChannelCount,
              physicalInputChannelCount < UInt32.max else { return nil }
        let tapStartingChannel = physicalInputChannelCount + 1
        let boundaryMatches = matches.filter {
            aggregateInputStartingChannels[$0.bufferIndex] == tapStartingChannel
        }
        guard boundaryMatches.count == 1 else { return nil }
        return boundaryMatches[0]
    }

    private static func compatible(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate && lhs.mFormatID == rhs.mFormatID && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}

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
    private(set) var ioBufferFrames: Int = 256

    /// Approximate added latency in seconds (tap + one IO buffer round trip).
    var estimatedLatency: Double {
        Double(ioBufferFrames) * 2 / max(processor.sampleRate, 1)
    }

    /// True once the tap has delivered non-silent audio, confirming that the
    /// current engine instance is receiving the system mix.
    private(set) var hasReceivedAudio = false

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var channelScratch: [UnsafeMutablePointer<Float>] = []
    private struct InputChannel {
        var pointer: UnsafeMutablePointer<Float>
        var stride: Int
    }
    private var inputChannels: [InputChannel] = []
    private var activeChannels: [UnsafeMutablePointer<Float>] = []
    /// Consecutive all-zero input frames, saturated at one second's worth.
    private var silentFrames = 0
    private var isSilenceGated = false
    private var preparedInput: TapInputSelection

    var onStateChange: ((State) -> Void)?

    /// Fired (on the main queue) when the tapped device's nominal sample rate
    /// changes while running. Biquad coefficients are baked for one rate, so
    /// the owner must restart the engine to stay on pitch.
    var onSampleRateChange: (() -> Void)?

    init(preparedInput: TapInputSelection = TapInputSelection(bufferIndex: 0, channels: 2)) {
        self.preparedInput = preparedInput
        inputChannels.reserveCapacity(8)
        activeChannels.reserveCapacity(8)
        channelScratch.reserveCapacity(8)
        prepareScratch(channels: preparedInput.channels, frames: ioBufferFrames)
    }

    // MARK: - Lifecycle

    /// Start (or restart) tapping the given output device — pass nil for the
    /// current system default output.
    func start(outputDeviceID explicitDevice: AudioObjectID? = nil, excludedBundleIDs: Set<String> = []) {
        stop()
        // A previous engine instance may have received audio even when this
        // start attempt cannot resolve an output device. Reset probe state up
        // front so failed restarts never masquerade as a live audio path.
        hasReceivedAudio = false
        targetDeviceID = 0

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

        // Prefer a unique format match. If a physical stereo input has the
        // same format as the tap, use aggregate channel numbering to identify
        // the tap without relying on stream-array order.
        guard let tapFormat = AudioDeviceManager.tapFormat(tapID),
              let inputFormats = AudioDeviceManager.inputStreamFormats(aggregateID),
              let inputChannels = AudioDeviceManager.inputStreamChannelCounts(aggregateID) else {
            cleanup()
            transition(to: .failed("Unsupported aggregate input topology: no unique tap stream."))
            return
        }
        let selection = TapInputSelection.select(
            tapFormat: tapFormat,
            aggregateInputFormats: inputFormats,
            aggregateInputChannels: inputChannels,
            aggregateInputStartingChannels: AudioDeviceManager.inputStreamStartingChannels(aggregateID) ?? [],
            physicalInputChannelCount: AudioDeviceManager.inputChannelCount(deviceID)
        )
        guard let selection else {
            cleanup()
            transition(to: .failed("Unsupported aggregate input topology: no unique tap stream."))
            return
        }
        preparedInput = selection

        // 3. IOProc: tapped audio arrives as input, processed audio leaves as output.
        silentFrames = 0
        isSilenceGated = false
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, _, outOutputData, _ in
            self?.render(input: inInputData, output: outOutputData)
        }
        guard status == noErr, let ioProcID else {
            cleanup()
            transition(to: .failed("Couldn’t create audio IO proc (error \(status))."))
            return
        }

        // Allocate the normal stereo scratch path before the realtime callback
        // starts. prepareScratch still handles unusual topologies defensively.
        readIOBufferSize()
        prepareScratch(channels: 2, frames: ioBufferFrames)

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup()
            transition(to: .failed("Couldn’t start audio device (error \(status))."))
            return
        }

        installSampleRateListener(on: deviceID)
        transition(to: .running)
    }

    func stop() {
        removeSampleRateListener()
        cleanup()
        targetDeviceID = 0
        hasReceivedAudio = false
        if state != .stopped { transition(to: .stopped) }
    }

    deinit {
        stop()
        for pointer in channelScratch { pointer.deallocate() }
    }

    private func cleanup() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
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

    private static let sampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func installSampleRateListener(on deviceID: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self,
                  AudioDeviceManager.nominalSampleRate(deviceID) != self.processor.sampleRate else { return }
            self.onSampleRateChange?()
        }
        var addr = Self.sampleRateAddress
        if AudioObjectAddPropertyListenerBlock(deviceID, &addr, .main, block) == noErr {
            sampleRateListener = block
            // Close the small gap between the initial rate read and listener
            // installation: a device can renegotiate while the aggregate starts.
            if AudioDeviceManager.nominalSampleRate(deviceID) != processor.sampleRate {
                onSampleRateChange?()
            }
        }
    }

    private func removeSampleRateListener() {
        guard let sampleRateListener, targetDeviceID != 0 else { return }
        var addr = Self.sampleRateAddress
        AudioObjectRemovePropertyListenerBlock(targetDeviceID, &addr, .main, sampleRateListener)
        self.sampleRateListener = nil
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

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        guard inputList.count > 0, outputList.count > 0 else {
            zero(outputList)
            return
        }
        // Consume only the prepared tap stream; other aggregate inputs can be
        // physical streams and must never influence output.
        inputChannels.removeAll(keepingCapacity: true)
        guard preparedInput.bufferIndex < inputList.count else { zero(outputList); return }
        let selectedBuffer = inputList[preparedInput.bufferIndex]
        let channels = preparedInput.channels
        guard channels == 2, let data = selectedBuffer.mData, Int(selectedBuffer.mNumberChannels) == channels,
              selectedBuffer.mDataByteSize % UInt32(MemoryLayout<Float>.size * channels) == 0 else { zero(outputList); return }
        let frameCount = Int(selectedBuffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frameCount > 0 else {
            zero(outputList)
            return
        }
        let floatPtr = data.assumingMemoryBound(to: Float.self)
        for ch in 0..<channels {
            inputChannels.append(InputChannel(pointer: floatPtr + ch, stride: channels))
        }
        guard inputChannels.count <= channelScratch.count, frameCount <= scratchCapacity else {
            zero(outputList)
            return
        }

        // Inspect the exact frames/channels the renderer consumes. Scanning the
        // raw AudioBuffer storage as one contiguous vDSP vector is incorrect for
        // layouts with padding or a channel stride and can leave the engine
        // permanently gated after playback resumes.
        var inputHasSignal = false
        signalSearch: for channel in inputChannels {
            for frame in 0..<frameCount where channel.pointer[frame * channel.stride] != 0 {
                inputHasSignal = true
                break signalSearch
            }
        }
        if inputHasSignal {
            hasReceivedAudio = true
            silentFrames = 0
            isSilenceGated = false
        } else {
            let ringOutFrames = Int(processor.sampleRate)
            silentFrames = min(silentFrames + frameCount, ringOutFrames)
            if silentFrames == ringOutFrames {
                if !isSilenceGated {
                    processor.resetRenderState()
                    isSilenceGated = true
                }
                zero(outputList)
                return
            }
        }

        // De-interleave into scratch, process, then write to the output buffers.
        activeChannels.removeAll(keepingCapacity: true)
        var zero: Float = 0
        for (index, channel) in inputChannels.enumerated() {
            let scratch = channelScratch[index]
            if channel.stride == 1 {
                scratch.update(from: channel.pointer, count: frameCount)
            } else {
                vDSP_vsadd(channel.pointer, vDSP_Stride(channel.stride), &zero,
                           scratch, 1, vDSP_Length(frameCount))
            }
            activeChannels.append(scratch)
        }
        processor.process(channels: activeChannels, frameCount: frameCount)
        spectrum.push(channels: activeChannels, frameCount: frameCount)

        // Write processed audio out, cycling tap channels across device channels.
        var sourceIndex = 0
        for buffer in outputList {
            guard let data = buffer.mData else { continue }
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channelCount
            let floatPtr = data.assumingMemoryBound(to: Float.self)
            let n = min(frames, frameCount)
            for ch in 0..<channelCount {
                let source = activeChannels[sourceIndex % activeChannels.count]
                if channelCount == 1 {
                    floatPtr.update(from: source, count: n)
                } else {
                    vDSP_vsadd(source, 1, &zero, floatPtr + ch,
                               vDSP_Stride(channelCount), vDSP_Length(n))
                }
                sourceIndex += 1
            }
            if frames > n {
                vDSP_vclr(floatPtr + n * channelCount, 1, vDSP_Length((frames - n) * channelCount))
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

    private func zero(_ outputList: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputList {
            guard let data = buffer.mData else { continue }
            vDSP_vclr(data.assumingMemoryBound(to: Float.self), 1,
                      vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
        }
    }
}
