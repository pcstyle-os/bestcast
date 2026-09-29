import Foundation

/// A launcher fallback: the typed query is its input, so it is offered whatever the query says.
enum Fallback: Hashable, Sendable {
    /// The shipped destinations, in the order a fresh install offers them.
    enum Builtin: String, CaseIterable, Sendable {
        case quickAI
        case searchFiles
        case runShellCommand
        case define

        /// Where its name and glyph come from, so a fallback row reads like the command it runs.
        var command: CommandID {
            switch self {
            case .quickAI: return .quickAI
            case .searchFiles: return .searchFiles
            case .runShellCommand: return .runShellCommand
            case .define: return .define
            }
        }
    }

    case builtin(Builtin)
    case quicklink(UUID)
    /// An extension command a contribution offers; the id is the command's own launcher id.
    case extensionCommand(extensionName: String, commandName: String)

    static let extensionIDPrefix = "extension:"

    /// The row's `AppEntry` id, so a stored order outlives a rename and survives a reinstall.
    var id: String {
        switch self {
        case .builtin(let builtin): return builtin.command.rawValue
        case .quicklink(let id): return Quicklink.entryIDPrefix + id.uuidString.lowercased()
        case .extensionCommand(let extensionName, let commandName):
            return Self.extensionIDPrefix + extensionName + "/" + commandName
        }
    }

    init?(id: String) {
        if let command = CommandID(rawValue: id),
            let builtin = Builtin.allCases.first(where: { $0.command == command })
        {
            self = .builtin(builtin)
        } else if let quicklink = Quicklink.id(fromEntryID: id) {
            self = .quicklink(quicklink)
        } else if id.hasPrefix(Self.extensionIDPrefix),
            case let body = id.dropFirst(Self.extensionIDPrefix.count),
            let slash = body.lastIndex(of: "/"), slash != body.startIndex,
            body.index(after: slash) != body.endIndex
        {
            self = .extensionCommand(
                extensionName: String(body[..<slash]),
                commandName: String(body[body.index(after: slash)...]))
        } else {
            return nil
        }
    }

    /// The footer pill's verb: what ↵ does, in the destination's own words.
    var openVerb: String {
        switch self {
        case .builtin(.quickAI): return "Ask Quick AI"
        case .builtin(.searchFiles): return "Search Files"
        case .builtin(.runShellCommand): return "Run Shell Command"
        case .builtin(.define): return "Define Word"
        case .quicklink: return "Open Quicklink"
        case .extensionCommand: return "Open Command"
        }
    }

    /// Stored order first, then anything it has never seen — a quicklink added today lands last.
    static func ordered(_ available: [Fallback], by storedIDs: [String]) -> [Fallback] {
        var remaining = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = storedIDs.compactMap { remaining.removeValue(forKey: $0) }
        return known + available.filter { remaining[$0.id] != nil }
    }

    /// The section header. A long query is elided in the middle, so “with…” always survives.
    static func sectionTitle(query: String, limit: Int = 72) -> String {
        guard query.count > limit else { return "Use “\(query)” with…" }
        return "Use “\(query.prefix(limit / 2))…\(query.suffix(limit - limit / 2 - 1))” with…"
    }
}
