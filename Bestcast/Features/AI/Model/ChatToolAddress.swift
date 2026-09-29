import Foundation

/// Something a turn can be addressed to with `@`: an integration, an extension or an MCP server.
struct ChatToolSource: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case bestcast
        case raycastExtension
        case mcpServer
    }

    let handle: String
    let title: String
    let symbol: String
    let kind: Kind

    var id: String { handle }
}

/// Leading `@handle`s scope a turn to those sources. An unknown handle is text, not an address.
enum ChatToolAddress {
    static func parse(_ text: String, handles: Set<String>) -> (handles: [String], rest: String) {
        var found: [String] = []
        var rest = Substring(text)
        while true {
            let trimmed = rest.drop { $0 == " " }
            guard trimmed.first == "@" else { break }
            let word = trimmed.dropFirst().prefix { !$0.isWhitespace }
            let handle = word.lowercased()
            guard handles.contains(handle) else { break }
            if !found.contains(handle) { found.append(handle) }
            rest = trimmed.dropFirst(word.count + 1)
        }
        guard !found.isEmpty else { return ([], text) }
        return (found, String(rest.drop { $0 == " " }))
    }

    /// How a message stores its handles; one handle reads back exactly as a single `@server` did.
    static func scope(_ handles: [String]) -> String? {
        handles.isEmpty ? nil : handles.joined(separator: " ")
    }

    /// `nil` for an unaddressed turn, which reaches every source the chat has switched on.
    static func handles(inScope scope: String?) -> Set<String>? {
        scope.map { Set($0.split(separator: " ").map(String.init)) }
    }

    /// What an edited message puts back in the composer ahead of its text.
    static func prefix(forScope scope: String?) -> String {
        guard let scope else { return "" }
        return scope.split(separator: " ").map { "@\($0) " }.joined()
    }

    /// The `@` being typed after any finished addresses, for the picker; `nil` when there is none.
    static func pendingMention(in text: String, handles: Set<String>) -> String? {
        let addressed = parse(text, handles: handles)
        // A finished handle with no space after it is still being typed, so it keeps its picker.
        if let last = addressed.handles.last, addressed.rest.isEmpty, !text.hasSuffix(" ") {
            return last
        }
        let tail = addressed.rest.drop { $0 == " " }
        guard tail.first == "@" else { return nil }
        let word = tail.dropFirst()
        guard !word.contains(where: \.isWhitespace) else { return nil }
        return word.lowercased()
    }

    /// Sources whose handle or title starts with what is typed, handles first.
    static func suggestions(
        for partial: String, among sources: [ChatToolSource]
    ) -> [ChatToolSource] {
        let query = partial.lowercased()
        guard !query.isEmpty else { return sources }
        let byHandle = sources.filter { $0.handle.hasPrefix(query) }
        let byTitle = sources.filter {
            !$0.handle.hasPrefix(query) && $0.title.lowercased().hasPrefix(query)
        }
        return byHandle + byTitle
    }

    /// Replaces the `@` being typed with a finished address and the space that closes it.
    static func complete(_ text: String, with handle: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text + "@\(handle) " }
        return String(text[..<at]) + "@\(handle) "
    }
}
