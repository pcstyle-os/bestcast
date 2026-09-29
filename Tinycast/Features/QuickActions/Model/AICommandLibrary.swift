import Foundation

/// Ready-made AI Commands a reader adds in one click; each becomes an ordinary custom command.
enum AICommandLibrary {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case writing = "Writing"
        case summaries = "Summaries"
        case code = "Code"
        case other = "Other"

        var id: String { rawValue }
    }

    struct Entry: Identifiable, Sendable, Equatable {
        let id: String
        let category: Category
        let name: String
        let symbol: String
        let prompt: String
        let output: AICommandOutput
        let creativity: AICommandCreativity

        func makeCommand(now: Date, id: UUID = UUID()) -> CustomQuickAction {
            CustomQuickAction(
                id: id, name: name, iconSymbol: symbol, instructions: prompt, output: output,
                creativity: creativity, createdAt: now)
        }

        /// Matched by name as well as prompt, so an edited copy still reads as added.
        func isAdded(in commands: [CustomQuickAction]) -> Bool {
            commands.contains {
                $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.instructions == prompt
            }
        }
    }

    static func entries(in category: Category) -> [Entry] {
        entries.filter { $0.category == category }
    }

    static let entries: [Entry] = writing + summaries + code + other

    private static let writing: [Entry] = [
        Entry(
            id: "improve-writing", category: .writing, name: "Improve Writing",
            symbol: "wand.and.stars",
            prompt: """
                Improve the writing of the text below. Fix mistakes, tighten the wording and make \
                it read clearly, keeping the writer's meaning, voice and language.

                Text:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "fix-spelling-grammar", category: .writing, name: "Fix Spelling & Grammar",
            symbol: "text.badge.checkmark",
            prompt: """
                Correct the spelling, grammar and punctuation of the text below. Change only what \
                is wrong and keep its wording, formatting and line breaks. If nothing is wrong, \
                return it unchanged.

                Text:
                {selection}
                """,
            output: .replace, creativity: .low),
        Entry(
            id: "make-shorter", category: .writing, name: "Make Shorter", symbol: "scissors",
            prompt: """
                Make the text below about half as long, keeping every point that matters and the \
                writer's voice and language.

                Text:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "make-longer", category: .writing, name: "Make Longer", symbol: "text.append",
            prompt: """
                Expand the text below with detail and examples that support what it already \
                says, keeping the writer's voice and language. Do not invent facts.

                Text:
                {selection}
                """,
            output: .panel, creativity: .medium),
        tone("professional", "Professional", symbol: "briefcase"),
        tone("casual", "Casual", symbol: "cup.and.saucer"),
        tone("friendly", "Friendly", symbol: "face.smiling"),
        Entry(
            id: "simplify", category: .writing, name: "Simplify",
            symbol: "line.3.horizontal.decrease",
            prompt: """
                Rewrite the text below in plain, simple language: short sentences, everyday \
                words, no jargon. Keep its meaning and language.

                Text:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "explain-simply", category: .writing, name: "Explain This in Simple Terms",
            symbol: "lightbulb",
            prompt: """
                Explain what the text below means in simple terms, as to a smart reader who is \
                new to the subject. Define any term they would not know.

                Text:
                {selection}
                """,
            output: .panel, creativity: .medium),
        Entry(
            id: "title-case", category: .writing, name: "Title Case", symbol: "textformat",
            prompt: """
                Convert the text below to title case, following the Chicago Manual of Style. \
                Change nothing else.

                Text:
                {selection}
                """,
            output: .replace, creativity: .low),
        Entry(
            id: "emojify", category: .writing, name: "Emojify", symbol: "face.smiling.inverse",
            prompt: """
                Add fitting emoji to the text below without changing its words. Use them \
                sparingly, where they add feeling.

                Text:
                {selection}
                """,
            output: .replace, creativity: .high)
    ]

    private static let summaries: [Entry] = [
        Entry(
            id: "summarize", category: .summaries, name: "Summarize", symbol: "doc.plaintext",
            prompt: """
                Summarize the text below in a short paragraph. Lead with the most important \
                point and use the text's own terms.

                Text:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "bullet-summary", category: .summaries, name: "Bullet-Point Summary",
            symbol: "list.bullet",
            prompt: """
                Summarize the text below as three to seven short bullet points, most important \
                first.

                Text:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "action-items", category: .summaries, name: "Find Action Items",
            symbol: "checklist",
            prompt: """
                List every action item in the text below as a checklist. Name the owner and the \
                deadline where the text gives them. If there are none, say so.

                Text:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "reply", category: .summaries, name: "Reply to Email or Message",
            symbol: "arrowshape.turn.up.left",
            prompt: """
                Write a reply to the message below. Answer what it asks, match its tone and \
                language, and keep it brief. Leave a [placeholder] for anything only I can know.

                Message:
                {selection}
                """,
            output: .panel, creativity: .medium)
    ]

    private static let code: [Entry] = [
        Entry(
            id: "explain-code", category: .code, name: "Explain Code", symbol: "curlybraces",
            prompt: """
                Explain what the code below does, step by step, then note anything surprising \
                about it.

                Code:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "find-bugs", category: .code, name: "Find Bugs in Code", symbol: "ladybug",
            prompt: """
                Review the code below for bugs: logic errors, edge cases, crashes and security \
                problems. For each, say where it is, why it is wrong and how to fix it. If you \
                find none, say so.

                Code:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "add-comments", category: .code, name: "Add Comments to Code",
            symbol: "text.bubble",
            prompt: """
                Add concise comments to the code below that explain why it does what it does, \
                not what each line says. Return the whole code with the comments added.

                Code:
                {selection}
                """,
            output: .panel, creativity: .low),
        convert(to: "TypeScript", id: "convert-typescript",
            symbol: "chevron.left.forwardslash.chevron.right"),
        convert(to: "Swift", id: "convert-swift", symbol: "swift"),
        Entry(
            id: "write-regex", category: .code, name: "Write Regex", symbol: "asterisk",
            prompt: """
                Write a regular expression that matches what the text below describes or \
                exemplifies. Give the pattern first, then one line on how it works.

                Text:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "shell-command", category: .code, name: "Shell Command", symbol: "terminal",
            prompt: """
                Write one macOS zsh command that does this: {argument name="task"}

                Give the command first, then one line on what it does. Warn if it deletes or \
                overwrites anything.
                """,
            output: .panel, creativity: .low)
    ]

    private static let other: [Entry] = [
        Entry(
            id: "translate", category: .other, name: "Translate to Language", symbol: "globe",
            prompt: """
                Translate the text below into {argument name="language"}. Keep its meaning, tone \
                and formatting.

                Text:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "brainstorm", category: .other, name: "Brainstorm Ideas", symbol: "brain",
            prompt: """
                Brainstorm ten varied, specific ideas for: {argument name="topic"}

                One line each, the boldest last.
                """,
            output: .panel, creativity: .high),
        Entry(
            id: "define-word", category: .other, name: "Define Selected Word",
            symbol: "book.closed",
            prompt: """
                Define the word or phrase below as it is most commonly used, give its part of \
                speech, and show it in one example sentence.

                Word:
                {selection}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "eli5", category: .other, name: "Explain Like I'm Five", symbol: "teddybear",
            prompt: """
                Explain the text below as you would to a curious five-year-old: short sentences, \
                a familiar comparison, no jargon.

                Text:
                {selection}
                """,
            output: .panel, creativity: .medium),
        Entry(
            id: "proofread-clipboard", category: .other, name: "Proofread Against Clipboard",
            symbol: "doc.on.clipboard",
            prompt: """
                Check the selected text against the reference copied to the clipboard. List every \
                place where it contradicts, misquotes or leaves out something from the \
                reference. If they agree, say so.

                Selected text:
                {selection}

                Reference:
                {clipboard}
                """,
            output: .panel, creativity: .low),
        Entry(
            id: "summarize-web-page", category: .other, name: "Summarize Web Page",
            symbol: "safari",
            prompt: """
                Summarize the web page open in my browser: the main point first, then the key \
                details as short bullets.

                {browser-tab}
                """,
            output: .quickAI, creativity: .low)
    ]

    private static func tone(_ id: String, _ tone: String, symbol: String) -> Entry {
        Entry(
            id: "tone-" + id, category: .writing, name: "Change Tone to " + tone, symbol: symbol,
            prompt: """
                Rewrite the text below in a \(tone.lowercased()) tone, keeping its meaning, \
                length and language.

                Text:
                {selection}
                """,
            output: .panel, creativity: .medium)
    }

    private static func convert(to language: String, id: String, symbol: String) -> Entry {
        Entry(
            id: id, category: .code, name: "Convert to " + language, symbol: symbol,
            prompt: """
                Convert the code below to idiomatic \(language). Keep its behaviour exactly, and \
                return only the converted code.

                Code:
                {selection}
                """,
            output: .panel, creativity: .low)
    }
}
