import Foundation

/// What snippets ask a model: a reply for an `{ai}` placeholder, or a whole template to start from.
enum SnippetAIPrompt {
    /// Past this the reader has moved on, so the placeholder expands empty instead of waiting.
    static let fillTimeout = Duration.seconds(10)
    static let fillMaxOutputTokens = 512
    static let draftMaxOutputTokens = 1_024

    static let fillInstructions = """
        Your reply is typed straight into another app at the cursor. Reply with only that text — \
        no preamble, no explanation, no quotation marks and no code fences. Keep it short unless \
        the request asks for more.
        """

    /// Lists only the tokens a fresh template can use unaided: no `{ai}`, no `{snippet}` by name.
    static let draftInstructions = """
        You write snippet templates for a Mac text expander. Return only the template body — no \
        title, no explanation and no code fences.

        A template is plain text with placeholders in braces. Use only these, and only where they \
        help:
        - {cursor} — where the caret lands after expansion; at most once
        - {clipboard} — the text on the clipboard
        - {selection} — the text selected when the snippet expands
        - {date}, {time}, {datetime}, {day} — the current date, time, both, or weekday; add \
        offset="+1d" or format="yyyy-MM-dd" when the request needs it
        - {uuid} — a new UUID
        - {argument name="Name"} — a value typed when the snippet expands; add default="…" or \
        options="A, B" when useful. Reuse the same name to repeat a value.
        Never invent other placeholders, and never use braces for anything else.
        """

    static func draftMessage(description: String) -> String {
        "Write a snippet template for this:\n" + description
    }

    /// Models fence a template out of habit even when told not to; the fence is never content.
    static func cleaned(_ reply: String) -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].hasPrefix("```"),
            lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```"
        else { return trimmed }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
