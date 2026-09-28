import AppKit
import Carbon.HIToolbox
@preconcurrency import IOKit.hidsystem
import Synchronization

// Snapshot the mutable C global `mach_task_self_`, so actor code never reads it raw.
private let machTaskSelf = mach_task_self_

/// C entry point, on the tap thread: decode, decide under the lock, then apply it out here.
private func hyperKeyEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tapThread = Unmanaged<HyperKeyTapThread>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tapThread.revive()
        return Unmanaged.passUnretained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let userData = event.getIntegerValueField(.eventSourceUserData)
    // A paste or keystroke Tinycast posts carries exact flags; a held Hyper must not add the chord.
    let isSynthetic = userData == HyperKeyTap.syntheticTag || userData == Paster.tinycastEventTag

    let outcome = tapThread.decide(
        type: type, keyCode: keyCode, flagsRaw: event.flags.rawValue,
        isAutorepeat: isAutorepeat, isSynthetic: isSynthetic)
    if let quickPress = outcome.quickPress { tapThread.onQuickPress(quickPress) }
    switch outcome.decision {
    case .pass:
        return Unmanaged.passUnretained(event)
    case .suppress:
        return nil
    case .rewrite(let flags, let keyCode, let asFlagsChanged):
        if asFlagsChanged { event.type = .flagsChanged }
        if let keyCode {
            event.setIntegerValueField(.keyboardEventKeycode, value: keyCode)
        }
        event.flags = CGEventFlags(rawValue: flags)
        return Unmanaged.passUnretained(event)
    }
}

/// HID remap of Caps Lock → F18 while it is Hyper. See docs/features/hotkeys.md#the-hyper-key.
private enum CapsLockRemap {
    // HID usages: keyboard page 0x07, Caps Lock 0x39, F18 0x6D.
    private static let mappingOn =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
    private static let mappingOff = #"{"UserKeyMapping":[]}"#

    // Serial, so rapid on→off→on toggles apply in call order rather than racing.
    private static let queue = DispatchQueue(label: "com.tinycast.capslock-remap", qos: .utility)

    static func setEnabled(_ enabled: Bool) {
        let mapping = enabled ? mappingOn : mappingOff
        queue.async { apply(mapping) }
    }

    /// Synchronous variant for `applicationWillTerminate`, where detached work wouldn't get to run.
    static func clearBlocking() {
        apply(mappingOff)
    }

    private static func apply(_ mapping: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", mapping]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.runObservingExit().wait()
            if process.terminationStatus != 0 {
                NSLog("Tinycast: hidutil remap exited %d", process.terminationStatus)
            }
        } catch {
            NSLog("Tinycast: hidutil caps lock remap failed: %@", error.localizedDescription)
        }
    }
}

/// The tap's CF handles; unchecked because CF mach port and run loop calls are thread-safe.
private struct HyperKeyTapHandles: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
    var runLoop: CFRunLoop?
}

/// The tap on its own thread, so a busy main actor never delays a keystroke. See hotkeys.md.
private final class HyperKeyTapThread: Sendable {
    let onQuickPress: @Sendable (HyperKeyRewriter.QuickPress) -> Void
    private let rewriter: Mutex<HyperKeyRewriter>
    private let handles = Mutex<HyperKeyTapHandles?>(nil)

    private init(
        configuration: HyperKeyRewriter.Configuration,
        onQuickPress: @escaping @Sendable (HyperKeyRewriter.QuickPress) -> Void
    ) {
        rewriter = Mutex(HyperKeyRewriter(configuration: configuration))
        self.onQuickPress = onQuickPress
    }

    /// Nil when the tap can't be created, which in practice means no Accessibility grant.
    static func start(
        configuration: HyperKeyRewriter.Configuration,
        onQuickPress: @escaping @Sendable (HyperKeyRewriter.QuickPress) -> Void
    ) -> HyperKeyTapThread? {
        let tapThread = HyperKeyTapThread(configuration: configuration, onQuickPress: onQuickPress)
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: hyperKeyEventTapCallback,
                userInfo: Unmanaged.passUnretained(tapThread).toOpaque())
        else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        tapThread.handles.withLock { $0 = HyperKeyTapHandles(port: port, source: source) }

