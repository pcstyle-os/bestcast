import Foundation

struct CustomQuickAction: Codable, Hashable, Identifiable, Sendable {
    static let entryIDPrefix = "quick-action:"
    static let sfSymbol = "wand.and.stars"

    let id: UUID
    var name: String
    var iconSymbol: String?
    /// The prompt; placeholders make it an AI Command, none makes it a plain selection transform.
    var instructions: String
    var output: AICommandOutput
    var creativity: AICommandCreativity
    var createdAt: Date

    init(
        id: UUID = UUID(), name: String, iconSymbol: String? = nil, instructions: String,
        output: AICommandOutput = .panel, creativity: AICommandCreativity = .medium,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.iconSymbol = iconSymbol
        self.instructions = instructions
        self.output = output
        self.creativity = creativity
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconSymbol, instructions, output, creativity, createdAt
        case previewsResult
    }

    /// A file written before AI Commands carries `previewsResult`, and that choice is kept.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        iconSymbol = try container.decodeIfPresent(String.self, forKey: .iconSymbol)
        instructions = try container.decode(String.self, forKey: .instructions)
        let previews = try container.decodeIfPresent(Bool.self, forKey: .previewsResult) ?? true
        output =
            try container.decodeIfPresent(AICommandOutput.self, forKey: .output)
            ?? (previews ? .panel : .replace)
        creativity =
            try container.decodeIfPresent(AICommandCreativity.self, forKey: .creativity) ?? .medium
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(iconSymbol, forKey: .iconSymbol)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(output, forKey: .output)
        try container.encode(creativity, forKey: .creativity)
        try container.encode(createdAt, forKey: .createdAt)
    }

    var symbol: String { iconSymbol ?? Self.sfSymbol }

    var entryID: String { Self.entryIDPrefix + id.uuidString.lowercased() }

    static func id(fromEntryID entryID: String) -> UUID? {
        guard entryID.hasPrefix(entryIDPrefix) else { return nil }
        return UUID(uuidString: String(entryID.dropFirst(entryIDPrefix.count)))
    }

    static func precedes(_ lhs: CustomQuickAction, _ rhs: CustomQuickAction) -> Bool {
        lhs.createdAt != rhs.createdAt
            ? lhs.createdAt < rhs.createdAt
            : lhs.id.uuidString < rhs.id.uuidString
    }
}

enum CustomQuickActionError: Error, LocalizedError, Equatable {
    case emptyName
    case emptyInstructions
    case invalidCharacter
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Give the action a name."
        case .emptyInstructions: return "Tell the model what the action should do."
        case .invalidCharacter: return "The name contains a character Tinycast can't store."
        case .storageUnavailable: return "Tinycast couldn't save to its actions file."
        }
    }
}
