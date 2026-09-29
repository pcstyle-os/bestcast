import Foundation

/// One installed extension's AI tools, under the handle `@` names it by.
struct ExtensionToolSource: Equatable, Sendable {
    let handle: String
    let extensionName: String
    let title: String
    let instructions: String?
    let tools: [ExtensionTool]

    /// Unique within the source: a tool whose name truncates onto another's is dropped.
    init(
        handle: String, extensionName: String, title: String, instructions: String?,
        tools: [ExtensionTool]
    ) {
        self.handle = handle
        self.extensionName = extensionName
        self.title = title
        self.instructions = instructions
        var seen: Set<String> = []
        self.tools = tools.filter {
            seen.insert(ExtensionToolName.wireName(handle: handle, tool: $0.name)).inserted
        }
    }

    func wireName(_ tool: ExtensionTool) -> String {
        ExtensionToolName.wireName(handle: handle, tool: tool.name)
    }

    func tool(wireName: String) -> ExtensionTool? {
        tools.first { self.wireName($0) == wireName }
    }

    /// The name a CLI's own client knows it by, inside the server `handle` names.
    func tool(innerName: String) -> ExtensionTool? {
        tools.first { ExtensionToolName.innerName(handle: handle, tool: $0.name) == innerName }
    }

    var aiTools: [AITool] {
        tools.map { tool in
            AITool(
                name: wireName(tool), description: Self.description(tool),
                parameters: Self.parameters(tool), origin: title, title: tool.title)
        }
    }

    var loopbackServer: LoopbackMCP.Server {
        LoopbackMCP.Server(
            title: title,
            tools: tools.map { tool in
                LoopbackMCP.Tool(
                    name: ExtensionToolName.innerName(handle: handle, tool: tool.name),
                    title: tool.title, description: Self.description(tool),
                    inputSchema: Self.parameters(tool),
                    isReadOnly: ExtensionToolPolicy.isReadOnly(tool))
            })
    }

