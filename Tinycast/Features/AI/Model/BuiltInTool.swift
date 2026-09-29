import Foundation

/// One of Tinycast's own tools as a model sees it; what running it touches lives in the Service.
struct BuiltInTool: Equatable, Sendable {
    /// A write is anything that copies, creates, appends, opens or moves, and it always asks.
    enum Effect: Equatable, Sendable {
        case read
        case write
    }

    let integration: BuiltInIntegration
    /// The name inside its integration, and the name a CLI route's client knows it by.
    let name: String
    let title: String
    let description: String
    let parameters: JSONValue
    let effect: Effect

    /// No `__`, so it can never parse as an MCP server's tool, and no slug can shadow it.
    var wireName: String { integration.handle + "_" + name }

    var aiTool: AITool {
        AITool(
            name: wireName, description: description, parameters: parameters,
            origin: integration.title, title: title)
    }
}

enum BuiltInToolCatalog {
    static let all: [BuiltInTool] = [
        tool(
            .clipboard, "search", "Search Clipboard", .read,
            "Search the text entries in the user's clipboard history, newest first. Returns each "
                + "entry's id, when it was copied and a preview. Images are never included.",
            ["query": string("Words to match; leave out for the latest entries"), "limit": limit],
            required: []),
        tool(
            .clipboard, "read", "Read Clipboard Entry", .read,
            "Read the full text of one clipboard history entry, by the id a search returned.",
            ["id": string("The entry's id")], required: ["id"]),
        tool(
            .clipboard, "copy", "Copy to Clipboard", .write,
            "Put text on the clipboard. The user is asked to confirm every call.",
            ["text": string("The text to copy")], required: ["text"]),
        tool(
            .snippets, "search", "Search Snippets", .read,
            "Search the user's snippets by name, keyword or text. Returns each snippet's name, "
                + "keyword and text.",
            ["query": string("Words to match; leave out to list every snippet"), "limit": limit],
            required: []),
        tool(
            .snippets, "create", "Create Snippet", .write,
            "Create a snippet. The user is asked to confirm every call.",
            [
                "name": string("The snippet's name"), "text": string("What the snippet expands to"),
                "keyword": string("Optional text that expands the snippet as it is typed")
            ], required: ["name", "text"]),
        tool(
            .notes, "read", "Read Note", .read,
            "Read the note open in Tinycast's floating note, as Markdown, with its title.",
            [:], required: []),
        tool(
            .notes, "append", "Add to Note", .write,
            "Add Markdown to the end of the open note. The user is asked to confirm every call.",
            ["text": string("The Markdown to add")], required: ["text"]),
        tool(
            .calendar, "events", "Read Calendar", .read,
            "List calendar events between two days, inclusive, in the user's time zone. Both days "
                + "default to today; the span may be at most \(BuiltInToolRequest.maxCalendarDays) "
                + "days.",
            [
                "start": string("First day, as YYYY-MM-DD"),
                "end": string("Last day, as YYYY-MM-DD")
            ], required: []),
        tool(
            .apps, "running", "List Running Apps", .read,
            "List the apps that are running, with the frontmost one marked.", [:], required: []),
        tool(
            .apps, "open", "Open App", .write,
            "Open an installed app by name, or bring it forward if it is running. The user is "
                + "asked to confirm every call.",
            ["name": string("The app's name, as the Applications folder shows it")],
            required: ["name"]),
        tool(
            .apps, "arrange_window", "Arrange Window", .write,
            "Move or resize the frontmost window of the app the user was last using. The user is "
                + "asked to confirm every call.",
            [
                "action": .object([
                    "type": .string("string"),
                    "enum": .array(windowActions.map { .string($0.rawValue) }),
                    "description": .string("Where the window goes")
                ])
            ], required: ["action"]),
        tool(
            .files, "search", "Search Files", .read,
            "Find files and folders by name within the places Tinycast's file search covers. "
                + "Returns each match's full path.",
            ["query": string("Part of the file's name"), "limit": limit], required: ["query"]),
        tool(
            .files, "read", "Read File", .read,
            "Read a UTF-8 text file in the user's home folder, up to "
                + "\(BuiltInFileAccess.maxBytes / 1024) KB. Hidden files and ~/Library are refused.",
            ["path": string("The file's full path, or one starting with ~/")],
            required: ["path"]),
        tool(
            .quicklinks, "list", "List Quicklinks", .read,
            "List the user's quicklinks with their links and any {argument} each one takes.",
            [:], required: []),
        tool(
            .quicklinks, "open", "Open Quicklink", .write,
            "Open a quicklink by name, filling its first {argument} with `argument`. The user is "
                + "asked to confirm every call.",
            [
                "name": string("The quicklink's name"),
                "argument": string("The value for the quicklink's first argument, if it has one")
            ], required: ["name"]),
        tool(
            .calculator, "evaluate", "Calculate", .read,
            "Evaluate arithmetic, a unit or currency conversion, a date or a time zone question "
                + "with Tinycast's calculator, e.g. \"12% of 340\", \"5 km in miles\", "
                + "\"100 usd in eur\" or \"3pm london in tokyo\".",
            ["expression": string("What to evaluate")], required: ["expression"]),
        tool(
            .system, "frontmost_app", "Read Frontmost App", .read,
            "Name the app the user was last working in.", [:], required: []),
        tool(
            .system, "selected_text", "Read Selected Text", .read,
            "Read the text selected in the app the user was last working in, through Accessibility.",
            [:], required: [])
    ]

