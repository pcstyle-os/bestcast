import Foundation

/// A category that is off runs nothing, so it gates shortcuts as well as the list.
@MainActor
@Observable
final class VisibilityStore {
    private let defaults = UserDefaults.standard
    private let itemsKey = "hiddenLauncherItems"
    private let kindsKey = "hiddenLauncherKinds"
    private let disabledItemsKey = "disabledLauncherItems"

    private(set) var hiddenItemKeys: Set<String>
    /// Off in every path, hotkey and deeplink included, where a hidden item only leaves the list.
    private(set) var disabledItemKeys: Set<String>
    private(set) var disabledKinds: Set<String>
    /// AppIndex includes this in its result key, invalidating a list when the visible set moves.
    private(set) var revision = 0

    init() {
        hiddenItemKeys = Set(defaults.stringArray(forKey: itemsKey) ?? [])
        disabledKinds = Set(defaults.stringArray(forKey: kindsKey) ?? [])
        disabledItemKeys = Set(defaults.stringArray(forKey: disabledItemsKey) ?? [])
    }

    /// Replace every exclusion set at once (used when importing a settings backup).
    func replace(hiddenItems: [String], disabledKinds newKinds: [String], disabledItems: [String]) {
        hiddenItemKeys = Set(hiddenItems)
        disabledKinds = Set(newKinds)
        disabledItemKeys = Set(disabledItems)
        revision &+= 1
        defaults.set(Array(hiddenItemKeys), forKey: itemsKey)
        defaults.set(Array(disabledKinds), forKey: kindsKey)
        defaults.set(Array(disabledItemKeys), forKey: disabledItemsKey)
    }

    func key(for entry: AppEntry) -> String { entry.preferenceKey }

    /// Whether the entry appears in the launcher: its category and the item itself must be on.
    func isVisible(_ entry: AppEntry) -> Bool {
        isCategoryEnabled(entry) && isItemVisible(entry) && !isDisabled(entry)
    }

    /// An entry a feature pane owns answers to that feature's switch, so no category gates it.
    private func isCategoryEnabled(_ entry: AppEntry) -> Bool {
        entry.settingsOwner != nil || isKindEnabled(entry.kind)
    }

    func isItemVisible(_ entry: AppEntry) -> Bool {
        !hiddenItemKeys.contains(key(for: entry))
    }

    func setItemVisible(_ visible: Bool, for entry: AppEntry) {
        let k = key(for: entry)
        if visible { hiddenItemKeys.remove(k) } else { hiddenItemKeys.insert(k) }
        revision &+= 1
        defaults.set(Array(hiddenItemKeys), forKey: itemsKey)
    }

    func isDisabled(_ entry: AppEntry) -> Bool {
        disabledItemKeys.contains(key(for: entry))
    }

    func setDisabled(_ disabled: Bool, key: String) {
        let previous = disabledItemKeys
        if disabled { disabledItemKeys.insert(key) } else { disabledItemKeys.remove(key) }
        guard disabledItemKeys != previous else { return }
        revision &+= 1
        defaults.set(Array(disabledItemKeys), forKey: disabledItemsKey)
    }

    func removeItemKeys(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        let previous = (hiddenItemKeys, disabledItemKeys)
        hiddenItemKeys.subtract(keys)
        disabledItemKeys.subtract(keys)
        guard hiddenItemKeys != previous.0 || disabledItemKeys != previous.1 else { return }
        revision &+= 1
        defaults.set(Array(hiddenItemKeys), forKey: itemsKey)
        defaults.set(Array(disabledItemKeys), forKey: disabledItemsKey)
    }

    func isKindEnabled(_ kind: AppEntry.Kind) -> Bool {
        !disabledKinds.contains(kind.rawValue)
    }

    func setKindEnabled(_ enabled: Bool, for kind: AppEntry.Kind) {
        if enabled { disabledKinds.remove(kind.rawValue) } else { disabledKinds.insert(kind.rawValue) }
        revision &+= 1
        defaults.set(Array(disabledKinds), forKey: kindsKey)
    }

    /// A feature carrying its own switch is not this store's to gate.
    func allowsHotKey(_ action: HotKeyAction) -> Bool {
        switch action {
        case .app: isKindEnabled(.application)
        case .settingsPane: isKindEnabled(.systemSettings)
        case .systemAction: isKindEnabled(.systemAction)
        case .command(let id): id.owner == nil ? isKindEnabled(.command) : true
        case .togglePalette, .quickAction, .customCommand, .windowCommand, .customWindowSize,
            .windowLayout, .windowRoom, .quicklink, .appleShortcut, .extensionCommand, .aiPreset,
            .extensionTrigger:
            true
        }
    }
}
