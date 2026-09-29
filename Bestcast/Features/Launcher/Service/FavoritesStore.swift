import Foundation

/// Favorites lead the empty list and pins lead a typed search; one cleanup drops a key from both.
@MainActor
@Observable
final class FavoritesStore {
    private let defaults = UserDefaults.standard
    private let key = "favoriteApps"
    private let pinnedDefaultsKey = "pinnedLauncherItems"

    private(set) var keys: [String]
    /// Settable so settings.json can bind it; the order is only the order they were pinned in.
    var pinnedKeys: [String] {
        didSet {
            guard pinnedKeys != oldValue else { return }
            revision &+= 1
            defaults.set(pinnedKeys, forKey: pinnedDefaultsKey)
        }
    }
    /// AppIndex includes this in its result key, invalidating a list when either list changes.
    private(set) var revision = 0

    init() {
        keys = defaults.stringArray(forKey: key) ?? []
        pinnedKeys = defaults.stringArray(forKey: pinnedDefaultsKey) ?? []
    }

    func key(for app: AppEntry) -> String { app.preferenceKey }

    func isFavorite(_ app: AppEntry) -> Bool { keys.contains(key(for: app)) }

    /// Replace the whole favorites list at once (used when importing a settings backup).
    func replace(keys newKeys: [String]) {
        keys = newKeys
        commit()
    }

    func remove(keys removedKeys: Set<String>) {
        guard !removedKeys.isEmpty else { return }
        pinnedKeys.removeAll { removedKeys.contains($0) }
        let updated = keys.filter { !removedKeys.contains($0) }
        guard updated != keys else { return }
        keys = updated
        commit()
    }

    func toggle(_ app: AppEntry) {
        let k = key(for: app)
        if let index = keys.firstIndex(of: k) {
            keys.remove(at: index)
        } else {
            keys.append(k)
        }
        commit()
    }

    func isPinned(_ app: AppEntry) -> Bool { pinnedKeys.contains(key(for: app)) }

    func togglePin(_ app: AppEntry) {
        let k = key(for: app)
        if pinnedKeys.contains(k) { pinnedKeys.removeAll { $0 == k } } else { pinnedKeys.append(k) }
    }

    /// The pair comes from the visible order, so hidden entries keep their slots.
    func exchange(_ first: String, with second: String) {
        guard let a = keys.firstIndex(of: first), let b = keys.firstIndex(of: second), a != b else {
            return
        }
        keys.swapAt(a, b)
        commit()
    }

    private func commit() {
        revision &+= 1
        defaults.set(keys, forKey: key)
    }

    /// Split `apps` into favorites (in stored order) and the rest (order preserved).
    func ordered(_ apps: [AppEntry]) -> (favorites: [AppEntry], rest: [AppEntry]) {
        guard !keys.isEmpty else { return ([], apps) }
        let byKey = Dictionary(
            apps.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let favorites = keys.compactMap { byKey[$0] }
        let favoriteKeys = Set(keys)
        let rest = apps.filter { !favoriteKeys.contains(key(for: $0)) }
        return (favorites, rest)
    }
}
