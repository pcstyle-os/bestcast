import AppKit
import Carbon.HIToolbox

private func keystrokeCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeystrokeTap>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reenable() }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)
    event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &characters)
    let text = String(utf16CodeUnits: characters, count: length)
    MainActor.assumeIsolated { tap.deliver(keyCode: keyCode, flags: flags, text: text) }
    return Unmanaged.passUnretained(event)
}

/// A listen-only key-down tap at the session's end, so it sees keys after Hyper rewrote them.
@MainActor
final class KeystrokeTap {
    private let onPress: (KeystrokePress) -> Void
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    init(onPress: @escaping (KeystrokePress) -> Void) {
        self.onPress = onPress
    }

    /// False when macOS refuses the tap, which means Accessibility is not granted.
    func install() -> Bool {
        guard port == nil else { return true }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: keystrokeCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else { return false }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func tearDown() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        port = nil
        source = nil
    }

    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    fileprivate func deliver(keyCode: Int, flags: NSEvent.ModifierFlags, text: String) {
        let modifiers = flags.intersection([.command, .option, .control, .shift])
        let shortcut = KeyShortcut(
            carbonKeyCode: keyCode, carbonModifiers: KeyShortcut.carbonModifiers(from: modifiers))
        let commanding = !modifiers.isDisjoint(with: [.command, .option, .control])
        // Return and Escape type control characters, arrows private-use ones: keycaps, not a run.
        let printable =
            !text.isEmpty
            && !text.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .privateUse
            }
        onPress(
            KeystrokePress(
                keycaps: shortcut.keycaps, typed: commanding || !printable ? nil : text,
                isShortcut: commanding || KeyShortcut.isFunctionKey(keyCode)))
    }
}
