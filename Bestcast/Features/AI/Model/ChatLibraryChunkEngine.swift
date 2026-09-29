import Foundation

/// Cuts a file's text into overlapping passages, breaking where the prose itself pauses.
enum ChatLibraryChunkEngine {
    /// Short enough that two fit the on-device window's share, long enough to hold a thought.
    static let length = 900
    /// Carried into the next passage, so a sentence cut at a boundary is whole in one of them.
    static let overlap = 120

    static func chunks(of text: String, path: String, page: Int? = nil) -> [ChatLibraryChunk] {
        let text = normalized(text)
        var chunks: [ChatLibraryChunk] = []
        var start = text.startIndex
        while start < text.endIndex {
            let limit = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
            let stop = limit == text.endIndex ? limit : breakpoint(in: text, from: start, to: limit)
            let passage = text[start..<stop].trimmingCharacters(in: .whitespacesAndNewlines)
            if !passage.isEmpty { chunks.append(ChatLibraryChunk(path: path, page: page, text: passage)) }
            guard stop < text.endIndex else { break }
            start = resume(in: text, before: stop, after: start)
        }
        return chunks
    }

    /// The last paragraph, then sentence, then word end in the window's back half; else the limit.
    private static func breakpoint(
        in text: String, from start: String.Index, to limit: String.Index
    ) -> String.Index {
        let floor = text.index(start, offsetBy: length / 2)
        let window = text[floor..<limit]
        for separator in ["\n\n", ". ", "? ", "! ", "\n", " "] {
            if let found = window.range(of: separator, options: .backwards) {
                return found.upperBound
            }
        }
        return limit
    }

    /// `overlap` back from the cut, moved on to a word start; never at or before the last start.
    private static func resume(
        in text: String, before stop: String.Index, after start: String.Index
    ) -> String.Index {
        var next = text.index(stop, offsetBy: -overlap, limitedBy: start) ?? start
        if next > start, let space = text[next..<stop].firstIndex(where: \.isWhitespace) {
            next = text.index(after: space)
        }
        return next > start && next < stop ? next : stop
    }

    /// Runs of spaces become one and blank lines at most one; a PDF's text is mostly such runs.
    static func normalized(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        var newlines = 0
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\u{2028}", "\u{2029}", "\u{0C}":
                newlines += 1
                pendingSpace = false
            case " ", "\t", "\r", "\u{A0}":
                pendingSpace = true
            case "\u{00}"..."\u{08}", "\u{0B}", "\u{0E}"..."\u{1F}":
                continue
            default:
                if newlines > 0, !result.isEmpty {
                    result.append(contentsOf: String(repeating: "\n", count: min(newlines, 2)).unicodeScalars)
                } else if pendingSpace, !result.isEmpty {
                    result.append(" ")
                }
                newlines = 0
                pendingSpace = false
                result.append(scalar)
            }
        }
        return String(result)
    }
}