    private static func description(_ tool: ExtensionTool) -> String {
        [tool.description, tool.instructions ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func parameters(_ tool: ExtensionTool) -> JSONValue {
        JSONValue(data: Data(tool.inputSchema.utf8)) ?? .object(["type": .string("object")])
    }
}

/// How an extension and its tools are named on the wire, beside built-in and MCP names.
enum ExtensionToolName {
    static let maxLength = 64

    /// `@scope/demo` becomes `scope-demo`: `@` can type it, and it never holds a `_`.
    static func handle(for extensionName: String) -> String? {
        let words = extensionName.lowercased().split { character in
            !(character.isASCII && (character.isLetter || character.isNumber))
        }
        let handle = words.joined(separator: "-")
        return handle.isEmpty ? nil : handle
    }

    /// No `__`, so it never parses as an MCP tool, and the first `_` always ends the handle.
    static func wireName(handle: String, tool: String) -> String {
        handle + "_" + innerName(handle: handle, tool: tool)
    }

    static func innerName(handle: String, tool: String) -> String {
        let words = tool.split { character in
            !(character.isASCII && (character.isLetter || character.isNumber || character == "-"))
        }
        return String(words.joined(separator: "_").prefix(max(0, maxLength - handle.count - 1)))
    }
}

/// Which extension tools a turn reaches, and whether a call runs, asks, or has nothing to run.
enum ExtensionToolPolicy {
    enum Verdict: Equatable, Sendable {
        case run
        case ask(ExtensionToolPrompt)
    }

    /// Built-in handles and MCP slugs are `taken`; of two extensions on one handle, the first keeps it.
    static func sources(
        _ manifests: [ExtensionManifest], taken: Set<String>
    ) -> [ExtensionToolSource] {
        var claimed = taken
        return manifests.compactMap { manifest in
            guard !manifest.tools.isEmpty, let handle = ExtensionToolName.handle(for: manifest.name),
                claimed.insert(handle).inserted
            else { return nil }
            return ExtensionToolSource(
                handle: handle, extensionName: manifest.name, title: manifest.title,
                instructions: manifest.aiInstructions, tools: manifest.tools)
        }
    }

    /// As in Raycast, only a turn that `@`-names an extension reaches its third-party code.
    static func offered(
        _ sources: [ExtensionToolSource], scope: Set<String>?, excluded: Set<String>
    ) -> [ExtensionToolSource] {
        guard let scope else { return [] }
        return sources.filter { scope.contains($0.handle) && !excluded.contains($0.handle) }
    }

    /// What the addressed extensions ask the model to know, appended to the system prompt.
    static func instructions(for sources: [ExtensionToolSource]) -> String? {
        let parts = sources.compactMap { source in
            source.instructions.map { "Instructions for @\(source.handle) (\(source.title)):\n\($0)" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Only a name that plainly reads runs unasked; anything else might change something.
    static func isReadOnly(_ tool: ExtensionTool) -> Bool {
        let name = tool.name.prefix(1).lowercased() + tool.name.dropFirst()
        return readVerbs.contains(String(name.prefix { $0.isLowercase }))
    }

    private static let readVerbs: Set<String> = [
        "get", "list", "search", "find", "read", "fetch", "lookup", "query", "describe", "inspect",
        "count", "preview"
    ]

    /// `confirmation` is what its export returned: nothing asks for nothing, a missing one asks
    /// unless the tool plainly only reads.
    static func decide(
        _ tool: ExtensionTool, of source: ExtensionToolSource, confirmation: ExtensionToolReturn,
        input: String
    ) -> Verdict {
        switch confirmation {
        case .missing:
            return isReadOnly(tool) ? .run : .ask(.generic(tool, of: source, input: input))
        case .value(.null):
            return .run
        case .value(let value):
            return .ask(.confirming(tool, of: source, with: value, input: input))
        }
    }
}

/// The consent dialog's text for one extension tool call.
struct ExtensionToolPrompt: Equatable, Sendable {
    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool

    /// Long enough to judge, short enough that the dialog stays a dialog.
    static let previewLength = 400

    static func generic(
        _ tool: ExtensionTool, of source: ExtensionToolSource, input: String
    ) -> ExtensionToolPrompt {
        ExtensionToolPrompt(
            title: title(tool), message: fallback(source, input: input), confirmTitle: "Run",
            isDestructive: false)
    }

    /// Raycast's `{message, info, style}`; a bare string is taken as the message.
    static func confirming(
        _ tool: ExtensionTool, of source: ExtensionToolSource, with value: JSONValue,
        input: String
    ) -> ExtensionToolPrompt {
        let object = value.objectValue ?? [:]
        let message = (object["message"]?.stringValue ?? value.stringValue).map(preview)
        let info = (object["info"]?.arrayValue ?? []).compactMap { entry -> String? in
            guard let name = entry.objectValue?["name"]?.stringValue,
                let shown = entry.objectValue?["value"].flatMap(display)
            else { return nil }
            return "\(name): \(preview(shown))"
        }
        let parts = [message].compactMap { $0 } + (info.isEmpty ? [] : [info.joined(separator: "\n")])
        return ExtensionToolPrompt(
            title: title(tool),
            message: parts.isEmpty ? fallback(source, input: input) : parts.joined(separator: "\n\n"),
            confirmTitle: "Run",
            isDestructive: object["style"]?.stringValue == "destructive")
    }

    private static func title(_ tool: ExtensionTool) -> String {
        "Run \u{201C}\(tool.title)\u{201D}?"
    }

    private static func fallback(_ source: ExtensionToolSource, input: String) -> String {
        let intro = "The model wants \(source.title) to run this tool"
        let arguments = JSONValue(data: Data(input.utf8))?.objectValue ?? [:]
        guard !arguments.isEmpty else { return intro + "." }
        return intro + " with:\n\n" + preview(ExtensionToolOutput.text(.object(arguments)))
    }

    private static func display(_ value: JSONValue) -> String? {
        switch value {
        case .null: return nil
        case .string(let text): return text
        default: return ExtensionToolOutput.text(value)
        }
    }

    private static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > previewLength ? String(trimmed.prefix(previewLength)) + "\u{2026}" : trimmed
    }
}

/// What one export handed back, as the runtime's `{exported, value}` reports it.
enum ExtensionToolReturn: Equatable, Sendable {
    case missing
    case value(JSONValue)

    init(json: String) {
        let object = JSONValue(data: Data(json.utf8))?.objectValue ?? [:]
        self = object["exported"]?.boolValue == true ? .value(object["value"] ?? .null) : .missing
    }
}

/// A tool's result as the model reads it: a string as written, anything else as JSON.
enum ExtensionToolOutput {
    static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .null: return "The tool finished without returning anything."
        default:
            let data = try? JSONSerialization.data(
                withJSONObject: value.jsonObject, options: [.fragmentsAllowed, .sortedKeys])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}