    /// Space moves have no window to act on; everything else a window command does is on offer.
    static let windowActions: [WindowCommand.ID] = WindowCommandCatalog.all
        .filter { $0.kind != .space }
        .map(\.id)

    private static let byWireName = Dictionary(uniqueKeysWithValues: all.map { ($0.wireName, $0) })

    static func tool(wireName: String) -> BuiltInTool? { byWireName[wireName] }

    static func tool(handle: String, name: String) -> BuiltInTool? {
        guard let integration = BuiltInIntegration(handle: handle) else { return nil }
        return all.first { $0.integration == integration && $0.name == name }
    }

    static func tools(for integration: BuiltInIntegration) -> [BuiltInTool] {
        all.filter { $0.integration == integration }
    }

    /// What a turn may reach: switched on, not lost to a same-named MCP server, and in scope.
    static func offered(
        enabled: Set<BuiltInIntegration>, shadowedBy slugs: Set<String>, scope: Set<String>?,
        excluded: Set<String>
    ) -> [BuiltInTool] {
        all.filter { tool in
            let handle = tool.integration.handle
            return enabled.contains(tool.integration) && !slugs.contains(handle)
                && !excluded.contains(handle) && scope.map { $0.contains(handle) } ?? true
        }
    }

    private static let limit = JSONValue.object([
        "type": .string("integer"), "minimum": .number(1),
        "maximum": .number(Double(BuiltInToolRequest.maxLimit)),
        "description": .string("How many to return; \(BuiltInToolRequest.defaultLimit) if left out")
    ])

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func tool(
        _ integration: BuiltInIntegration, _ name: String, _ title: String,
        _ effect: BuiltInTool.Effect, _ description: String, _ properties: [String: JSONValue],
        required: [String]
    ) -> BuiltInTool {
        BuiltInTool(
            integration: integration, name: name, title: title, description: description,
            parameters: .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false)
            ]),
            effect: effect)
    }
}

/// Reads run once their integration is on; a write asks on every call, and nothing is remembered.
enum BuiltInToolPolicy {
    enum Verdict: Equatable, Sendable {
        case allow
        case ask
        case refuse
    }

    static func decide(_ tool: BuiltInTool, enabled: Set<BuiltInIntegration>) -> Verdict {
        guard enabled.contains(tool.integration) else { return .refuse }
        return tool.effect == .read ? .allow : .ask
    }
}
