import Foundation

/// A named Quick AI setup: its own system prompt, model and web search, picked per chat.
struct QuickAIPreset: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var systemPrompt: String
    /// Nil keeps whatever model Quick AI would use anyway.
    var model: AIModelSelection?
    var webSearch: Bool

    init(
        id: UUID = UUID(), name: String, systemPrompt: String = "",
        model: AIModelSelection? = nil, webSearch: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.model = model
        self.webSearch = webSearch
    }

    static let entryPrefix = "ai-preset:"

    var entryID: String { Self.entryID(for: id) }

    static func entryID(for id: UUID) -> String { entryPrefix + id.uuidString.lowercased() }

    static func id(fromEntryID entryID: String) -> UUID? {
        guard entryID.hasPrefix(entryPrefix) else { return nil }
        return UUID(uuidString: String(entryID.dropFirst(entryPrefix.count)))
    }

    var launcherName: String { "Quick AI: \(name)" }
}
