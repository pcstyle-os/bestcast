// Extension contributions: the manifest's `bestcast.contributes`, the decoder that caps what an
// export returns, the search scheduler, fallback ids, `{ext:…}` tokens, and a real runtime run.

import Foundation

@main
@MainActor
struct ExtensionSurfacesTests {
    static var failures = 0
    static var passes = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func main() async {
        parsing()
        exportRefs()
        decoding()
        scheduler()
        fallbacks()
        placeholders()
        await runtime()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Manifest

    static func contributions(_ contributes: [String: Any], commands: Set<String> = ["open"])
        -> ExtensionContributions
    {
        let data = try? JSONSerialization.data(withJSONObject: ["contributes": contributes])
        return ExtensionContributions(json: data, commandNames: commands)
    }

    static func parsing() {
        check(
            "no bestcast key is no contributions",
            ExtensionContributions(json: nil, commandNames: []).isEmpty)

        let parsed = contributions([
            "search": [
                ["name": "a", "title": "A", "export": "a.js", "maxResults": 99, "minLength": 1e300],
                ["name": "b", "export": "b.js#answer", "mode": "answer", "prefix": "b "],
                ["name": "a", "export": "dup.js"],
                ["name": "bad name", "export": "c.js"],
                ["name": "c", "export": "../escape.js"],
                ["name": "d", "export": "/abs.js"],
                ["name": "e", "export": "e.js", "mode": "grid"],
                ["name": "f", "export": "f.ts"],
                ["name": "g", "export": "g.js", "prefix": ""]
            ],
            "fallbacks": [["command": "open", "title": "Open It"], ["command": "missing"]],
            "actions": [
                ["name": "x", "title": "X", "on": ["app", "nope", "app"], "export": "x.js", "icon": "../evil"],
                ["name": "y", "on": ["snippet"], "command": "open", "icon": "star.fill"],
                ["name": "z", "on": [], "export": "z.js"],
                ["name": "w", "on": ["app"], "export": "w.js", "command": "open"],
                ["name": "v", "on": ["app"], "command": "missing"]
            ],
            "placeholders": [
                ["name": "p", "export": "p.js", "arguments": [["name": "project"], ["name": "bad arg"], [:]]],
                ["name": "q"]
            ]
        ])
        check(
            "valid search providers survive",
            parsed.search.map(\.name) == ["a", "b"], "\(parsed.search.map(\.name))")
        check("maxResults is capped at 5", parsed.search.first?.maxResults == 5)
        check("a huge minLength clamps without trapping", parsed.search.first?.minLength == 32)
        check("an answer provider returns one row", parsed.search.last?.maxResults == 1)
        check("an answer export names its member", parsed.search.last?.export.member == "answer")
        check("a prefix is trimmed", parsed.search.last?.prefix == "b")
        check("a title defaults to the name", parsed.search.last?.title == "b")
        check("a fallback must name a shipped command", parsed.fallbacks.map(\.command) == ["open"])
        check(
            "valid actions survive",
            parsed.actions.map(\.name) == ["x", "y"], "\(parsed.actions.map(\.name))")
        check("unknown targets drop, duplicates fold", parsed.actions.first?.targets == [.app])
        check("a path is never an icon", parsed.actions.first?.icon == nil)
        check("a symbol is an icon", parsed.actions.last?.icon == "star.fill")
        check("a command-backed action", parsed.actions.last?.run == .command("open"))
        check("placeholder arguments are validated", parsed.placeholders.map(\.arguments) == [["project"]])

        let many = contributions([
            "search": (0..<20).map { ["name": "s\($0)", "export": "s.js"] }
        ])
        check("each kind is capped", many.search.count == ExtensionContributions.maxPerKind)

        let long = contributions([
            "fallbacks": [["command": "open", "title": String(repeating: "x", count: 500) + "\n"]]
        ])
        check(
            "a title is clipped to one short line",
            long.fallbacks.first.map { $0.title.count == ExtensionContributions.maxTitleLength } ?? false)

        check(
            "items keep declaration order across kinds",
            parsed.items.map(\.kind) == [.search, .search, .fallback, .action, .action, .placeholder])
        check("export paths are what install copies", parsed.exportPaths == ["a.js", "b.js", "x.js", "p.js"])
    }

    static func exportRefs() {
        check("a bare path runs default", ExtensionExportRef("src/a.js")?.member == "default")
        check("a member is taken after #", ExtensionExportRef("src/a.js#run")?.member == "run")
        check("an empty member is refused", ExtensionExportRef("a.js#") == nil)
        check("a dot segment is refused", ExtensionExportRef("./a.js") == nil)
        check("a home path is refused", ExtensionExportRef("~/a.js") == nil)
        check("a double slash is refused", ExtensionExportRef("src//a.js") == nil)
        let url = ExtensionExportRef("src/a.js")?.fileURL(in: URL(fileURLWithPath: "/ext"))
        check("the file resolves under the extension", url?.path == "/ext/src/a.js", url?.path ?? "nil")
    }

    // MARK: - Decoding

    static func decoding() {
        let rows = JSONValue([
            ["title": "One", "actions": [["type": "open", "target": "https://example.com"]]],
            ["title": String(repeating: "a", count: 400), "subtitle": "line\none\u{0007}bell"],
            ["title": ""],
            ["title": "Four", "icon": "/etc/passwd", "actions": [["type": "open", "target": "slack://x"]]],
            ["title": "Five"],
            ["title": "Six"]
        ] as [Any])
        let items = ExtensionSearchOutput.items(from: rows, mode: .rows, limit: 3)
        check("rows are cut to maxResults", items.count == 3, "\(items.count)")
        check("an untitled row is dropped", items.map(\.title).last == "Four")
        check(
            "a title is truncated", items[1].title.count == ExtensionSearchOutput.maxTitleLength,
            "\(items[1].title.count)")
        check(
            "control characters become spaces",
            items[1].subtitle == "line one bell", items[1].subtitle ?? "nil")
        check("a path is never an icon", items[2].icon == nil)
        check(
            "a custom scheme is refused, leaving the default copy",
            items[2].actions == [.copy("Four", title: nil)])
        check("an http target is kept", items[0].actions == [.open("https://example.com", title: nil)])
        check("ids default to the position", items.map(\.id) == ["item-0", "item-1", "item-3"])

        let wrapped = ExtensionSearchOutput.items(
            from: JSONValue(["items": [["title": "A"]]]), mode: .rows, limit: 5)
        check("{ items } is accepted", wrapped.map(\.title) == ["A"])

        let answer = ExtensionSearchOutput.items(from: .string("42\n"), mode: .answer, limit: 1)
        check("an answer is one row", answer.map(\.title) == ["42"] && answer.first?.style == .answer)
        check("an answer copies itself", answer.first?.actions == [.copy("42", title: "Copy Answer")])
        check(
            "garbage decodes to nothing",
            ExtensionSearchOutput.items(from: .number(3), mode: .rows, limit: 3).isEmpty)

        let launch = ExtensionContributionAction(json: JSONValue([
            "type": "launch", "command": "open", "arguments": ["id": "1", "bad key": "2", "n": 3]
        ]))
        check(
            "launch keeps valid string arguments",
            launch == .launch(command: "open", arguments: ["id": "1"], title: nil))
        check("a file path opens", ExtensionContributionAction.isOpenable("/Users/me/a.txt"))
        check("javascript: does not", !ExtensionContributionAction.isOpenable("javascript:alert(1)"))
        let huge = String(repeating: "x", count: ExtensionContributionAction.maxContentLength + 1)
        check(
            "oversized copy content is refused",
            ExtensionContributionAction(json: JSONValue(["type": "copy", "content": huge])) == nil)
    }

    // MARK: - Scheduler

    static func provider(prefix: String? = nil, minLength: Int = 1) -> ExtensionSearchProvider {
        ExtensionSearchProvider(
            name: "p", title: "P", export: ExtensionExportRef("p.js")!, prefix: prefix,
            minLength: minLength, mode: .rows, maxResults: 3)
    }

    static func scheduler() {
        var schedule = ExtensionSearchScheduler()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = schedule.noteQuery("ab", now: start)
        check(
            "the same query keeps its generation",
            schedule.noteQuery(" ab ", now: start.addingTimeInterval(1)) == first)
        check(
            "not before the debounce",
            !schedule.shouldQuery(query: "ab", provider: provider(), now: start.addingTimeInterval(0.1)))
        check(
            "after the debounce",
            schedule.shouldQuery(query: "ab", provider: provider(), now: start.addingTimeInterval(0.151)))
        check(
            "never a stale query",
            !schedule.shouldQuery(query: "a", provider: provider(), now: start.addingTimeInterval(1)))
        check(
            "below minLength stays quiet",
            !schedule.shouldQuery(query: "ab", provider: provider(minLength: 3), now: start.addingTimeInterval(1)))
        check(
            "an unaddressed prefix stays quiet",
            !schedule.shouldQuery(query: "ab", provider: provider(prefix: "gh"), now: start.addingTimeInterval(1)))
        check("the current generation is accepted", schedule.accept(generation: first))
        let second = schedule.noteQuery("abc", now: start.addingTimeInterval(2))
        check("a new query is a new generation", second == first + 1)
        check("an older answer is dropped", !schedule.accept(generation: first))
        check(
            "in time",
            !ExtensionSearchScheduler.isExpired(startedAt: start, now: start.addingTimeInterval(0.8)))
        check(
            "too late",
            ExtensionSearchScheduler.isExpired(startedAt: start, now: start.addingTimeInterval(0.81)))
        check(
            "the prefix is stripped",
            ExtensionSearchScheduler.input(for: "GH  bestcast", provider: provider(prefix: "gh")) == "bestcast")
        check(
            "no prefix hands over the whole query",
            ExtensionSearchScheduler.input(for: " x ", provider: provider()) == "x")
        schedule.reset()
        check("reset retires every generation", !schedule.accept(generation: second))
        check(
            "an empty query never runs",
            !schedule.shouldQuery(query: "", provider: provider(), now: start.addingTimeInterval(9)))
    }

    // MARK: - Fallbacks

    static func fallbacks() {
        let fallback = Fallback.extensionCommand(extensionName: "surfaces", commandName: "open-ticket")
        check("an extension fallback's id is the command's", fallback.id == "extension:surfaces/open-ticket")
        check("an extension fallback round-trips", Fallback(id: fallback.id) == fallback)
        check("a slash in the name keeps the last segment as the command",
              Fallback(id: "extension:@a/b/c") == .extensionCommand(extensionName: "@a/b", commandName: "c"))
        check("an empty command is refused", Fallback(id: "extension:a/") == nil)
        check("an empty extension is refused", Fallback(id: "extension:/c") == nil)
    }

    // MARK: - Snippets

    static func stored(_ text: String) -> StoredSnippet {
        StoredSnippet(
            fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).md"),
            snippet: Snippet(name: "t", text: text), sourceRevision: SnippetSourceRevision(content: text))
    }

