#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation
import UnmuffleDSP

/// Routes everything the Mac plays through the enhancer.
///
/// 1. A Core Audio process tap captures the mix of every app except Unmuffle and mutes
///    the originals while it's running.
/// 2. A private aggregate device pairs that tap (as input) with the current output
///    device (as output), so one callback receives the captured audio and writes the
///    enhanced version straight to the speakers or headphones.
///
/// Requires macOS 14.2+ and the "System Audio Recording" permission. Everything is torn
/// down on `stop()`; if the app quits or crashes, macOS removes the tap and un-mutes.
final class SystemAudioEngine {
    /// Called on the main queue when the default output device changes.
    var onOutputDeviceChange: (() -> Void)?

    private(set) var isRunning = false
    private var outputDevice = HAL.unknown
    private var enhancer: Enhancer?
    private var renderer: TapRenderer?
    private var tapID = HAL.unknown
    private var aggregateID = HAL.unknown
    private var procID: AudioDeviceIOProcID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    // Core Audio calls the IO block on its own real-time thread; the queue is required by
    // the API but not where the work happens.
    private let queue = DispatchQueue(label: "Unmuffle.audio", qos: .userInteractive)

    deinit {
        stop()
    }

    func start(settings: EnhancerSettings) throws {
        stop()
        do {
            outputDevice = try HAL.defaultOutputDevice()
            let outputUID = try HAL.deviceUID(outputDevice)
            let tapUID = try createTap()
            try createAggregate(outputUID: outputUID, tapUID: tapUID, bluetooth: HAL.isBluetooth(outputDevice))

            var sampleRate = try HAL.nominalSampleRate(aggregateID)
            if sampleRate <= 0 { sampleRate = try HAL.nominalSampleRate(outputDevice) }
            let enhancer = Enhancer(sampleRate: sampleRate > 0 ? sampleRate : 48_000, settings: settings)
            let renderer = TapRenderer(enhancer: enhancer)

            var newProc: AudioDeviceIOProcID?
            try check(
                AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, queue) { _, input, _, output, _ in
                    renderer.render(input: input, output: output)
                },
                "set up the audio callback"
            )
            procID = newProc
            self.enhancer = enhancer
            self.renderer = renderer
            try check(AudioDeviceStart(aggregateID, procID), "start audio")
            isRunning = true
            listenForDeviceChanges()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        stopListening()
        if aggregateID != HAL.unknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != HAL.unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        outputDevice = HAL.unknown
        aggregateID = HAL.unknown
        tapID = HAL.unknown
        renderer = nil
        enhancer = nil
        isRunning = false
    }

    func update(_ settings: EnhancerSettings) {
        enhancer?.update(settings)
    }

    func readMeters() -> EnhancerMeters? {
        enhancer?.readMeters()
    }

    // MARK: - Setup

    /// Taps the stereo mix of every process except this one, muting the originals.
    private func createTap() throws -> String {
        // Excluding ourselves is what stops the enhanced output from feeding back in.
        let ownProcess = try HAL.processObject(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.uuid = UUID()
        description.name = "Unmuffle"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTap = HAL.unknown
        try check(AudioHardwareCreateProcessTap(description, &newTap), "capture system audio")
        tapID = newTap
        return description.uuid.uuidString
    }

    private func createAggregate(outputUID: String, tapUID: String, bluetooth: Bool) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Unmuffle",
            kAudioAggregateDeviceUIDKey: "Unmuffle-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    // With Bluetooth the tap already follows the headset's clock, and drift
                    // compensation causes a rhythmic crackle. Wired outputs need it.
                    kAudioSubTapDriftCompensationKey: !bluetooth,
                    kAudioSubTapUIDKey: tapUID,
                ],
            ],
        ]
        var newAggregate = HAL.unknown
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate),
            "create the audio route"
        )
        aggregateID = newAggregate
    }

    // MARK: - Output device changes

    private func listenForDeviceChanges() {
        var address = HAL.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, (try? HAL.defaultOutputDevice()) != self.outputDevice else { return }
            self.onOutputDeviceChange?()
        }
        if AudioObjectAddPropertyListenerBlock(HAL.systemObject, &address, DispatchQueue.main, listener) == noErr {
            deviceListener = listener
        }
    }

    private func stopListening() {
        guard let listener = deviceListener else { return }
        var address = HAL.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(HAL.systemObject, &address, DispatchQueue.main, listener)
        deviceListener = nil
    }
}

/// Owns the scratch buffers used on the real-time audio thread.
private final class TapRenderer: @unchecked Sendable {
    let enhancer: Enhancer
    private let capacity = 16_384
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    init(enhancer: Enhancer) {
        self.enhancer = enhancer
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = outputs.first, first.mNumberChannels > 0 else { return }

        let outputFrames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float>.size)
        let frames = min(outputFrames, capacity)
        readTap(inputs, frames: frames)
        enhancer.process(left: left, right: right, frameCount: frames)
        writeOutput(outputs, frames: frames)
    }

    /// The tap's buffers come after any input streams of the output device itself
    /// (a headset mic, for example), so read from the end of the list.
    private func readTap(_ inputs: UnsafeMutableAudioBufferListPointer, frames: Int) {
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        let count = inputs.count
        guard count > 0, let lastData = inputs[count - 1].mData else { return }
        let last = inputs[count - 1]
        let channels = Int(last.mNumberChannels)

        if channels >= 2 {
            // Interleaved stereo (the usual tap format).
            let source = lastData.assumingMemoryBound(to: Float.self)
            let available = min(frames, Int(last.mDataByteSize) / (channels * MemoryLayout<Float>.size))
            for i in 0..<available {
                left[i] = source[i * channels]
                right[i] = source[i * channels + 1]
            }
        } else if channels == 1 {
            // Non-interleaved: left and right in separate buffers, or a mono tap.
            let rightSource = lastData.assumingMemoryBound(to: Float.self)
            var leftSource = rightSource
            if count >= 2, inputs[count - 2].mNumberChannels == 1, let data = inputs[count - 2].mData {
                leftSource = data.assumingMemoryBound(to: Float.self)
            }
            let available = min(frames, Int(last.mDataByteSize) / MemoryLayout<Float>.size)
            for i in 0..<available {
                left[i] = leftSource[i]
                right[i] = rightSource[i]
            }
        }
    }

    /// Left and right go to the first two output channels; a mono device gets the sum.
    private func writeOutput(_ outputs: UnsafeMutableAudioBufferListPointer, frames: Int) {
        var totalChannels = 0
        for buffer in outputs { totalChannels += Int(buffer.mNumberChannels) }

        var channelIndex = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { channelIndex += channels }
            guard channels > 0, let data = buffer.mData else { continue }
            let destination = data.assumingMemoryBound(to: Float.self)
            let bufferFrames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            for c in 0..<channels {
                let global = channelIndex + c
                for i in 0..<bufferFrames {
                    var value: Float = 0
                    if i < frames {
                        if totalChannels == 1 {
                            value = 0.5 * (left[i] + right[i])
                        } else if global == 0 {
                            value = left[i]
                        } else if global == 1 {
                            value = right[i]
                        }
                    }
                    destination[i * channels + c] = value
                }
            }
        }
    }
}
#endif
