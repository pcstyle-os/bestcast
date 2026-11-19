import CoreGraphics
import Foundation

enum KeystrokeOverlaySize: String, CaseIterable, Sendable {
    case small, medium, large

    var pointSize: CGFloat {
        switch self {
        case .small: 15
        case .medium: 20
        case .large: 28
        }
    }
}

enum KeystrokeFilter: String, CaseIterable, Sendable {
    case allKeys, shortcuts
}

/// One key press as the overlay reads it.
struct KeystrokePress: Equatable, Sendable {
    /// Modifiers first, Hyper already collapsed to ✦, the key last.
    var keycaps: [String]
    /// The visible character it typed; nil whenever ⌘, ⌃, ⌥ or ✦ is held.
    var typed: String?
    /// Holds ⌘, ⌃, ⌥ or ✦, or is a function key: what Shortcuts Only keeps.
    var isShortcut: Bool
}

/// What the overlay shows. See docs/features/keystroke-overlay.md.
struct KeystrokeFeed: Equatable, Sendable {
    struct Item: Equatable, Identifiable, Sendable {
        enum Content: Equatable, Sendable {
            case text(String)
            case keys([String], count: Int)
        }

        let id: Int
        var content: Content
        var updated: Date
    }

    /// How long an item stays after its last press.
    static let linger: TimeInterval = 2
    /// A pause longer than this starts a new item instead of extending the last one.
    static let runGap: TimeInterval = 1
    static let maximumItems = 4
    /// A run keeps its tail, so a long sentence scrolls rather than widening the overlay.
    static let maximumRun = 24

    private(set) var items: [Item] = []
    private var nextID = 0

    mutating func record(_ press: KeystrokePress, at now: Date, filter: KeystrokeFilter) {
        guard filter == .allKeys || press.isShortcut else { return }
        prune(at: now)
        let last = items.indices.last.flatMap { now.timeIntervalSince(items[$0].updated) <= Self.runGap ? $0 : nil }
        if let typed = press.typed {
            if let last, case .text(let run) = items[last].content {
                items[last].content = .text(String((run + typed).suffix(Self.maximumRun)))
                items[last].updated = now
                return
            }
            // Leading blanks would draw an empty pill, so a space with no run shows as its key.
            if !typed.allSatisfy(\.isWhitespace) {
                append(.text(typed), at: now)
                return
            }
        }
        if let last, case .keys(let keycaps, let count) = items[last].content, keycaps == press.keycaps {
            items[last].content = .keys(keycaps, count: count + 1)
            items[last].updated = now
            return
        }
        append(.keys(press.keycaps, count: 1), at: now)
    }

    mutating func prune(at now: Date) {
        items.removeAll { now.timeIntervalSince($0.updated) > Self.linger }
    }

    /// When the oldest item left will expire, so the overlay knows when to look again.
    var nextExpiry: Date? {
        items.map(\.updated).min().map { $0.addingTimeInterval(Self.linger) }
    }

    private mutating func append(_ content: Item.Content, at now: Date) {
        items.append(Item(id: nextID, content: content, updated: now))
        nextID += 1
        if items.count > Self.maximumItems { items.removeFirst(items.count - Self.maximumItems) }
    }
}
