import Foundation

/// Whether a root-search query reads as something to ask rather than something to open.
enum QuickAIQuestion {
    static let openers: Set<String> = [
        "what", "why", "how", "who", "when", "where", "can", "should", "is", "are", "does",
        "explain", "write",
    ]

    static func looksLikeQuestion(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: \.isLetter) else { return false }
        if trimmed.hasSuffix("?") { return true }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        // One word is still a name being typed: "Where" could be the start of an app called Where.
        guard words.count >= 2, let first = words.first else { return false }
        let opener = first.lowercased().split(whereSeparator: { $0 == "'" || $0 == "’" }).first
        return opener.map { openers.contains(String($0)) } ?? false
    }
}
