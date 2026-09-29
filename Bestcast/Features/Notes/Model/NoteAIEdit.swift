import Foundation

/// The passage an AI action works on: the selection when there is one, otherwise the whole note.
struct NoteAITarget: Sendable, Equatable {
    /// The same ceiling Quick Actions keep, so a note is never a larger prompt than a selection.
    static let maxBytes = 32_768

    /// UTF-16, against the note source it was resolved from.
    let range: NSRange
    let text: String
    let isSelection: Bool

    var isTooLong: Bool { text.utf8.count > Self.maxBytes }

    /// Nil when there is nothing but whitespace to work on.
    static func resolve(source: String, selection: NSRange) -> NoteAITarget? {
        let note = source as NSString
        if selection.location != NSNotFound, selection.length > 0,
            NSMaxRange(selection) <= note.length
        {
            let text = note.substring(with: selection)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return NoteAITarget(range: selection, text: text, isSelection: true)
            }
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NoteAITarget(
            range: NSRange(location: 0, length: note.length), text: source, isSelection: false)
    }
}

/// Turns an accepted reply into the one edit `NoteTextView.performEdit` applies as one undo step.
enum NoteAIEdit {
    /// The reply ends up selected, so the reader sees exactly what changed and ⌘Z takes it back.
    static func plan(
        reply: String, for target: NoteAITarget, placement: NoteAIPlacement, in source: String
    ) -> NoteEditPlan {
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        switch placement {
        case .replace:
            // The passage's own surrounding whitespace is layout, not content the model rewrote.
            let leading = String(target.text.prefix { $0.isWhitespace })
            let trailing = String(target.text.reversed().prefix { $0.isWhitespace }.reversed())
            return NoteEditPlan(
                range: target.range,
                replacement: leading + reply + trailing,
                selection: NSRange(
                    location: target.range.location + leading.utf16.count,
                    length: reply.utf16.count))
        case .continueAfter:
            let end = NSMaxRange(target.range)
            let before = target.text.last.map { $0.isWhitespace } == false ? " " : ""
            let after = startsWithNonWhitespace(source, at: end) ? " " : ""
            return insertion(reply, at: end, before: before, after: after)
        case .insertBelow:
            let end = NSMaxRange(target.range)
            let trailingBreaks = target.text.reversed().prefix { $0 == "\n" }.count
            let before = String(repeating: "\n", count: max(0, 2 - trailingBreaks))
            let after = startsWithNonWhitespace(source, at: end) ? "\n\n" : ""
            return insertion(reply, at: end, before: before, after: after)
        }
    }

    private static func insertion(
        _ reply: String, at location: Int, before: String, after: String
    ) -> NoteEditPlan {
        NoteEditPlan(
            range: NSRange(location: location, length: 0),
            replacement: before + reply + after,
            selection: NSRange(location: location + before.utf16.count, length: reply.utf16.count))
    }

    private static func startsWithNonWhitespace(_ source: String, at location: Int) -> Bool {
        let note = source as NSString
        guard location < note.length else { return false }
        let next = note.substring(with: note.rangeOfComposedCharacterSequence(at: location))
        return next.first.map { !$0.isWhitespace } ?? false
    }
}
