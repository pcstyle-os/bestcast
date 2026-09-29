import Foundation

/// AI Commands as a file, in Raycast's shape so an export from either app imports into the other.
enum AICommandArchive {
    struct Imported: Equatable, Sendable {
        let commands: [CustomQuickAction]
        /// Already present, by name and prompt, so a second import of one file adds nothing.
        let duplicates: Int
    }

    /// Raycast writes `title`; a hand-written file often says `name`. Its `model` is never read.
    private struct Record: Codable {
        var title: String?
        var name: String?
        var prompt: String?
        var icon: String?
        var creativity: String?
        var output: String?
    }

    static func encode(_ commands: [CustomQuickAction]) throws -> Data {
        let records = commands.map {
            Record(
                title: $0.name, prompt: $0.instructions, icon: $0.iconSymbol,
                creativity: $0.creativity.rawValue, output: $0.output.rawValue)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(records)
    }

    /// `isKnownSymbol` is injected: Raycast's icon names are not SF Symbols, and only AppKit knows.
    static func decode(
        _ data: Data, existing: [CustomQuickAction], now: Date,
        isKnownSymbol: (String) -> Bool
    ) throws(AICommandArchiveError) -> Imported {
        let decoder = JSONDecoder()
        let records: [Record]
        if let list = try? decoder.decode([Record].self, from: data) {
            records = list
        } else if let single = try? decoder.decode(Record.self, from: data), single.prompt != nil {
            records = [single]
        } else {
            throw .unreadable
        }

        var known = existing.map { Key(name: $0.name, prompt: $0.instructions) }
        var commands: [CustomQuickAction] = []
        var duplicates = 0
        for record in records {
            guard let name = trimmed(record.title ?? record.name),
                let prompt = trimmed(record.prompt)
            else { continue }
            let key = Key(name: name, prompt: prompt)
            guard !known.contains(key) else {
                duplicates += 1
                continue
            }
            known.append(key)
            let icon = trimmed(record.icon).flatMap { isKnownSymbol($0) ? $0 : nil }
            commands.append(
                CustomQuickAction(
                    name: name, iconSymbol: icon, instructions: prompt,
                    output: record.output.flatMap(AICommandOutput.init(rawValue:)) ?? .panel,
                    creativity: record.creativity.flatMap(AICommandCreativity.init(raycast:))
                        ?? .medium,
                    createdAt: now.addingTimeInterval(Double(commands.count) / 1_000)))
        }
        guard !commands.isEmpty || duplicates > 0 else { throw .empty }
        return Imported(commands: commands, duplicates: duplicates)
    }

    private struct Key: Equatable {
        let name: String
        let prompt: String

        init(name: String, prompt: String) {
            self.name = name.lowercased()
            self.prompt = prompt
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }
}

enum AICommandArchiveError: Error, LocalizedError, Equatable {
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That file isn't a list of AI Commands."
        case .empty: return "That file has no AI Commands with both a title and a prompt."
        }
    }
}