        // The block keeps the object alive for as long as its run loop can call back into it.
        let thread = Thread { [tapThread] in tapThread.runUntilStopped() }
        thread.name = "com.tinycast.hyper-key-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return tapThread
    }

    private func runUntilStopped() {
        let attached = handles.withLock { handles -> Bool in
            guard let source = handles?.source else { return false }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            handles?.runLoop = CFRunLoopGetCurrent()
            return true
        }
        if attached { CFRunLoopRun() }
    }

    func decide(
        type: CGEventType, keyCode: Int, flagsRaw: UInt64, isAutorepeat: Bool, isSynthetic: Bool
    ) -> HyperKeyRewriter.Outcome {
        rewriter.withLock {
            $0.decide(
                type: type, keyCode: keyCode, flagsRaw: flagsRaw, isAutorepeat: isAutorepeat,
                isSynthetic: isSynthetic, at: .now)
        }
    }

    func configure(_ configuration: HyperKeyRewriter.Configuration) {
        rewriter.withLock { $0.configure(configuration) }
    }

    var isEnabled: Bool {
        handles.withLock { $0.map { CGEvent.tapIsEnabled(tap: $0.port) } ?? false }
    }

    /// Re-enables a tap the system disabled; a hold spanning the gap may have lost its release.
    func revive() {
        rewriter.withLock { $0.cancelHold() }
        handles.withLock { if let port = $0?.port { CGEvent.tapEnable(tap: port, enable: true) } }
    }

    func suspend() {
        rewriter.withLock { $0.cancelHold() }
        handles.withLock { if let port = $0?.port { CGEvent.tapEnable(tap: port, enable: false) } }
    }

    /// Invalidating the port detaches the source; stopping the run loop lets the thread exit.
    func stop() {
        let taken = handles.withLock { handles -> HyperKeyTapHandles? in
            defer { handles = nil }
            return handles
        }
        guard let taken else { return }
        CGEvent.tapEnable(tap: taken.port, enable: false)
        CFMachPortInvalidate(taken.port)
        if let runLoop = taken.runLoop { CFRunLoopStop(runLoop) }
    }
}

/// The Hyper Key engine, a modifying tap. See docs/features/hotkeys.md#the-hyper-key.
@MainActor
@Observable
final class HyperKeyTap: HealthCheckable {
    enum Status: Equatable {
        case off
        case active
        case needsAccessibility
    }

    /// Marker on events this tap posts, so it never reacts to its own synthetics.
    nonisolated static let syntheticTag: Int64 = 0x5459_4354

    private(set) var status: Status = .off

    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var tapThread: HyperKeyTapThread?
    @ObservationIgnored private var sessionTokens: [NotificationToken] = []
    @ObservationIgnored private var sessionActive = true
    @ObservationIgnored private var hidConnect: io_connect_t = IO_OBJECT_NULL

    @ObservationIgnored weak var healthTicker: HealthTicker?

    /// Mirror of the Hyper settings; the tap thread holds its own copy, pushed on every change.
    @ObservationIgnored private var configuration = HyperKeyRewriter.Configuration()
    private var key: HyperKeyPhysicalKey { configuration.key }

    // Isolated so teardown can release the main-actor IOKit connection.
    isolated deinit {
        tapThread?.stop()
        if hidConnect != IO_OBJECT_NULL { IOServiceClose(hidConnect) }
    }

