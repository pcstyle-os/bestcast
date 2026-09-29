import Foundation

enum ExtensionConsoleLevel: String, Sendable, CaseIterable, Identifiable {
    case log, warn, error, timing

    var id: Self { self }

    /// `info`, `debug` and anything unknown read as plain log lines.
    init(runtimeLevel: String) {
        self = Self(rawValue: runtimeLevel) ?? .log
    }

    var title: String {
        switch self {
        case .log: "Log"
        case .warn: "Warnings"
        case .error: "Errors"
        case .timing: "Timing"
        }
    }
}

struct ExtensionConsoleEntry: Sendable, Hashable, Identifiable {
    let id: Int
    let date: Date
    let level: ExtensionConsoleLevel
    let message: String
    let stack: String?

    var text: String {
        let head = "[\(level.rawValue)] \(message)"
        return stack.map { "\(head)\n\($0)" } ?? head
    }
}

/// One extension's recent output, in memory only: it may hold whatever a command printed.
struct ExtensionConsoleBuffer: Sendable {
    static let defaultCapacity = 500
    /// Per message and per stack, so 500 lines stay small whatever a command prints.
    static let maximumLength = 16 * 1024

    let capacity: Int
    private(set) var entries: [ExtensionConsoleEntry] = []
    private var nextID = 0

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    mutating func append(
        level: ExtensionConsoleLevel, message: String, stack: String? = nil, at date: Date
    ) {
        entries.append(
            ExtensionConsoleEntry(
                id: nextID, date: date, level: level, message: Self.clipped(message),
                stack: stack.map(Self.clipped)))
        nextID += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    private static func clipped(_ text: String) -> String {
        let head = text.prefix(maximumLength)
        return head.endIndex < text.endIndex ? String(head) + "…" : text
    }

    mutating func clear() {
        entries.removeAll()
    }

    /// A nil level is every level; the query matches the message or the stack, case-insensitively.
    func filtered(level: ExtensionConsoleLevel?, query: String) -> [ExtensionConsoleEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (level == nil || entry.level == level)
                && (needle.isEmpty || entry.message.localizedCaseInsensitiveContains(needle)
                    || entry.stack?.localizedCaseInsensitiveContains(needle) == true)
        }
    }

    static func text(of entries: [ExtensionConsoleEntry]) -> String {
        entries.map(\.text).joined(separator: "\n")
    }
}
