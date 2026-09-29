// Built-in tools' pure half: the catalog, what a turn is offered, consent, arguments and the wire.

import Foundation

@main
@MainActor
struct AIToolsTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        catalogSchemasAreCallable()
        wireNamesRouteBackAndNeverLookLikeMCP()
        offeredFollowsSwitchesShadowsAndScope()
        writesAlwaysAskAndReadsNeverDo()
        argumentsAreCheckedBeforeAnythingRuns()
        calendarSpansAreWholeDays()
        promptsShowWhatWillHappen()
        fileAccessStaysInHomeAndOutOfSight()
        textIsShapedForNotesAndResults()
        addressingTakesSeveralHandles()
        mentionsSuggestWhileTyping()
        loopbackParsesOnlyWhatItServes()
        loopbackSpeaksJSONRPC()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static let everything = Set(BuiltInIntegration.allCases)

    static func tool(_ wireName: String) -> BuiltInTool {
        guard let tool = BuiltInToolCatalog.tool(wireName: wireName) else {
            fatalError("no built-in tool \(wireName)")
        }
        return tool
    }

    static func catalogSchemasAreCallable() {
        expect(
            Set(BuiltInToolCatalog.all.map(\.wireName)).count == BuiltInToolCatalog.all.count,
            "every built-in tool has its own name")
        expect(
            BuiltInIntegration.allCases.allSatisfy { !BuiltInToolCatalog.tools(for: $0).isEmpty },
            "every integration offers at least one tool")
        for tool in BuiltInToolCatalog.all {
            let schema = tool.parameters.objectValue
            let properties = schema?["properties"]?.objectValue ?? [:]
            let required = schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            expect(
                schema?["type"]?.stringValue == "object",
                "\(tool.wireName) takes a JSON object, as every provider requires")
            expect(
                required.allSatisfy { properties[$0] != nil },
                "\(tool.wireName) requires only arguments it describes")
            expect(
                tool.wireName.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil,
                "\(tool.wireName) is a name every provider accepts")
            expect(
                tool.aiTool.origin == tool.integration.title,
                "\(tool.wireName)'s transcript row names its integration")
        }
        expect(
            !BuiltInToolCatalog.windowActions.isEmpty
                && BuiltInToolCatalog.windowActions.allSatisfy {
                    WindowCommandCatalog.command(id: $0)?.kind != .space
                },
            "window actions are offered, but never a move between Spaces")
    }

    static func wireNamesRouteBackAndNeverLookLikeMCP() {
        for tool in BuiltInToolCatalog.all {
            expect(
                !tool.wireName.contains("__"),
                "\(tool.wireName) never parses as an MCP server's tool")
            expect(
                BuiltInToolCatalog.tool(wireName: tool.wireName) == tool,
                "\(tool.wireName) routes back to itself")
            expect(
                BuiltInToolCatalog.tool(handle: tool.integration.handle, name: tool.name) == tool,
                "\(tool.wireName) is found by its integration and inner name, as a CLI sends it")
        }
        expect(
            BuiltInToolCatalog.tool(wireName: "github__search") == nil,
            "an MCP tool is not mistaken for a built-in")
        expect(
            BuiltInIntegration.handles.allSatisfy { !$0.contains("_") },
            "a handle never holds `_`, so a wire name splits one way")
    }

    static func offeredFollowsSwitchesShadowsAndScope() {
        let none = BuiltInToolCatalog.offered(
            enabled: [], shadowedBy: [], scope: nil, excluded: [])
        expect(none.isEmpty, "nothing is offered until an integration is switched on")

        let clipboard = BuiltInToolCatalog.offered(
            enabled: [.clipboard], shadowedBy: [], scope: nil, excluded: [])
        expect(
            clipboard.map(\.wireName) == ["clipboard_search", "clipboard_read", "clipboard_copy"],
            "a switched-on integration offers all of its tools")

        let shadowed = BuiltInToolCatalog.offered(
            enabled: everything, shadowedBy: ["notes"], scope: nil, excluded: [])
        expect(
            !shadowed.contains { $0.integration == .notes } && shadowed.contains { $0.integration == .files },
            "an MCP server saved as @notes keeps the handle, and the integration steps aside")

        let scoped = BuiltInToolCatalog.offered(
            enabled: everything, shadowedBy: [], scope: ["calendar", "github"], excluded: [])
        expect(
            Set(scoped.map(\.integration)) == [.calendar],
            "an addressed turn reaches only the integrations it named")

        let unscoped = BuiltInToolCatalog.offered(
            enabled: everything, shadowedBy: [], scope: nil, excluded: ["files"])
        expect(
            !unscoped.contains { $0.integration == .files }
                && unscoped.count == BuiltInToolCatalog.all.count - 2,
            "a chat that switched one off never sees it")
    }

    static func writesAlwaysAskAndReadsNeverDo() {
        let writes = Set(BuiltInToolCatalog.all.filter { $0.effect == .write }.map(\.wireName))
        expect(
            writes == [
                "clipboard_copy", "snippets_create", "notes_append", "apps_open",
                "apps_arrange_window", "quicklinks_open"
            ],
            "exactly the tools that copy, create, append, open or move are writes")
        for tool in BuiltInToolCatalog.all {
            let verdict = BuiltInToolPolicy.decide(tool, enabled: everything)
            expect(
                verdict == (tool.effect == .write ? .ask : .allow),
                "\(tool.wireName) \(tool.effect == .write ? "asks on every call" : "just runs")")
            expect(
                BuiltInToolPolicy.decide(tool, enabled: []) == .refuse,
                "\(tool.wireName) is refused once its integration is off, even mid-chat")
        }
        for tool in BuiltInToolCatalog.all where tool.effect == .write {
            let request = try? BuiltInToolRequest.parse(
                tool, arguments: sampleArguments(tool), now: .now, calendar: .current
            ).get()
            expect(
                request.flatMap { BuiltInToolPrompt.make(for: $0, subject: nil) } != nil,
                "\(tool.wireName) has a dialog to ask with")
        }
    }

    static func sampleArguments(_ tool: BuiltInTool) -> String {
        switch tool.wireName {
        case "clipboard_copy", "notes_append": return #"{"text":"hello"}"#
        case "snippets_create": return #"{"name":"Sig","text":"Best, A"}"#
        case "apps_open": return #"{"name":"Safari"}"#
        case "apps_arrange_window":
            return #"{"action":"\#(BuiltInToolCatalog.windowActions[0].rawValue)"}"#
        case "quicklinks_open": return #"{"name":"Search"}"#
        default: return "{}"
        }
    }

    static func argumentsAreCheckedBeforeAnythingRuns() {
        func parse(_ wireName: String, _ arguments: String) -> Result<
            BuiltInToolRequest, BuiltInToolRequest.Failure
        > {
            BuiltInToolRequest.parse(
                tool(wireName), arguments: arguments, now: .now, calendar: .current)
        }
        expect(
            (try? parse("clipboard_search", "").get())
                == .clipboardSearch(query: "", limit: BuiltInToolRequest.defaultLimit),
            "no arguments at all is an empty object")
        expect(
            (try? parse("clipboard_search", #"{"query":" invoice ","limit":500}"#).get())
                == .clipboardSearch(query: "invoice", limit: BuiltInToolRequest.maxLimit),
            "a query is trimmed and a limit is clamped")
        expect(
            (try? parse("clipboard_search", #"{"limit":"lots"}"#).get()) == nil,
            "a limit that is not a number is refused")
        expect((try? parse("clipboard_search", "[1]").get()) == nil, "arguments are an object")
        expect((try? parse("clipboard_read", "{}").get()) == nil, "a required argument is required")
        expect(
            (try? parse("clipboard_copy", #"{"text":"  keep  "}"#).get())
                == .clipboardCopy(text: "  keep  "),
            "copied text keeps its spacing")
        expect((try? parse("clipboard_copy", #"{"text":"   "}"#).get()) == nil, "blank text is not copied")
        let huge = String(repeating: "x", count: BuiltInToolRequest.maxWriteBytes + 1)
        expect(
            (try? parse("notes_append", #"{"text":"\#(huge)"}"#).get()) == nil,
            "a write is capped rather than obeyed")
        expect(
            (try? parse("snippets_create", #"{"name":"Sig","text":"Best","keyword":" "}"#).get())
                == .snippetsCreate(name: "Sig", text: "Best", keyword: nil),
            "a blank keyword is no keyword")
        expect(
            (try? parse("apps_arrange_window", #"{"action":"no-such-thing"}"#).get()) == nil,
            "an unknown window action is refused")
        expect(
            (try? parse("quicklinks_open", #"{"name":"Search","argument":" a b "}"#).get())
                == .quicklinksOpen(name: "Search", argument: " a b "),
            "a quicklink argument is passed exactly as given")
        expect(
            (try? parse("calculator_evaluate", #"{"expression":"2+2"}"#).get())
                == .calculate(expression: "2+2"),
            "an expression reaches the calculator as written")
    }

    static func calendarSpansAreWholeDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw") ?? .gmt
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 3, day: 10, hour: 15)) ?? .now
        let today = calendar.startOfDay(for: now)

        let plain = try? BuiltInToolRequest.calendarSpan(
            start: "", end: "", now: now, calendar: calendar)
        expect(
            plain == DateInterval(start: today, duration: 86_400),
            "no days means today, midnight to midnight")
        let week = try? BuiltInToolRequest.calendarSpan(
            start: "2026-03-09", end: "2026-03-15", now: now, calendar: calendar)
        expect(week.map { calendar.dateComponents([.day], from: $0.start, to: $0.end).day } == 7,
            "a range includes both of its ends")
        let spring = try? BuiltInToolRequest.calendarSpan(
            start: "2026-03-29", end: "", now: now, calendar: calendar)
        expect(spring?.duration == 23 * 3_600, "a day is a calendar day, even when clocks change")
        expect(
            (try? BuiltInToolRequest.calendarSpan(
                start: "2026-03-10", end: "2026-03-09", now: now, calendar: calendar)) == nil,
            "a range that runs backwards is refused")
        expect(
            (try? BuiltInToolRequest.calendarSpan(
                start: "2026-01-01", end: "2026-03-01", now: now, calendar: calendar)) == nil,
            "a span longer than the cap is refused")
        expect(
            (try? BuiltInToolRequest.calendarSpan(
                start: "2026-02-30", end: "", now: now, calendar: calendar)) == nil,
            "a day that does not exist is refused rather than rolled over")
    }

    static func promptsShowWhatWillHappen() {
        let append = BuiltInToolPrompt.make(for: .notesAppend(text: "- milk"), subject: "Groceries")
        expect(
            append?.title == "Add to “Groceries”?" && append?.message.contains("- milk") == true,
            "the dialog names the note and shows what is added")
        let link = BuiltInToolPrompt.make(
            for: .quicklinksOpen(name: "Search", argument: "cats"),
            subject: "https://example.com/?q=cats")
        expect(
            link?.message.contains("https://example.com/?q=cats") == true,
            "a quicklink shows the address it resolved to, not just its name")
        let long = BuiltInToolPrompt.quote(String(repeating: "a", count: 5_000))
        expect(
            long.hasPrefix("\u{201C}" + String(repeating: "a", count: BuiltInToolPrompt.previewLength))
                && !long.contains(String(repeating: "a", count: BuiltInToolPrompt.previewLength + 1)),
            "a long write is clipped so the dialog stays a dialog")
        expect(long.contains("5000 characters"), "and says how long the whole is")
        expect(BuiltInToolPrompt.quote(" hi ") == "\u{201C}hi\u{201D}", "a short write is quoted whole")
        expect(
            BuiltInToolPrompt.make(for: .clipboardSearch(query: "", limit: 5), subject: nil) == nil,
            "a read has nothing to ask")
    }

    static func fileAccessStaysInHomeAndOutOfSight() {
        let home = URL(fileURLWithPath: "/Users/ada")
        func readable(_ raw: String) -> Bool {
            BuiltInFileAccess.isReadable(
                BuiltInFileAccess.standardized(raw, home: home), home: home)
        }
        expect(readable("~/Documents/plan.md"), "a file in home is readable")
        expect(readable("/Users/ada/notes.txt"), "by its full path too")
        expect(!readable("~"), "home itself is not a file")
        expect(!readable("/etc/hosts"), "nothing outside home")
        expect(!readable("/Users/adam/secret.txt"), "not a neighbour whose name starts the same")
        expect(!readable("~/Documents/../../bob/x.txt"), "`..` cannot climb out")
        expect(!readable("~/Library/Preferences/x.plist"), "not ~/Library")
        expect(!readable("~/library/Preferences/x.plist"), "not ~/Library in another case")
        expect(!readable("~/.ssh/id_ed25519"), "not a hidden folder")
        expect(!readable("~/code/.env"), "not a hidden file anywhere under home")
    }

    static func textIsShapedForNotesAndResults() {
        expect(
            BuiltInToolText.appending("new", to: "# Title\nold\n\n\n") == "# Title\nold\n\nnew\n",
            "appended Markdown starts its own paragraph")
        expect(BuiltInToolText.appending("\nnew\n", to: "  ") == "new\n", "an empty note just takes it")
        expect(BuiltInToolText.preview("one\ntwo\n\nthree") == "one two three", "a preview is one line")
        expect(
            BuiltInToolText.preview(String(repeating: "b", count: 500)).count
                == BuiltInToolText.previewLength + 1,
            "and is clipped")
    }

    static func addressingTakesSeveralHandles() {
        let handles: Set<String> = ["clipboard", "calendar", "github"]
        let both = ChatToolAddress.parse("@calendar @GitHub what's on", handles: handles)
        expect(
            both.handles == ["calendar", "github"] && both.rest == "what's on",
            "several leading handles scope one turn, integrations and servers alike")
        expect(
            ChatToolAddress.parse("@calendar @nosuch hi", handles: handles).rest == "@nosuch hi",
            "addressing stops at the first unknown handle")
        expect(
            ChatToolAddress.parse("@calendar @calendar hi", handles: handles).handles == ["calendar"],
            "a repeated handle counts once")
        let scope = ChatToolAddress.scope(["calendar", "github"])
        expect(
            ChatToolAddress.handles(inScope: scope) == ["calendar", "github"],
            "a message's scope reads back as the handles it named")
        expect(
            ChatToolAddress.scope(["github"]) == "github",
            "one handle is stored exactly as a single server always was")
        expect(ChatToolAddress.handles(inScope: nil) == nil, "an unaddressed turn is unscoped")
        expect(
            ChatToolAddress.prefix(forScope: scope) == "@calendar @github ",
            "editing a message puts its addresses back ahead of the text")
    }

    static func mentionsSuggestWhileTyping() {
        let handles: Set<String> = ["clipboard", "calendar", "calculator"]
        expect(ChatToolAddress.pendingMention(in: "@ca", handles: handles) == "ca", "an @ being typed")
        expect(ChatToolAddress.pendingMention(in: "@", handles: handles) == "", "a bare @ opens the picker")
        expect(
            ChatToolAddress.pendingMention(in: "@clipboard @c", handles: handles) == "c",
            "a second @ after a finished one")
        expect(
            ChatToolAddress.pendingMention(in: "@clipboard", handles: handles) == "clipboard",
            "a finished handle with no space yet still shows its picker")
        expect(
            ChatToolAddress.pendingMention(in: "@clipboard ", handles: handles) == nil,
            "the space that closes it closes the picker")
        expect(
            ChatToolAddress.pendingMention(in: "mail @ca", handles: handles) == nil,
            "an @ mid-sentence is text")
        expect(
            ChatToolAddress.pendingMention(in: "@ca what", handles: handles) == nil,
            "an unknown @ followed by words is text")

        let sources = [
            ChatToolSource(handle: "clipboard", title: "Clipboard", symbol: "", isBuiltIn: true),
            ChatToolSource(handle: "calendar", title: "Calendar", symbol: "", isBuiltIn: true),
            ChatToolSource(handle: "gh", title: "Calculator Hub", symbol: "", isBuiltIn: false)
        ]
        expect(
            ChatToolAddress.suggestions(for: "CAL", among: sources).map(\.handle) == ["calendar", "gh"],
            "a handle match comes before a title match, whatever the case")
        expect(ChatToolAddress.suggestions(for: "", among: sources).count == 3, "a bare @ lists all")
        expect(
            ChatToolAddress.complete("@clipboard @cal", with: "calendar") == "@clipboard @calendar ",
            "picking finishes the @ being typed and closes it with a space")
    }

    static func loopbackParsesOnlyWhatItServes() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw =
            "POST /mcp/clipboard HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer t0k\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        guard case .request(let request) = LoopbackMCP.parse(Data(raw.utf8)) else {
            expect(false, "a complete request parses")
            return
        }
        expect(
            request.method == "POST" && request.path == "/mcp/clipboard"
                && request.body == Data(body.utf8),
            "the method, path and body are read as sent")
        expect(LoopbackMCP.isAuthorized(request, token: "t0k"), "the right bearer token is let in")
        expect(!LoopbackMCP.isAuthorized(request, token: "t0x"), "a wrong token is not")
        expect(!LoopbackMCP.isAuthorized(request, token: "t0"), "nor a token of another length")
        expect(
            LoopbackMCP.parse(Data(raw.dropLast(3).utf8)) == .incomplete,
            "a body still arriving is waited for")
        expect(LoopbackMCP.parse(Data("POST /mcp/x HTTP/1.1\r\n".utf8)) == .incomplete, "so is a head")
        expect(
            LoopbackMCP.parse(Data("POST /mcp/x HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8))
                == .tooLarge,
            "a body over the cap is refused before it is read")
        expect(
            LoopbackMCP.parse(Data("POST /mcp/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
                == .invalid,
            "a chunked body is refused rather than misread")
        expect(LoopbackMCP.parse(Data("garbage\r\n\r\n".utf8)) == .invalid, "garbage is refused")
        expect(LoopbackMCP.handle(inPath: "/mcp/notes?x=1") == "notes", "a path names its integration")
        expect(LoopbackMCP.handle(inPath: "/mcp/") == nil, "an empty handle names nothing")
        expect(LoopbackMCP.handle(inPath: "/mcp/a/b") == nil, "a deeper path names nothing")
        expect(LoopbackMCP.handle(inPath: "/other") == nil, "another path names nothing")
    }

    static func loopbackSpeaksJSONRPC() {
        func call(_ json: String) -> LoopbackMCP.Call { LoopbackMCP.call(from: Data(json.utf8)) }
        expect(
            call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
                == .initialize(id: .number(1), version: "2025-03-26"),
            "initialize carries the client's protocol version")
        expect(
            call(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == .notification,
            "a message with no id is a notification")
        expect(
            call(#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"copy","arguments":{"text":"hi"}}}"#)
                == .callTool(id: .string("a"), name: "copy", arguments: #"{"text":"hi"}"#),
            "a tool call keeps its id and its arguments as JSON")
        expect(
            call(#"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
                == .unknown(id: .number(2), method: "resources/list"),
            "an unknown method is answered as one")
        expect(call("nope") == .invalid, "a body that is not JSON-RPC is invalid")

        let agreed = LoopbackMCP.initializeResult(version: "2024-11-05", title: "Clipboard")
        expect(
            agreed.objectValue?["protocolVersion"]?.stringValue == "2024-11-05",
            "a supported version is agreed to")
        let fallback = LoopbackMCP.initializeResult(version: "1999-01-01", title: "Clipboard")
        expect(
            fallback.objectValue?["protocolVersion"]?.stringValue == LoopbackMCP.version,
            "an unknown one is answered with Tinycast's own")

        let listed = LoopbackMCP.toolList(BuiltInToolCatalog.tools(for: .clipboard))
        let entries = listed.objectValue?["tools"]?.arrayValue ?? []
        expect(
            entries.compactMap { $0.objectValue?["name"]?.stringValue } == ["search", "read", "copy"],
            "a CLI sees each tool under its inner name, and prefixes the server's own")
        expect(
            entries.last?.objectValue?["annotations"]?.objectValue?["readOnlyHint"] == .bool(false),
            "a write is not advertised as read-only")

        let huge = LoopbackMCP.clipped(String(repeating: "z", count: LoopbackMCP.maxResultBytes * 2))
        expect(
            huge.utf8.count < LoopbackMCP.maxResultBytes + 32 && huge.hasSuffix("truncated."),
            "a CLI route's result is capped as the API loop's is")
        expect(LoopbackMCP.clipped("short") == "short", "a small result goes through whole")

        let http = String(
            bytes: LoopbackMCP.http(status: "200 OK", body: Data("{}".utf8)), encoding: .utf8) ?? ""
        expect(
            http.hasPrefix("HTTP/1.1 200 OK\r\n") && http.contains("Content-Length: 2\r\n")
                && http.hasSuffix("\r\n\r\n{}"),
            "a response is framed with its length")
    }
}
