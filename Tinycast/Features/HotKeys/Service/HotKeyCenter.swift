import Carbon.HIToolbox
import Observation

/// C entry point: decode the `EventRef` to a plain value before crossing into actor code.
private func hotKeyCarbonEventHandler(
    _: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let error = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard error == noErr else { return error }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated { center.handle(hotKeyID) }
}

/// The Carbon layer only; which shortcuts exist is `HotKeyManager`'s business.
@MainActor
@Observable
final class HotKeyCenter {
    private struct Entry {
        let shortcut: KeyShortcut
        let onKeyDown: () -> Void
        let carbonID: UInt32
        var ref: EventHotKeyRef?
    }

    /// Live registrations by stable id, plus the reverse lookup the Carbon callback needs.
    private var entries: [String: Entry] = [:]
    private var idToKey: [UInt32: String] = [:]
    private var nextCarbonID: UInt32 = 0
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x5459_4354  // FourCC "TYCT"
    /// Why a registered id is not live, keyed like `entries`; the recorder renders it.
    private(set) var issues: [String: HotKeyRegistrationIssue] = [:]
    /// Read once per batch, and again whenever the user may have changed macOS's own shortcuts.
    @ObservationIgnored private var systemShortcutsCache: [HotKeyRegistrationIssue.SystemShortcut]?

    /// While true every hotkey is soft-unregistered, so a recorder can capture combos.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused { systemShortcutsCache = nil }
            for key in entries.keys {
                if isPaused { deactivate(key) } else { activate(key) }
            }
        }
    }

    /// Registers `shortcut` under `id`, dropping any previous one so no combo leaks.
    func register(id: String, shortcut: KeyShortcut, onKeyDown: @escaping () -> Void) {
        unregister(id: id)
        nextCarbonID += 1
        entries[id] = Entry(
            shortcut: shortcut, onKeyDown: onKeyDown, carbonID: nextCarbonID, ref: nil)
        idToKey[nextCarbonID] = id
        if !isPaused { activate(id) }
    }

    func unregister(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let ref = entry.ref { UnregisterEventHotKey(ref) }
        idToKey.removeValue(forKey: entry.carbonID)
        record(nil, for: id)
    }

    /// The other owner may have quit, or macOS's shortcut been turned off, since the last try.
    func retry(id: String) {
        guard !isPaused else { return }
        systemShortcutsCache = nil
        deactivate(id)
        activate(id)
    }

    private func activate(_ id: String) {
        guard var entry = entries[id], entry.ref == nil else { return }
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let error = RegisterEventHotKey(
            UInt32(entry.shortcut.carbonKeyCode),
            UInt32(entry.shortcut.carbonModifiers),
            EventHotKeyID(signature: signature, id: entry.carbonID),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        let issue = HotKeyRegistrationIssue.diagnose(
            status: error, carbonKeyCode: entry.shortcut.carbonKeyCode,
            carbonModifiers: entry.shortcut.carbonModifiers, systemShortcuts: systemShortcuts)
        record(issue, for: id)
        guard error == noErr, let ref else {
            NSLog("Tinycast: could not register hotkey for %@ (OSStatus %d)", id, error)
            return
        }
        entry.ref = ref
        entries[id] = entry
    }

    private func deactivate(_ id: String) {
        guard var entry = entries[id], let ref = entry.ref else { return }
        UnregisterEventHotKey(ref)
        entry.ref = nil
        entries[id] = entry
    }

    private func record(_ issue: HotKeyRegistrationIssue?, for id: String) {
        // Every recorder reads this map, so even an unchanged write would redraw them all.
        guard issues[id] != issue else { return }
        issues[id] = issue
    }

    private var systemShortcuts: [HotKeyRegistrationIssue.SystemShortcut] {
        if let systemShortcutsCache { return systemShortcutsCache }
        let shortcuts = Self.enabledSystemShortcuts()
        systemShortcutsCache = shortcuts
        return shortcuts
    }

    private static func enabledSystemShortcuts() -> [HotKeyRegistrationIssue.SystemShortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
            let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                let keyCode = entry[kHISymbolicHotKeyCode as String] as? Int,
                let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int
            else { return nil }
            return HotKeyRegistrationIssue.SystemShortcut(
                carbonKeyCode: keyCode, carbonModifiers: modifiers)
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil, let dispatcher = GetEventDispatcherTarget() else { return }
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]
        InstallEventHandler(
            dispatcher,
            hotKeyCarbonEventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    fileprivate func handle(_ hotKeyID: EventHotKeyID) -> OSStatus {
        guard
            hotKeyID.signature == signature,
            let key = idToKey[hotKeyID.id],
            let entry = entries[key]
        else { return OSStatus(eventNotHandledErr) }
        entry.onKeyDown()
        return noErr
    }
}
