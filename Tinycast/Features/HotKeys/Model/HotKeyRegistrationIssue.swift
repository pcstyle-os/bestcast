import Carbon.HIToolbox

/// Why a recorded combo is not live. See docs/features/hotkeys.md#when-a-combo-does-not-register.
enum HotKeyRegistrationIssue: Equatable, Sendable {
    case heldByAnotherApp
    case reservedBySystem
    case refused(OSStatus)

    /// An enabled macOS shortcut from `CopySymbolicHotKeys`, in Carbon's encoding.
    struct SystemShortcut: Equatable, Sendable {
        let carbonKeyCode: Int
        let carbonModifiers: Int
    }

    /// Without fn: macOS stores it on every F-key and arrow entry, and the recorder drops it there.
    private static let comparedModifiers = cmdKey | shiftKey | optionKey | controlKey

    /// A system shortcut wins over any status: macOS consumes the chord before Carbon delivers it.
    static func diagnose(
        status: OSStatus, carbonKeyCode: Int, carbonModifiers: Int,
        systemShortcuts: [SystemShortcut]
    ) -> HotKeyRegistrationIssue? {
        let modifiers = carbonModifiers & comparedModifiers
        let isSystemShortcut = systemShortcuts.contains {
            $0.carbonKeyCode == carbonKeyCode && $0.carbonModifiers & comparedModifiers == modifiers
        }
        if isSystemShortcut { return .reservedBySystem }
        switch status {
        case noErr: return nil
        case OSStatus(eventHotKeyExistsErr): return .heldByAnotherApp
        default: return .refused(status)
        }
    }

    var message: String {
        switch self {
        case .heldByAnotherApp:
            "In use by another app. Quit it, then click to retry."
        case .reservedBySystem:
            "macOS uses this shortcut. Turn it off in System Settings › Keyboard › Keyboard "
                + "Shortcuts, then click to retry."
        case .refused(let status):
            "macOS refused this shortcut (error \(status)). Click to retry, or record another."
        }
    }
}