    func start(settings: AppSettings) {
        self.settings = settings
        applySettings()
        observeSettings()

        // Fast user switching: drop half-held state and stop rewriting until we are back.
        let center = NSWorkspace.shared.notificationCenter
        sessionTokens = [
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sessionDidResign() }
                }, center: center),
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sessionDidBecomeActive() }
                }, center: center)
        ]
    }

    /// Fires synchronously on main before the write lands, so the task re-arms, then applies.
    private func observeSettings() {
        withObservationTracking {
            _ = settings?.hyperKey
            _ = settings?.hyperKeyIncludesShift
            _ = settings?.hyperKeyQuickPress
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeSettings()
                self.applySettings()
            }
        }
    }

    // MARK: - Configuration

    private func applySettings() {
        guard let settings else { return }
        let newConfiguration = HyperKeyRewriter.Configuration(
            key: settings.hyperKey, includesShift: settings.hyperKeyIncludesShift,
            quickPress: settings.hyperKeyQuickPress)
        guard newConfiguration != configuration else { return }
        let oldKey = key
        configuration = newConfiguration
        tapThread?.configure(newConfiguration)
        guard key != oldKey else { return }
        if key == .capsLock {
            // Remapping takes the key's own function away, so unlatch the lock first.
            setCapsLockState(false)
            CapsLockRemap.setEnabled(true)
        } else if oldKey == .capsLock {
            CapsLockRemap.setEnabled(false)
        }
        syncTapPresence()
    }

    /// The HID remap outlives the process, so hand the key back before exiting.
    func prepareForTermination() {
        if key == .capsLock { CapsLockRemap.clearBlocking() }
    }

    // MARK: - Tap lifecycle

    private func syncTapPresence() {
        if key == .none {
            tearDownTap()
            healthTicker?.unsubscribe(self)
            status = .off
        } else {
            healthTicker?.subscribe(self)
            installTapIfNeeded()
        }
    }

    private func installTapIfNeeded() {
        guard tapThread == nil, key != .none else { return }
        guard
            let tapThread = HyperKeyTapThread.start(
                configuration: configuration,
                onQuickPress: { [weak self] quickPress in
                    Task { @MainActor in self?.fireQuickPress(quickPress) }
                })
        else {
            // A modifying tap needs Accessibility; the health timer retries until granted.
            status = .needsAccessibility
            return
        }
        self.tapThread = tapThread
        status = .active
    }

    private func tearDownTap() {
        tapThread?.stop()
        tapThread = nil
    }

    /// One-second watchdog while a key is configured. See docs/features/hotkeys.md#lifecycle.
    func healthCheck() {
        guard key != .none, sessionActive else { return }
        if tapThread == nil {
            installTapIfNeeded()
        } else if !Permissions.isAccessibilityTrusted() {
            tearDownTap()
            status = .needsAccessibility
        } else if let tapThread, !tapThread.isEnabled {
            tapThread.revive()
        }
    }

    private func sessionDidResign() {
        sessionActive = false
        tapThread?.suspend()
    }

    private func sessionDidBecomeActive() {
        sessionActive = true
        if let tapThread {
            tapThread.revive()
        } else {
            installTapIfNeeded()
        }
    }

    // MARK: - Quick Press

    private func fireQuickPress(_ quickPress: HyperKeyRewriter.QuickPress) {
        switch quickPress.action {
        case .none:
            break
        case .originalKey:
            if quickPress.key == .capsLock { setCapsLockState(!capsLockState()) }
        case .escape:
            postKey(CGKeyCode(kVK_Escape))
        }
    }

    // MARK: - Synthetics & caps state

    /// Synthesize a bare key press for Quick Press, tagged so the tap ignores it.
    private func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        for event in [down, up] {
            // The session source still carries the chord we injected, and a modified Escape is eaten.
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The IOHIDSystem connection for the Caps Lock LED and lock state.
    private func hidConnection() -> io_connect_t {
        if hidConnect != IO_OBJECT_NULL { return hidConnect }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return IO_OBJECT_NULL }
        var connect: io_connect_t = IO_OBJECT_NULL
        IOServiceOpen(service, machTaskSelf, UInt32(kIOHIDParamConnectType), &connect)
        IOObjectRelease(service)
        hidConnect = connect
        return connect
    }

    private func capsLockState() -> Bool {
        let connect = hidConnection()
        guard connect != IO_OBJECT_NULL else { return false }
        var on = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on)
        return on
    }

    private func setCapsLockState(_ on: Bool) {
        let connect = hidConnection()
        guard connect != IO_OBJECT_NULL else { return }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }
}
