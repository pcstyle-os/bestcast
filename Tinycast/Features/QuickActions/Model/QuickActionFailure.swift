import Foundation

/// One case per cause: a single "nothing selected" tells a reader to select what they selected.
enum QuickActionFailure: LocalizedError, Equatable {
    case needsAccessibility
    case noTarget
    case noPasteTarget
    /// The app answered but exposes no focused text element — Chromium before its tree is built.
    case unreadableApp(String)
    case noSelection
    case tooLong
    case clipboardEmpty
    case clipboardTooLong
    case noBrowser
    case browserAutomationDenied(String)
    case browserUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .needsAccessibility:
            return "Tinycast needs the Accessibility permission to read the selected text."
        case .noTarget:
            return "Select text in another app first."
        case .noPasteTarget:
            return "Click into a text field in another app first."
        case .unreadableApp(let name):
            return "\(name) doesn't share its text with Tinycast."
        case .noSelection:
            return "Select some text first."
        case .tooLong:
            return "That selection is too long to work on."
        case .clipboardEmpty:
            return "Copy some text first."
        case .clipboardTooLong:
            return "The clipboard is too long to work on."
        case .noBrowser:
            return "Bring Safari, Chrome, Arc or Brave to the front first."
        case .browserAutomationDenied(let name):
            return "Allow Tinycast to control \(name) in Automation settings, then try again."
        case .browserUnreadable(let name):
            return "\(name) has no open tab to read."
        }
    }

    /// The failures with somewhere to send the reader, and so the only ones worth a dialog.
    var opensAccessibilitySettings: Bool { self == .needsAccessibility }

    var opensAutomationSettings: Bool {
        if case .browserAutomationDenied = self { return true }
        return false
    }
}
