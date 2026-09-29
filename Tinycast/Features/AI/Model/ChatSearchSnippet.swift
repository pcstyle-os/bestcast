import Foundation

/// The line a sidebar row shows for a chat found by its text: the match with a little around it.
enum ChatSearchSnippet {
    static func make(_ text: String, matching query: String, before: Int = 24, limit: Int = 90)
        -> String?
    {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
            let match = flat.range(of: needle, options: ChatFindIndex.options)
        else { return nil }
        let start =
            flat.index(match.lowerBound, offsetBy: -before, limitedBy: flat.startIndex)
            ?? flat.startIndex
        let end = flat.index(start, offsetBy: limit, limitedBy: flat.endIndex) ?? flat.endIndex
        let stop = max(end, match.upperBound)
        let body = String(flat[start..<stop])
        return (start > flat.startIndex ? "…" : "") + body + (stop < flat.endIndex ? "…" : "")
    }

    /// SQLite's LIKE wildcards, escaped so a query for `50%` finds the text `50%`.
    static func likePattern(_ query: String) -> String {
        var escaped = ""
        for character in query {
            if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%" + escaped + "%"
    }
}
