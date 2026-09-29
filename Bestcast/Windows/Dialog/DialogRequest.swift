import Foundation

/// One button; role decides its colour, severity living separately in `DialogTone`.
struct DialogAction {
    enum Role {
        case standard
        case destructive
        case cancel
    }

    let title: String
    var role: Role = .standard
}

/// How serious a dialog is; it tints the glyph but never picks one. See docs/ui.md.
enum DialogTone: Sendable {
    case neutral
    case success
    case danger
}

struct DialogRequest {
    let title: String
    var message: String?
    /// Nil where the title already names the subject and a glyph would repeat it.
    let symbol: String?
    var tone: DialogTone = .neutral
    var actions: [DialogAction]
    /// The button ↵ fires, normally the primary action.
    var defaultIndex: Int
    /// Resolved when the dialog goes without a choice: Esc, or losing key status.
    var cancelIndex: Int
    /// The caller reads the result back out of the state object it passed in.
    var accessory: DialogAccessory?

    /// Cancel leads a horizontal pair; a vertical choice keeps the caller's semantic order.
    var visualOrder: [Int] {
        guard actions.count < 3 else { return Array(actions.indices) }
        return actions.indices.sorted { rank(of: $0) < rank(of: $1) }
    }

    /// Where ⇥ lands from `index`, walking the buttons as drawn and wrapping at either end.
    func tabStop(after index: Int?, backwards: Bool) -> Int? {
        let order = visualOrder
        guard let first = order.first, let last = order.last else { return nil }
        guard let index, let position = order.firstIndex(of: index) else {
            return backwards ? last : first
        }
        let step = backwards ? order.count - 1 : 1
        return order[(position + step) % order.count]
    }

    private func rank(of index: Int) -> Int {
        actions[index].role == .cancel ? 0 : 1
    }
}

/// A dialog carries at most one control, so the cases are exclusive by construction.
enum DialogAccessory {
    case volume(VolumeState)
    case eventDraft(EventDraftState)
    case snippetArguments(SnippetArgumentsState)
    case text(DialogTextState)
    /// Recording starts once the panel is key, since any window resigning key ends it.
    case hotKey(HotKeyAction, HotKeyManager)
    case extensionContributions(ExtensionContributionConsentState)

    /// Whether ←/→/↑/↓ belong to the control rather than to whatever has focus inside it.
    var claimsArrowKeys: Bool {
        if case .volume = self { return true }
        return false
    }
}
