import CoreAudio
import Foundation
import Synchronization

struct AppAudioError: Error {
    let status: OSStatus
}

/// One app's audio, taken off its output and replayed at a gain. See docs/features/app-audio.md.
nonisolated final class AppAudioTap: @unchecked Sendable {
    let processIDs: [AudioObjectID]
    let outputUID: String

    /// What both real-time threads read: the ring, the gain, and tap frames per output frame.
    final class Shared: Sendable {
        let ring: AudioSampleRing
        let gain: Atomic<UInt32>
        let step = Atomic<UInt64>(1.0.bitPattern)

        init(ring: AudioSampleRing, gain: Float) {
            self.ring = ring
            self.gain = Atomic(gain.bitPattern)
        }
    }

    private static let rateChanges = DispatchQueue(label: "com.bestcast.app-audio.rate")

    /// Long enough to ride out a late I/O cycle; a reader further behind skips to 50 ms.
    private static let ringSeconds = 1.0
    private static let maximumLagSeconds = 0.1

    private var shared: Shared?
    private let initialGain: Float
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputID = AudioObjectID(kAudioObjectUnknown)
    private var outputProcID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?

    init(processIDs: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.processIDs = processIDs
        self.outputUID = outputUID
        initialGain = gain
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    func setGain(_ value: Float) {
        shared?.gain.store(value.bitPattern, ordering: .relaxed)
    }

    func stop() {
        if let rateListener {
            for (object, selector) in rateSources {
                var address = address(selector)
                AudioObjectRemovePropertyListenerBlock(object, &address, Self.rateChanges, rateListener)
            }
            self.rateListener = nil
        }
        if let outputProcID {
            AudioDeviceStop(outputID, outputProcID)
            AudioDeviceDestroyIOProcID(outputID, outputProcID)
            self.outputProcID = nil
        }
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.uuid = UUID()
        // The app goes silent on its own output while tapped, so only the replayed copy is heard.
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID))
        outputID = try deviceID()
        let format = try property(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        let rate = format.mSampleRate
        let shared = Shared(
            ring: AudioSampleRing(
                channels: max(Int(format.mChannelsPerFrame), 1), capacity: Int(rate * Self.ringSeconds),
                maximumLag: Int(rate * Self.maximumLagSeconds)),
            gain: initialGain)
        self.shared = shared
        try startCapture(into: shared.ring)
        followRateChanges(shared)
        try startOutput(shared: shared)
    }

    /// Either side changing rate, say a headset switching to its call profile, re-pitches the copy.
    private var rateSources: [(AudioObjectID, AudioObjectPropertySelector)] {
        [(outputID, kAudioDevicePropertyNominalSampleRate), (tapID, kAudioTapPropertyFormat)]
    }

    private func followRateChanges(_ shared: Shared) {
        let (tap, output) = (tapID, outputID)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in Self.updateStep(shared, tap: tap, output: output) }
        Self.updateStep(shared, tap: tap, output: output)
        rateListener = listener
        for (object, selector) in rateSources {
            var address = address(selector)
            AudioObjectAddPropertyListenerBlock(object, &address, Self.rateChanges, listener)
        }
    }

    private static func updateStep(_ shared: Shared, tap: AudioObjectID, output: AudioObjectID) {
        var tapFormat = AudioStreamBasicDescription()
        var outputRate = Float64(0)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &tapFormat) == noErr,
            AudioObjectGetPropertyData(output, &rateAddress, 0, nil, &rateSize, &outputRate) == noErr,
            tapFormat.mSampleRate > 0, outputRate > 0
        else { return }
        shared.step.store((tapFormat.mSampleRate / outputRate).bitPattern, ordering: .relaxed)
    }

    /// The tap alone, with no device in the aggregate: a device's input side would be a microphone.
    private func startCapture(into ring: AudioSampleRing) throws {
        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bestcast App Audio",
            kAudioAggregateDeviceUIDKey: "com.bestcast.app-audio." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: try tapUID()]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregateID))
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let buffer = buffers.last, let data = buffer.mData?.assumingMemoryBound(to: Float.self)
                else { return }
                let channels = max(Int(buffer.mNumberChannels), 1)
                ring.write(data, frames: Int(buffer.mDataByteSize) / 4 / channels, sourceChannels: channels)
            })
        try check(AudioDeviceStart(aggregateID, procID))
    }

    /// A raw I/O proc, input off: an audio unit or a rate set on the aggregate both ask for the mic.
    private func startOutput(shared: Shared) throws {
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&outputProcID, outputID, nil) { _, _, _, output, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(output)
                for (index, buffer) in buffers.enumerated() {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let channels = max(Int(buffer.mNumberChannels), 1)
                    let frames = Int(buffer.mDataByteSize) / 4 / channels
                    if index == 0 {
                        shared.ring.read(
                            into: data, frames: frames, outputChannels: channels,
                            gain: Float(bitPattern: shared.gain.load(ordering: .relaxed)),
                            step: Double(bitPattern: shared.step.load(ordering: .relaxed)))
                    } else {
                        data.update(repeating: 0, count: frames * channels)
                    }
                }
            })
        try turnOffInputStreams()
        try check(AudioDeviceStart(outputID, outputProcID))
    }

    private func turnOffInputStreams() throws {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(outputID, &address, 0, nil, &size) == noErr, size > 0,
            let outputProcID
        else { return }
        let streams = Int(size) / MemoryLayout<AudioStreamID>.size
        let usageSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + (streams - 1) * MemoryLayout<UInt32>.size
        let usage = UnsafeMutableRawPointer.allocate(
            byteCount: usageSize, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { usage.deallocate() }
        usage.initializeMemory(as: UInt8.self, repeating: 0, count: usageSize)
        let header = usage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        header.pointee.mIOProc = unsafeBitCast(outputProcID, to: UnsafeMutableRawPointer.self)
        header.pointee.mNumberStreams = UInt32(streams)
        address = self.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        try check(AudioObjectSetPropertyData(outputID, &address, 0, nil, UInt32(usageSize), usage))
    }

    private func property<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T
    ) throws -> T {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value))
        return value
    }

    private func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func tapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uid))
        guard let uid else { throw AppAudioError(status: -1) }
        return uid.takeRetainedValue() as String
    }

    private func deviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid = outputUID as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try withUnsafeMutablePointer(to: &uid) { qualifier in
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address,
                    UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device))
        }
        guard device != kAudioObjectUnknown else { throw AppAudioError(status: -1) }
        return device
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AppAudioError(status: status) }
    }
}
