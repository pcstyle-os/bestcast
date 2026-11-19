import AVFAudio
import AppKit
import CoreAudio

/// What the mixer shows; the HAL work behind it lives on `AppAudioEngine`'s queue.
@MainActor
@Observable
final class AppAudioRouter {
    struct Output: Hashable, Identifiable, Sendable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    private(set) var groups: [AppAudioGroup] = []
    private(set) var outputs: [Output] = []
    private(set) var defaultOutputUID: String?

    @ObservationIgnored var onFailure: ((OSStatus) -> Void)?
    @ObservationIgnored private lazy var engine = AppAudioEngine(
        publish: { [weak self] snapshot in
            Task { @MainActor in self?.show(snapshot) }
        },
        fail: { [weak self] status in
            Task { @MainActor in self?.onFailure?(status) }
        })
    @ObservationIgnored private var poll: Task<Void, Never>?

    /// An untouched mixer installs nothing: no listener, no tap.
    func apply(_ settings: [String: AppAudioSetting]) {
        engine.apply(settings, apps: Self.runningApps())
    }

    /// While the mixer shows, rows follow apps starting and stopping playback.
    func setVisible(_ visible: Bool) {
        poll?.cancel()
        guard visible else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.engine.refresh(apps: Self.runningApps())
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func setDefaultOutput(uid: String) {
        engine.setDefaultOutput(uid: uid)
    }

    func stopAll() {
        engine.stopAll()
    }

    private func show(_ snapshot: AppAudioEngine.Snapshot) {
        if groups != snapshot.groups { groups = snapshot.groups }
        if outputs != snapshot.outputs { outputs = snapshot.outputs }
        if defaultOutputUID != snapshot.defaultOutputUID { defaultOutputUID = snapshot.defaultOutputUID }
    }

    private static func runningApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

/// Taps are built and torn down on one serial queue: from main, creating or stopping an I/O proc can
/// deadlock against the property listeners the HAL delivers.
nonisolated final class AppAudioEngine: @unchecked Sendable {
    struct Snapshot: Sendable {
        var groups: [AppAudioGroup]
        var outputs: [AppAudioRouter.Output]
        var defaultOutputUID: String?
    }

    private let queue = DispatchQueue(label: "com.bestcast.app-audio", qos: .userInitiated)
    private let notifications = DispatchQueue(label: "com.bestcast.app-audio.notifications")
    private let publish: @Sendable (Snapshot) -> Void
    private let fail: @Sendable (OSStatus) -> Void
    // Queue-confined from here down.
    private var settings: [String: AppAudioSetting] = [:]
    private var apps: Set<String> = []
    private var taps: [String: AppAudioTap] = [:]
    /// One report per app until a tap for it starts, so a refused permission is not reported per tick.
    private var reported: Set<String> = []
    private var listening = false
    private var askingMicrophone = false

    init(publish: @escaping @Sendable (Snapshot) -> Void, fail: @escaping @Sendable (OSStatus) -> Void) {
        self.publish = publish
        self.fail = fail
    }

    func apply(_ settings: [String: AppAudioSetting], apps: Set<String>) {
        queue.async { [self] in
            self.settings = settings
            self.apps = apps
            guard listening || settings.values.contains(where: \.needsTap) else { return }
            update()
        }
    }

    func refresh(apps: Set<String>) {
        queue.async { [self] in
            self.apps = apps
            update()
        }
    }

    func setDefaultOutput(uid: String) {
        queue.async { [self] in
            if let device = CoreAudioReads.devices().first(where: { CoreAudioReads.uid(of: $0) == uid }) {
                CoreAudioReads.setDefaultOutput(device)
            }
            update()
        }
    }

    /// Synchronous, so quitting waits until every app plays on its own output again.
    func stopAll() {
        queue.sync { [self] in
            for tap in taps.values { tap.stop() }
            taps = [:]
        }
    }

    private func update() {
        listen()
        let outputs = CoreAudioReads.devices().compactMap { device -> AppAudioRouter.Output? in
            guard CoreAudioReads.hasOutput(device), let uid = CoreAudioReads.uid(of: device),
                let name = CoreAudioReads.name(of: device)
            else { return nil }
            return AppAudioRouter.Output(uid: uid, name: name)
        }
        let defaultUID = CoreAudioReads.defaultOutput().flatMap(CoreAudioReads.uid(of:))
        let groups = AppAudioGrouping.groups(
            CoreAudioReads.processes(), apps: apps, adjusted: Set(settings.filter(\.value.needsTap).keys),
            excluding: Bundle.main.bundleIdentifier ?? "")
        reconcile(groups, outputs: Set(outputs.map(\.uid)), defaultUID: defaultUID)
        publish(Snapshot(groups: groups, outputs: outputs, defaultOutputUID: defaultUID))
    }

    private func reconcile(_ groups: [AppAudioGroup], outputs: Set<String>, defaultUID: String?) {
        var wanted: [String: (ids: [AudioObjectID], uid: String, gain: Float)] = [:]
        for group in groups {
            guard let setting = settings[group.appID], setting.needsTap else { continue }
            // A chosen output that went away plays on the default until it comes back.
            let chosen = setting.outputUID.flatMap { outputs.contains($0) ? $0 : nil }
            guard let uid = chosen ?? defaultUID else { continue }
            wanted[group.appID] = (group.processes.map(\.objectID), uid, setting.gain)
        }
        for (appID, tap) in taps where wanted[appID] == nil {
            tap.stop()
            taps[appID] = nil
        }
        for (appID, want) in wanted {
            if let tap = taps[appID], tap.processIDs == want.ids, tap.outputUID == want.uid {
                tap.setGain(want.gain)
                continue
            }
            taps[appID]?.stop()
            taps[appID] = nil
            guard !microphoneUnanswered(on: want.uid) else {
                askForMicrophone()
                continue
            }
            do {
                taps[appID] = try AppAudioTap(processIDs: want.ids, outputUID: want.uid, gain: want.gain)
                reported.remove(appID)
            } catch {
                taps[appID] = nil
                if reported.insert(appID).inserted { fail((error as? AppAudioError)?.status ?? -1) }
            }
        }
    }

    /// A device with an input side asks for the mic, stalling `coreaudiod`; asked here, it doesn't.
    private func microphoneUnanswered(on uid: String) -> Bool {
        AVAudioApplication.shared.recordPermission == .undetermined && CoreAudioReads.hasInput(uid: uid)
    }

    private func askForMicrophone() {
        guard !askingMicrophone else { return }
        askingMicrophone = true
        AVAudioApplication.requestRecordPermission { [self] _ in
            queue.async { [self] in
                askingMicrophone = false
                update()
            }
        }
    }

    /// New and exiting processes, devices coming and going, and a new default all re-route.
    private func listen() {
        guard !listening else { return }
        listening = true
        for selector in [
            kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            // Delivered elsewhere, then queued: the HAL waits on a listener while a stop is in flight.
            AudioObjectAddPropertyListenerBlock(CoreAudioReads.system, &address, notifications) { [weak self] _, _ in
                self?.changed()
            }
        }
    }

    private func changed() {
        queue.async { [self] in update() }
    }
}

/// The handful of HAL reads the engine needs, each a single property.
nonisolated private enum CoreAudioReads {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func processes() -> [AudioProcessInfo] {
        objects(system, kAudioHardwarePropertyProcessObjectList).compactMap { process in
            guard let pid = value(process, kAudioProcessPropertyPID, pid_t(0)), pid > 0 else { return nil }
            let bundleID = string(process, kAudioProcessPropertyBundleID) ?? ""
            return AudioProcessInfo(
                objectID: process, pid: pid,
                appID: bundleID.isEmpty ? executableName(pid) : bundleID,
                isPlaying: value(process, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1)
        }
    }

    static func devices() -> [AudioObjectID] { objects(system, kAudioHardwarePropertyDevices) }

    static func defaultOutput() -> AudioObjectID? {
        value(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    static func setDefaultOutput(_ device: AudioObjectID) {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = device
        AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
    }

    static func uid(of device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(of device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    /// Private aggregates are ours; listing them would offer a tap's own plumbing as an output.
    static func hasOutput(_ device: AudioObjectID) -> Bool {
        guard uid(of: device)?.hasPrefix("com.bestcast.") == false else { return false }
        return !objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty
    }

    static func hasInput(uid: String) -> Bool {
        devices().contains {
            self.uid(of: $0) == uid && !objects($0, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty
        }
    }

    private static func executableName(_ pid: pid_t) -> String {
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return "" }
        return String(bytes: path.prefix(Int(length)), encoding: .utf8)
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objects(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func value<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T
    ) -> T? {
        var address = address(selector)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr, let result else {
            return nil
        }
        return result.takeRetainedValue() as String
    }
}
