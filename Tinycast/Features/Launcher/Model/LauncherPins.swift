import Foundation

/// Pinned rows lead a typed search; everything keeps its relevance order within its half.
enum LauncherPins {
    static func leading<Item>(_ items: [Item], pinned: Set<String>, key: (Item) -> String) -> [Item] {
        guard !pinned.isEmpty else { return items }
        var lead: [Item] = []
        var rest: [Item] = []
        for item in items {
            if pinned.contains(key(item)) { lead.append(item) } else { rest.append(item) }
        }
        return lead + rest
    }

    /// A hand-edited list may repeat or blank a key; the first spelling of each wins.
    static func normalized(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
