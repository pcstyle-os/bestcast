import Foundation

/// What a Quick AI turn is told, and the follow-ups its reply offers.
enum QuickAIInstructions {
    static let maxFollowUps = 3

    static let followUpRequest = """
        After answering, suggest up to \(maxFollowUps) short follow-up questions the user might ask \
        next, as a ```choices fence, one per line. Skip the fence when no follow-up would help.
        """

    /// A preset's prompt stands in for the global one, so a preset reads the same on any setup.
    static func compose(
        systemPrompt: String?, systemPromptEnabled: Bool, preset: QuickAIPreset?, followUps: Bool
    ) -> String? {
        let base: String?
        if let preset {
            base = AIInstructions.compose(userPrompt: preset.systemPrompt, isEnabled: true)
        } else {
            base = AIInstructions.compose(userPrompt: systemPrompt, isEnabled: systemPromptEnabled)
        }
        guard followUps else { return base }
        return base.map { $0 + "\n\n" + followUpRequest } ?? followUpRequest
    }

    /// ⇥ walks the chips through the composer: the next after the one shown, wrapping around.
    static func nextChoice(_ choices: [String], current: String, backwards: Bool) -> String? {
        guard !choices.isEmpty else { return nil }
        guard let index = choices.firstIndex(of: current) else {
            return backwards ? choices.last : choices.first
        }
        let step = backwards ? -1 : 1
        return choices[(index + step + choices.count) % choices.count]
    }

    /// Copy Code Block's source: the last fenced block of a reply, or nil when it has none.
    static func lastCodeBlock(in reply: String) -> String? {
        lastCode(in: MarkdownBlock.parse(ChatChoices.split(reply).text))
    }

    private static func lastCode(in blocks: [MarkdownBlock]) -> String? {
        for block in blocks.reversed() {
            switch block {
            case .code(_, let text): return text
            case .quote(let inner):
                if let found = lastCode(in: inner) { return found }
            case .bulletList(let items), .numberedList(_, let items):
                for item in items.reversed() {
                    if let found = lastCode(in: item.blocks) { return found }
                }
            case .heading, .paragraph, .table, .rule: continue
            }
        }
        return nil
    }
}
