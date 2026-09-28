import Foundation

/// The two built-ins a Claude turn may use once the reader has opted into web search, and no other.
enum ClaudeWebSearchLaunch {
    static let tools = ["WebSearch", "WebFetch"]
    /// A search and the answer after it are separate requests, so one request cannot hold both.
    static let searchTurns = 10

    /// `--tools` names the built-ins that exist at all; the allow rule is what runs them unasked.
    static func builtInArguments(webSearch: Bool) -> [String] {
        guard webSearch else { return ["--tools", ""] }
        let list = tools.joined(separator: ",")
        return ["--tools", list, "--allowedTools", list]
    }

    /// A turn with no server to run: one request, or the search cap with every MCP tool denied.
    static func argumentsWithoutServers(webSearch: Bool) -> [String] {
        guard webSearch else { return ["--disallowedTools", "*", "--max-turns", "1"] }
        return [
            "--disallowedTools", "mcp__*",
            "--permission-mode", "default",
            "--max-turns", "\(searchTurns)"
        ]
    }

    static func kind(of tool: String) -> AIWebLookup {
        tool == "WebFetch" ? .fetch : .search
    }

    /// What a search row names: the query, or for a fetch the page it read.
    static func label(tool: String, input: [String: Any]?) -> String? {
        let value = (input?[kind(of: tool) == .fetch ? "url" : "query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}
