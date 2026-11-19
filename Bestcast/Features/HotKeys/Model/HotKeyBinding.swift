import Foundation

/// What an action is bound to. See docs/features/hotkeys.md.
enum HotKeyBinding: Hashable, Sendable, Codable {
    case combo(KeyShortcut)
    case doubleTap(DoubleTapModifier)
    case globe
    case doubleGlobe
    /// Hold ✦, press `leader`, then `key`: a keycode pair. docs/features/hotkeys.md#hyper-layers
    case hyperLayer(leader: Int, key: Int)

    /// One string per keycap, so every display site renders all bindings through one path.
    @MainActor var keycaps: [String] {
        switch self {
        case .combo(let shortcut): shortcut.keycaps
        case .doubleTap(let modifier): modifier.keycaps
        case .globe: ["🌐︎"]
        case .doubleGlobe: ["🌐︎", "🌐︎"]
        case .hyperLayer(let leader, let key):
            [HyperKeyPhysicalKey.hyperGlyph] + [leader, key].flatMap {
                KeyShortcut(carbonKeyCode: $0, carbonModifiers: 0).keycaps
            }
        }
    }

    var shortcut: KeyShortcut? {
        if case .combo(let shortcut) = self { return shortcut }
        return nil
    }

    var isHyperLayer: Bool {
        if case .hyperLayer = self { return true }
        return false
    }

    var usesModifierTapMonitor: Bool {
        switch self {
        case .combo, .hyperLayer: false
        case .doubleTap, .globe, .doubleGlobe: true
        }
    }
}
