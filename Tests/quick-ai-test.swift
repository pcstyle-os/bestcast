import Foundation

/// Quick AI's pure rules: what reads as a question, what a turn is told, and what a reply offers.
@main
@MainActor
struct QuickAITests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        questions()
        instructions()
        followUps()
        codeBlocks()
        editing()
        presets()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func questions() {
        let asks = [
            "what is a monad", "Why does it rain", "how to center a div", "who wrote dune",
            "when is easter", "where is lisbon", "can I use swift on linux", "should I use tabs",
            "is it raining", "are cats liquid", "does swift have macros", "explain closures",
            "write a haiku", "safari?", "What's new in macOS", "  how   are you  ", "2+2 in rust?"
        ]
        for query in asks {
            expect(QuickAIQuestion.looksLikeQuestion(query), "“\(query)” reads as a question")
        }
        let opens = [
            "", "   ", "safari", "what", "How", "whatsapp web", "island", "?", "???", "1+1?",
            "calendar", "is"
        ]
        for query in opens {
            expect(!QuickAIQuestion.looksLikeQuestion(query), "“\(query)” stays a search")
        }
    }

    static func instructions() {
        let follow = QuickAIInstructions.followUpRequest
        let off = AIInstructions.compose(userPrompt: "Be terse.", isEnabled: false)
        expect(off == nil, "a disabled prompt and no follow-ups send no instructions")

        let global = AIInstructions.compose(userPrompt: "Be terse.", isEnabled: true)
        expect(global?.hasSuffix("Be terse.") == true, "the global prompt goes last")

        let onlyFollowUps = AIInstructions.compose(
            userPrompt: "Be terse.", isEnabled: false, followUpRequest: follow)
        expect(onlyFollowUps == follow, "follow-ups alone still ask for the fence")

        let preset = QuickAIPreset(name: "Reviewer", systemPrompt: "Review code.")
        let presetPrompt = AIInstructions.compose(
            userPrompt: "Be terse.", isEnabled: false, presetPrompt: preset.systemPrompt,
            followUpRequest: follow)
        expect(presetPrompt?.contains("Review code.") == true, "a preset's prompt is sent")
        expect(presetPrompt?.contains("Be terse.") == false, "a preset replaces the global prompt")
        expect(
            presetPrompt?.hasPrefix(AIPreamble.text) == true,
            "a preset keeps the preamble with the global prompt off")
        expect(
            presetPrompt?.hasSuffix(follow) == true, "the follow-up request comes after the preset")
        expect(
            AIInstructions.compose(userPrompt: "Be terse.", isEnabled: false, presetPrompt: "")
                == AIPreamble.text,
            "a preset with no prompt still sends the preamble")

        let both = AIInstructions.compose(
            userPrompt: "Be terse.", isEnabled: true, chatPrompt: "Reply in French.",
            presetPrompt: "Review code.")
        expect(
            both == AIPreamble.text + "\n\nReview code.\n\nReply in French.",
            "a preset and a chat's own prompt both go, the chat's last")
        expect(follow.contains("```choices"), "the request names the fence ChatChoices parses")
    }

    static func followUps() {
        let choices = ["One", "Two", "Three"]
        expect(
            QuickAIInstructions.nextChoice(choices, current: "", backwards: false) == "One",
            "⇥ from an empty composer lands on the first")
        expect(
            QuickAIInstructions.nextChoice(choices, current: "", backwards: true) == "Three",
            "⇧⇥ from an empty composer lands on the last")
        expect(
            QuickAIInstructions.nextChoice(choices, current: "Three", backwards: false) == "One",
            "⇥ wraps past the last")
        expect(
            QuickAIInstructions.nextChoice(choices, current: "One", backwards: true) == "Three",
            "⇧⇥ wraps past the first")
        expect(
            QuickAIInstructions.nextChoice([], current: "", backwards: false) == nil,
            "no choices leaves ⇥ to the palette")

        let reply = "Here.\n\n```choices\nA\nB\nC\nD\n```"
        let parsed = ChatChoices.split(reply).choices
        expect(parsed.count == 4, "the parser keeps every choice")
        expect(
            Array(parsed.prefix(QuickAIInstructions.maxFollowUps)) == ["A", "B", "C"],
            "Quick AI shows three")
    }

    static func codeBlocks() {
        let reply = """
            First:

            ```swift
            let a = 1
            ```

            Then:

            ```python
            print("b")
            ```

            ```choices
            More?
            ```
            """
        expect(
            QuickAIInstructions.lastCodeBlock(in: reply) == "print(\"b\")",
            "the last fenced block is copied, never the choices fence")
        expect(QuickAIInstructions.lastCodeBlock(in: "No code here.") == nil, "prose has no block")
        let nested = "- step\n\n  ```sh\n  ls\n  ```"
        expect(QuickAIInstructions.lastCodeBlock(in: nested) != nil, "a block inside a list counts")
    }

    static func editing() {
        var unanswered = ChatSession()
        unanswered.append(ChatMessage(role: .user, text: "first"))
        unanswered.append(ChatMessage(role: .assistant, text: "one"))
        unanswered.append(ChatMessage(role: .user, text: "only"))
        let last = unanswered.messages.last { $0.role == .user }
        expect(
            last.flatMap { unanswered.truncate(from: $0.id) }?.text == "only",
            "↑ takes back a question its reply never came to")
        expect(unanswered.messages.map(\.text) == ["first", "one"], "earlier turns stay")
    }

    static func presets() {
        let preset = QuickAIPreset(
            name: "Translator", systemPrompt: "Translate.",
            model: .codex(model: "gpt-5", effort: nil), webSearch: true)
        expect(
            QuickAIPreset.id(fromEntryID: preset.entryID) == preset.id,
            "a preset's launcher row names it back")
        expect(QuickAIPreset.id(fromEntryID: "command:ai-chat") == nil, "other rows are not presets")
        expect(preset.launcherName == "Quick AI: Translator", "the row reads as Raycast's does")
        let data = try? JSONEncoder().encode([preset])
        let decoded = data.flatMap { try? JSONDecoder().decode([QuickAIPreset].self, from: $0) }
        expect(decoded == [preset], "presets round-trip through their stored form")

        let defaults = UserDefaults(suiteName: "quick-ai-test-\(UUID().uuidString)")!
        let store = AISettingsStore(defaults: defaults)
        expect(store.askAIFromRootSearch, "Ask AI from root search defaults on")
        expect(store.quickAIFollowUps, "follow-up suggestions default on")
        expect(store.quickAIPresets.isEmpty, "no presets ship")
        store.quickAIPresets = [preset]
        expect(AISettingsStore(defaults: defaults).quickAIPresets == [preset], "presets persist")
        expect(store.preset(id: preset.id) == preset, "a preset is found by id")
    }
}
