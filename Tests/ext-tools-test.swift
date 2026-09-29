import Foundation

/// Pins how an extension's `tools` become AI tools: names, scope, consent and results.
@main
@MainActor
struct ExtensionToolsTest {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("PASS  \(message)")
        } else {
            failures += 1
            print("FAIL  \(message)")
        }
    }

    static func manifest(
        _ name: String, tools: [[String: Any]], instructions: String? = nil
    ) -> ExtensionManifest? {
        var json: [String: Any] = [
            "name": name, "title": name.capitalized,
            "commands": [["name": "open", "title": "Open", "mode": "view"]],
            "tools": tools
        ]
        if let instructions { json["ai"] = ["instructions": instructions] }
        return ExtensionManifest(json: json)
    }

    static let deleteNote: [String: Any] = [
        "name": "delete-note", "title": "Delete Note", "description": "Deletes a note.",
        "instructions": "Only after the user names it.",
        "input": [
            "type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]
        ],
        "confirmation": true
    ]

    static func main() {
        manifestParsing()
        naming()
        sourcesAndScope()
        consent()
        results()
        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll extension tool checks passed")
    }

    static func manifestParsing() {
        let parsed = manifest(
            "notes", tools: [deleteNote, ["title": "No name"], ["name": "../escape"]],
            instructions: "Notes are markdown.")
        expect(parsed?.tools.map(\.name) == ["delete-note"], "a tool needs a plain name")
        expect(parsed?.aiInstructions == "Notes are markdown.", "`ai.instructions` is read")
        expect(manifest("notes", tools: [])?.tools.isEmpty == true, "no `tools` is no tools")
        let bare = manifest("notes", tools: [["name": "ping"]])?.tools.first
        expect(bare?.title == "ping", "a title defaults to the name")
        expect(
            bare.flatMap { JSONValue(data: Data($0.inputSchema.utf8)) }?.objectValue?["type"]
                == .string("object"),
            "a tool without `input` takes an empty object")
    }

    static func naming() {
        expect(ExtensionToolName.handle(for: "github") == "github", "a plain name is its handle")
        expect(
            ExtensionToolName.handle(for: "@Scope/Spotify Player") == "scope-spotify-player",
            "anything but letters and digits becomes one dash")
        expect(ExtensionToolName.handle(for: "__") == nil, "a name with nothing left has no handle")
        let wire = ExtensionToolName.wireName(handle: "github", tool: "list issues/v2")
        expect(wire == "github_list_issues_v2", "a tool name keeps dashes and joins the rest with _")
        expect(!wire.contains("__"), "a wire name never parses as an MCP tool")
        let long = ExtensionToolName.wireName(
            handle: "github", tool: String(repeating: "x", count: 100))
        expect(long.count == ExtensionToolName.maxLength, "a wire name fits the tool-name limit")
    }

    static func sourcesAndScope() {
        let manifests = [
            manifest("github", tools: [deleteNote], instructions: "Use owner/repo."),
            manifest("clipboard", tools: [deleteNote]),
            manifest("git-hub", tools: [deleteNote]),
            manifest("GitHub", tools: [deleteNote]),
            manifest("plain", tools: [])
        ].compactMap { $0 }
        let sources = ExtensionToolPolicy.sources(manifests, taken: ["clipboard"])
        expect(
            sources.map(\.handle) == ["github", "git-hub"],
            "a taken handle, a second claim and a tool-less extension are all skipped")
        let crowded = manifest(String(repeating: "a", count: 63), tools: [deleteNote])
        expect(
            ExtensionToolPolicy.sources([crowded].compactMap { $0 }, taken: []).isEmpty,
            "a handle that leaves no room for a tool name offers nothing")
        let github = sources[0]
        expect(
            github.aiTools.map(\.name) == ["github_delete-note"],
            "each tool is offered under its wire name")
        expect(github.aiTools.first?.origin == "Github", "a call row names the extension")
        expect(
            github.aiTools.first?.description == "Deletes a note.\n\nOnly after the user names it.",
            "a tool's own instructions ride in its description")
        expect(github.tool(wireName: "github_delete-note")?.name == "delete-note", "a call routes back")
        expect(github.tool(innerName: "delete-note")?.name == "delete-note", "so does a CLI's")
        expect(
            github.loopbackServer.tools.first?.isReadOnly == false,
            "a CLI is not told a delete only reads")

        expect(
            ExtensionToolPolicy.offered(sources, scope: nil, excluded: []).isEmpty,
            "an unaddressed turn reaches no extension")
        expect(
            ExtensionToolPolicy.offered(sources, scope: ["github"], excluded: []).map(\.handle)
                == ["github"],
            "`@github` reaches only GitHub")
        expect(
            ExtensionToolPolicy.offered(sources, scope: ["github"], excluded: ["github"]).isEmpty,
            "an excluded handle stays out")
        let instructions = ExtensionToolPolicy.instructions(for: [github])
        expect(
            instructions == "Instructions for @github (Github):\nUse owner/repo.",
            "an addressed extension's instructions are labelled with its handle")
        expect(
            ExtensionToolPolicy.instructions(for: [sources[1]]) == nil,
            "an extension without instructions adds nothing")
    }

    static func consent() {
        guard let source = ExtensionToolPolicy.sources(
            [manifest("notes", tools: [deleteNote, ["name": "getNotes"], ["name": "listAll"]])]
                .compactMap { $0 }, taken: []
        ).first else { return expect(false, "a source is built") }
        let delete = source.tools[0]
        let input = #"{"title":"Groceries"}"#

        let asked = ExtensionToolPolicy.decide(
            delete, of: source,
            confirmation: ExtensionToolReturn(
                json: #"{"exported":true,"value":{"style":"destructive","message":"Delete the note?","#
                    + #""info":[{"name":"Note","value":"Groceries"},{"name":"Hidden"}]}}"#),
            input: input)
        guard case .ask(let prompt) = asked else { return expect(false, "a confirmation asks") }
        expect(prompt.title == "Run \u{201C}Delete Note\u{201D}?", "the dialog names the tool")
        expect(prompt.message == "Delete the note?\n\nNote: Groceries", "message and shown info")
        expect(prompt.isDestructive, "a destructive style is kept")

        expect(
            ExtensionToolPolicy.decide(
                delete, of: source, confirmation: ExtensionToolReturn(json: #"{"exported":true,"value":null}"#),
                input: input) == .run,
            "a confirmation that returns nothing runs unasked")

        let missing = ExtensionToolPolicy.decide(
            delete, of: source, confirmation: ExtensionToolReturn(json: #"{"exported":false}"#),
            input: input)
        guard case .ask(let generic) = missing else {
            return expect(false, "a tool without confirmation that might write asks")
        }
        expect(generic.message.contains("Groceries"), "the generic question shows the input")
        expect(!generic.isDestructive, "and is not styled destructive")

        expect(ExtensionToolPolicy.isReadOnly(source.tools[1]), "`getNotes` plainly reads")
        expect(ExtensionToolPolicy.isReadOnly(source.tools[2]), "`listAll` plainly reads")
        expect(!ExtensionToolPolicy.isReadOnly(delete), "`delete-note` does not")
        expect(
            ExtensionToolPolicy.decide(
                source.tools[1], of: source, confirmation: .missing, input: "{}") == .run,
            "a read-only tool without confirmation runs")

        let long = String(repeating: "a", count: 1_000)
        guard case .ask(let bounded) = ExtensionToolPolicy.decide(
            delete, of: source, confirmation: .value(.string(long)), input: input)
        else { return expect(false, "a string confirmation asks") }
        expect(
            bounded.message.count == ExtensionToolPrompt.previewLength + 1,
            "a long message is cut short with an ellipsis")
    }

    static func results() {
        expect(ExtensionToolReturn(json: "garbage") == .missing, "an unreadable answer is no export")
        expect(ExtensionToolOutput.text(.string("done")) == "done", "a string reaches the model as is")
        expect(
            ExtensionToolOutput.text(.object(["b": .number(2), "a": .bool(true)]))
                == #"{"a":true,"b":2}"#,
            "anything else reaches it as JSON")
        expect(!ExtensionToolOutput.text(.null).isEmpty, "nothing returned still says so")
    }
}