    static func placeholders() {
        let text = #"Ticket {ext:surfaces/ticket project="ABC"} and {ext:Surfaces/Ticket|uppercase}"#
        let record = stored(text)
        let found = SnippetTemplateEngine.externalPlaceholders(in: record, snippets: [record])
        let first = SnippetTemplateEngine.ExternalPlaceholder(
            namespace: "ext", name: "surfaces/ticket", arguments: ["project": "ABC"])
        let second = SnippetTemplateEngine.ExternalPlaceholder(
            namespace: "ext", name: "Surfaces/Ticket", arguments: [:])
        check("both tokens parse, case kept", found == [first, second], "\(found)")
        let simple = SnippetTemplateEngine.externalPlaceholders(
            in: stored(#"{ext:a/b x="1"}"#), snippets: [])
        check(
            "{ext:a/b x=\"1\"} parses",
            simple == [.init(namespace: "ext", name: "a/b", arguments: ["x": "1"])], "\(simple)")
        for malformed in ["{ext:ab}", "{ext:/b}", "{ext:a/}", "{ext:a/b x}"] {
            check("\(malformed) stays text", SnippetTemplateEngine.placeholders(in: malformed).isEmpty)
        }

        var context = SnippetTemplateEngine.ExpansionContext(
            clipboard: "", selection: "", now: Date(), calendar: Calendar(identifier: .gregorian),
            locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)
        let unresolved = SnippetTemplateEngine.expand(record, snippets: [record], context: context)
        check("no values leaves the tokens", unresolved.text == text)
        context.externalValues = [first: "ABC-12"]
        let expanded = SnippetTemplateEngine.expand(record, snippets: [record], context: context)
        check("a value fills, a missing one is empty", expanded.text == "Ticket ABC-12 and ", expanded.text)
        check(
            "the copy for a late selection keeps the values",
            context.replacingSelection(with: "x").externalValues?[first] == "ABC-12")
    }

    // MARK: - Runtime

    final class StubHost: ExtensionHostAPI {
        func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String { "" }
        func sessionEnded() {}
    }

    static func repositoryRoot() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Tests/ext-fixtures").path) {
            return cwd
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func runtime() async {
        let root = repositoryRoot()
        let fixture = root.appendingPathComponent("Tests/ext-fixtures/surfaces")
        let runtimeURL = root.appendingPathComponent("Bestcast/Resources/RaycastRuntime.generated.js")
        guard let manifest = try? ExtensionManifest.load(directory: fixture) else {
            return check("the fixture loads", false)
        }
        let owner = InstalledExtension(manifest: manifest, directory: fixture)
        let parsed = ExtensionContributions(manifest: manifest)
        check(
            "the fixture declares every kind",
            Set(parsed.items.map(\.kind)) == Set(ExtensionContributionKind.allCases))

        var opened = 0
        let runner = ExtensionContributionRunner { owner, bundle in
            opened += 1
            let session = ExtensionToolSession(
                runtime: ExtensionRuntime(hostAPI: StubHost(), runtimeURL: runtimeURL)) {}
            let code = (try? String(contentsOf: bundle, encoding: .utf8)) ?? ""
            let context = ExtensionLaunchContext(
                extensionName: owner.manifest.name, extensionTitle: owner.title,
                commandName: bundle.deletingPathExtension().lastPathComponent, commandMode: .noView,
                assetsPath: owner.assetsPath, supportPath: NSTemporaryDirectory(), preferences: [:],
                caches: [:], arguments: [:], fallbackText: nil, isDarkAppearance: true)
            do {
                try await session.load(
                    code: code, file: bundle, context: context,
                    support: URL(fileURLWithPath: NSTemporaryDirectory()))
            } catch {
                session.end()
                throw error
            }
            return session
        }

        guard let lookup = parsed.searchProvider(named: "lookup"),
            let estimate = parsed.searchProvider(named: "estimate"),
            let share = parsed.action(named: "share"), case .export(let shareRef) = share.run,
            let ticket = parsed.placeholder(named: "ticket")
        else { return check("the fixture's contributions parse", false) }

        do {
            let value = try await runner.runExport(
                lookup.export, of: owner, input: JSONValue(["query": "ab"]), keepWarm: true)
            let items = ExtensionSearchOutput.items(from: value, mode: lookup.mode, limit: lookup.maxResults)
            check("search returns two rows for ab", items.map(\.id) == ["t-1", "t-2"], "\(items.map(\.id))")
            check("a newline in a title is flattened", items.last?.title == "ABC-2 Line two")
            check(
                "a refused open leaves the copy",
                items.last?.actions == [.copy("ABC-2 Line two", title: nil)])
            check(
                "the first action is the declared one",
                items.first?.actions.first == .copy("ABC-1", title: nil))

            let again = try await runner.runExport(
                lookup.export, of: owner, input: JSONValue(["query": "zz"]), keepWarm: true)
            check("the warm session answers again", again.arrayValue?.isEmpty == true)
            check("a warm bundle loads once", opened == 1, "\(opened)")

            let answer = try await runner.runExport(
                estimate.export, of: owner, input: JSONValue(["query": "abcd"]), keepWarm: true)
            let answerItems = ExtensionSearchOutput.items(from: answer, mode: .answer, limit: 1)
            check("the answer export runs by member", answerItems.map(\.title) == ["4 points"])
            check("a busy-free warm session serves another member", opened == 1, "\(opened)")

            let shared = try await runner.runExport(
                shareRef, of: owner,
                input: JSONValue(["kind": "app", "item": ["name": "Safari"]]))
            check("a row action returns its HUD text", shared.stringValue == "Shared app Safari")

            let placeholder = try await runner.runExport(
                ticket.export, of: owner, input: JSONValue(["arguments": [String: String]()]))
            check("the placeholder returns ABC-12", placeholder.stringValue == "ABC-12")
        } catch {
            check("the fixture runs", false, error.localizedDescription)
        }

        do {
            _ = try await runner.runExport(
                ExtensionExportRef("src/search-lookup.js#nope")!, of: owner, input: .object([:]))
            check("a missing member throws", false)
        } catch let error as ExtensionContributionError {
            check("a missing member throws", error == .missingExport("nope"))
        } catch {
            check("a missing member throws", false, "\(error)")
        }

        do {
            _ = try await runner.runExport(ExtensionExportRef("src/absent.js")!, of: owner, input: .null)
            check("an absent bundle throws", false)
        } catch {
            check(
                "an absent bundle throws",
                error as? ExtensionContributionError == .notBuilt("src/absent.js"))
        }
        runner.stopAll()
    }
}
