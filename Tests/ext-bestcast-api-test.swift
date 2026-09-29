// `@bestcast/api`: the consent table, manifest parsing, the bridge, and a JS round trip.

import Foundation

@main
struct BestcastAPITests {
    static func main() async {
        policyChecks()
        manifestChecks()
        await bridgeChecks()
        await runtimeChecks()
        print("ext-bestcast-api-test: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Results

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL  \(label)\(detail.isEmpty ? "" : "\n      \(detail)")")
        }
    }

    static let fixtureName = "bestcast-api-fixture"

    static func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("ext-fixtures/bestcast-api")
    }

    static func manifest(_ capabilities: [String]?) -> ExtensionManifest? {
        var json: [String: Any] = [
            "name": fixtureName, "title": "API Fixture",
            "commands": [["name": "probe", "title": "Probe", "mode": "no-view"]]
        ]
        if let capabilities { json["bestcast"] = ["capabilities": capabilities] }
        return ExtensionManifest(json: json)
    }

    // MARK: - Policy

    static func policyChecks() {
        let now = Date(timeIntervalSince1970: 1_000)
        func decide(
            _ capability: ExtensionCapability, declared: Set<ExtensionCapability> = [],
            grant: ExtensionGrant? = nil, implicit: Bool = false, enabled: Bool = true
        ) -> ExtensionGrantDecision {
            ExtensionGrantPolicy.decide(
                capability: capability, declared: declared, grant: grant, isImplicit: implicit,
                featureEnabled: enabled)
        }
        let read = ExtensionGrant(capability: .notesRead, grantedAt: now, always: false)
        let once = ExtensionGrant(capability: .notesWrite, grantedAt: now, always: false)
        let always = ExtensionGrant(capability: .notesWrite, grantedAt: now, always: true)

        check("an undeclared capability is refused by name",
            decide(.notesRead) == .deny("undeclared capability notes.read"))
        check("a granted, declared read is allowed", decide(.notesRead, declared: [.notesRead], grant: read) == .allow)
        check("an ungranted read asks", decide(.notesRead, declared: [.notesRead]) == .ask(subject: "read your note"))
        check("a write without Always Allow asks again",
            decide(.notesWrite, declared: [.notesWrite], grant: once) == .ask(subject: "add to your note"))
        check("a write with Always Allow is allowed",
            decide(.notesWrite, declared: [.notesWrite], grant: always) == .allow)
        check("a switched-off feature denies even a granted read",
            decide(.notesRead, declared: [.notesRead], grant: read, enabled: false) == .deny("denied"))
        check("a Raycast API reaches windows without a declaration",
            decide(.windowsWrite, implicit: true) == .ask(subject: "move and resize your windows"))
        check("implicit covers only the Raycast-backed capabilities",
            decide(.notesRead, implicit: true) == .deny("undeclared capability notes.read"))
        check("the calculator needs a declaration, not a prompt", decide(.calculator, declared: [.calculator]) == .allow)
        check("AI handoff is refused when AI is off",
            decide(.aiHandoff, declared: [.aiHandoff], enabled: false) == .deny("denied"))
        check("a read is remembered after one Allow",
            ExtensionGrantPolicy.grant(.notesRead, always: false, now: now)?.always == false)
        check("a write is remembered only on Always Allow",
            ExtensionGrantPolicy.grant(.notesWrite, always: false, now: now) == nil
                && ExtensionGrantPolicy.grant(.notesWrite, always: true, now: now)?.always == true)
    }

    // MARK: - Manifest

    static func manifestChecks() {
        let loaded = try? ExtensionManifest.load(directory: fixtureDirectory())
        check("the fixture declares its known capabilities",
            loaded?.declaredCapabilities == [.calculator, .clipboardHistoryRead],
            "\(String(describing: loaded?.declaredCapabilities))")
        check("an unknown capability is reported, not kept", loaded?.unknownCapabilities == ["teleport.write"])
        check("no `bestcast` key declares nothing", manifest(nil)?.declaredCapabilities == [])
        check("a non-string entry is skipped",
            ExtensionManifest(json: [
                "name": "x", "commands": [["name": "c", "title": "C", "mode": "no-view"]],
                "bestcast": ["capabilities": [1, "notes.read"]]
            ])?.declaredCapabilities == [.notesRead])
    }

    // MARK: - Bridge

    @MainActor
    final class FakeServices: ExtensionBestcastServices {
        var manifests: [String: ExtensionManifest] = [:]
        var disabled: Set<ExtensionCapability> = []
        var answers: [ExtensionConsentAnswer] = []
        var asked: [ExtensionConsentRequest] = []
        var created: [String] = []
        var editors: [String] = []
        var frames: [String: CGRect] = [:]
        let window = ExtensionWindowInfo(
            id: "42", app: "Finder", bundleID: "com.apple.finder", title: "Downloads",
            frame: CGRect(x: 10, y: 20, width: 800, height: 600), focused: true, desktopID: "D1",
            positionable: true, resizable: true)

        func manifest(extension name: String) -> ExtensionManifest? { manifests[name] }
        func isFeatureEnabled(_ capability: ExtensionCapability) -> Bool { !disabled.contains(capability) }
        func confirm(_ request: ExtensionConsentRequest) async -> ExtensionConsentAnswer {
            asked.append(request)
            return answers.isEmpty ? .allowOnce : answers.removeFirst()
        }

        func clipboardSearch(_ query: String, limit: Int, kind: String?) -> [[String: Any]] {
            [["id": "a", "kind": "text", "preview": "\(query)-entry", "copiedAt": "2026-02-03T04:05:06Z"]]
        }
        func clipboardRead(id: String) throws -> [String: Any] { ["text": id] }
        func snippets(matching query: String?) -> [[String: Any]] { [] }
        func createSnippet(name: String, text: String, keyword: String?) async throws -> String {
            created.append(name)
            return "s\(created.count)"
        }
        func expandSnippet(
            _ idOrKeyword: String, arguments: [String: String], clipboardHistory: Bool
        ) throws -> String { idOrKeyword }
        func openSnippetEditor(name: String?, text: String, keyword: String?) {
            editors.append("snippet:\(name ?? ""):\(text)")
        }
        func readNote() async throws -> String { "hi" }
        func appendToNote(_ text: String) async throws {}
        func quicklinks() -> [[String: Any]] { [] }
        func quicklinkName(id: String) -> String? { nil }
        func openQuicklink(id: String, query: String?) async throws {}
        func createQuicklink(name: String, link: String, application: String?) throws -> String { "q" }
        func openQuicklinkEditor(name: String?, link: String, application: String?) {
            editors.append("quicklink:\(name ?? ""):\(link)")
        }
        func windows() throws -> [ExtensionWindowInfo] { [window] }
        func desktops() -> [ExtensionDesktopInfo] {
            [ExtensionDesktopInfo(id: "D1", size: CGSize(width: 1512, height: 982), active: true)]
        }
        func setWindowFrame(id: String, frame: CGRect) throws { frames[id] = frame }
        func setWindowFullScreen(id: String) throws {}
        func applyWindowLayout(named name: String) throws {}
        func runWindowCommand(_ command: String) throws {}
        func calendarEvents(from start: Date, to end: Date) throws -> [[String: Any]] { [] }
        func evaluate(_ expression: String) -> [String: Any]? {
            expression == "2+2" ? ["result": "4", "raw": 4] : nil
        }
        func openQuickAI(prompt: String?) {}
        func openChat(prompt: String?, mention: String?) {}
        func aiTools() -> [[String: Any]] { [] }
        func callAITool(name: String, input: String) async throws -> String { "" }
    }

    @MainActor
    static func makeBridge(declaring capabilities: [String]) -> (ExtensionBestcastBridge, FakeServices, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("bestcast-grants-\(UUID().uuidString).json")
        let services = FakeServices()
        services.manifests[fixtureName] = manifest(capabilities)
        let bridge = ExtensionBestcastBridge()
        bridge.services = services
        bridge.grants = ExtensionGrantStore(fileURL: file)
        return (bridge, services, file)
    }

    /// The call's refusal, or nil when it went through.
    @MainActor
    static func refusal(
        _ bridge: ExtensionBestcastBridge, _ method: String, _ arguments: [RenderValue] = [],
        canPrompt: Bool = true
    ) async -> BestcastPermissionError? {
        do {
            _ = try await bridge.perform(
                method: method, arguments: arguments, extension: fixtureName,
                context: ExtensionBestcastCallContext(canPrompt: canPrompt))
            return nil
        } catch let error as BestcastPermissionError {
            return error
        } catch {
            return BestcastPermissionError("unexpected \(error)", capability: "?")
        }
    }

    @MainActor
    static func bridgeChecks() async {
        let (bridge, services, file) = makeBridge(declaring: ["calculator", "clipboardHistory.read", "snippets.write"])
        defer { try? FileManager.default.removeItem(at: file) }

        let undeclared = await refusal(bridge, "notes.read")
        check("an undeclared call is refused by capability",
            undeclared == BestcastPermissionError("undeclared capability notes.read", capability: "notes.read"))
        check("the refusal carries the marker JS matches",
            undeclared?.errorDescription == "[bestcast-permission:notes.read] undeclared capability notes.read")

        check("a declared calculator runs without asking",
            await refusal(bridge, "calculator.evaluate", [.string("2+2")]) == nil && services.asked.isEmpty)

        check("a first read asks", await refusal(bridge, "clipboardHistory.search", [.string("x")]) == nil)
        check("the read prompt names the extension and the capability",
            services.asked.map(\.title) == ["API Fixture wants to read your clipboard history"]
                && services.asked.first?.offersAlways == false)
        _ = await refusal(bridge, "clipboardHistory.search", [.string("y")])
        check("an allowed read is not asked again", services.asked.count == 1)
        check("the read grant is kept", bridge.grants?.grant(for: fixtureName, capability: .clipboardHistoryRead) != nil)

        services.disabled = [.clipboardHistoryRead]
        check("a switched-off feature denies a granted read",
            await refusal(bridge, "clipboardHistory.search", [.string("x")])?.reason == "denied")
        services.disabled = []

        services.asked = []
        let draft = RenderValue.object(["name": .string("Sig"), "text": .string("Hi"), "keyword": .string(";s")])
        _ = await refusal(bridge, "snippets.create", [draft])
        _ = await refusal(bridge, "snippets.create", [draft])
        check("a write asks on every call", services.asked.count == 2 && services.created == ["Sig", "Sig"])
        check("the write prompt names its subject",
            services.asked.first?.message == "Create snippet \u{2018}Sig\u{2019} with keyword ;s\n\n\u{201C}Hi\u{201D}"
                && services.asked.first?.offersAlways == true)
        check("Allow once keeps no write grant",
            bridge.grants?.grant(for: fixtureName, capability: .snippetsWrite) == nil)
        services.answers = [.always]
        _ = await refusal(bridge, "snippets.create", [draft])
        _ = await refusal(bridge, "snippets.create", [draft])
        check("Always Allow stops the per-call question", services.asked.count == 3 && services.created.count == 4)

        services.answers = [.deny]
        let denied = await refusal(bridge, "snippets.create", [draft])
        check("Always Allow is not asked again after the grant", denied == nil)

        let reloaded = ExtensionGrantStore(fileURL: file)
        check("grants persist to their own file",
            reloaded.grant(for: fixtureName, capability: .snippetsWrite)?.always == true
                && reloaded.grant(for: fixtureName, capability: .clipboardHistoryRead) != nil)

        bridge.grants?.revoke(.clipboardHistoryRead, extension: fixtureName)
        services.asked = []
        services.answers = [.deny]
        check("a refused read throws denied",
            await refusal(bridge, "clipboardHistory.search", [.string("x")])?.reason == "denied")
        check("a refused read is not asked again",
            await refusal(bridge, "clipboardHistory.search", [.string("x")])?.reason == "denied"
                && services.asked.count == 1)

        services.asked = []
        check("a background run cannot prompt",
            await refusal(bridge, "windows.active", canPrompt: false)?.reason == "denied" && services.asked.isEmpty)
        check("WindowManagement reaches windows without a declaration",
            await refusal(bridge, "windows.active") == nil && services.asked.count == 1)
        let bounds = RenderValue.object([
            "id": .string("42"), "bounds": .object(["size": .object(["width": .number(640)])])
        ])
        check("setWindowBounds asks, naming the window",
            await refusal(bridge, "windows.setWindowBounds", [bounds]) == nil
                && services.asked.last?.message == "Move and resize Finder \u{2014} Downloads")
        check("a partial bounds keeps the rest of the frame",
            services.frames["42"] == CGRect(x: 10, y: 20, width: 640, height: 600))

        services.asked = []
        let editorDraft = RenderValue.object(["name": .string("Link"), "link": .string("https://a.b")])
        check("createQuicklink opens the editor without asking or declaring",
            await refusal(bridge, "quicklinks.openEditor", [editorDraft]) == nil
                && services.asked.isEmpty && services.editors == ["quicklink:Link:https://a.b"])
        check("a background run cannot open an editor",
            await refusal(bridge, "quicklinks.openEditor", [editorDraft], canPrompt: false)?.reason
                == "denied" && services.editors.count == 1)
        let flood = RenderValue.object(["name": .string("x"), "text": .string(String(repeating: "a", count: 100_001))])
        check("an oversized write is refused before it asks",
            await refusal(bridge, "snippets.create", [flood])?.capability == "?"
                && services.asked.isEmpty)

        let capabilities = try? await bridge.perform(
            method: "capabilities", arguments: [], extension: fixtureName,
            context: ExtensionBestcastCallContext(canPrompt: true)) as? [[String: String]]
        let states = Dictionary(
            uniqueKeysWithValues: (capabilities ?? []).compactMap { row in
                row["name"].flatMap { name in row["state"].map { (name, $0) } }
            })
        check("capabilities() reports each state",
            states["calculator"] == "granted" && states["snippets.write"] == "granted"
                && states["clipboardHistory.read"] == "denied" && states["notes.read"] == "undeclared",
            "\(states)")

        bridge.grants?.forgetAll(except: ["someone-else"])
        check("a vanished extension's grants are forgotten",
            ExtensionGrantStore(fileURL: file).grants(for: fixtureName).isEmpty)
        bridge.grants?.grant(.clipboardHistoryRead, always: false, extension: fixtureName)
        bridge.grants?.revokeAll(extension: fixtureName)
        check("Revoke all clears the file",
            ExtensionGrantStore(fileURL: file).grants(for: fixtureName).isEmpty)
    }

    // MARK: - Runtime

    /// Forwards `bestcast` to a real bridge and records every call with its arguments.
    @MainActor
    final class StubHost: ExtensionHostAPI {
        let bridge: ExtensionBestcastBridge
        var calls: [(api: String, method: String, arguments: String)] = []
        var huds: [String] = []

        init(bridge: ExtensionBestcastBridge) { self.bridge = bridge }

        func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
            calls.append((api, method, ExtensionRuntime.jsonString(from: arguments.map(\.jsonValue))))
            switch (api, method) {
            case ("bestcast", _):
                return ExtensionRuntime.jsonString(
                    from: try await bridge.perform(
                        method: method, arguments: arguments, extension: fixtureName,
                        context: ExtensionBestcastCallContext(canPrompt: true)))
            case ("feedback", "showHUD"):
                huds.append(arguments.first?.stringValue ?? "")
                return ""
            case ("storage", "all"):
                return "{}"
            default:
                return ""
            }
        }

        func sessionEnded() {}
    }

    @MainActor
    final class Recorder: ExtensionRuntimeDelegate {
        var failures: [String] = []
        var finished = false

        func runtime(_ runtime: ExtensionRuntime, session: String, didRender tree: RenderTree) {}
        func runtime(_ runtime: ExtensionRuntime, session: String, didFail message: String) {
            failures.append(message)
        }
        func runtime(_ runtime: ExtensionRuntime, session: String, navigationDepth: Int) {}
        func runtime(_ runtime: ExtensionRuntime, session: String, didFinish: Void) { finished = true }
        func runtime(_ runtime: ExtensionRuntime, session: String, didReturn json: String) {}
        func runtime(_ runtime: ExtensionRuntime, log level: String, message: String) {}
    }

    static func runtimeURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bestcast/Resources/RaycastRuntime.generated.js")
    }

    /// Runs one fixture command headless and waits for it to finish or fail.
    @MainActor
    static func run(_ command: String, host: StubHost) async -> Recorder {
        let recorder = Recorder()
        let runtime = ExtensionRuntime(hostAPI: host, runtimeURL: runtimeURL())
        runtime.setDelegate(recorder)
        defer { runtime.shutdown() }
        try? await runtime.boot(config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        let file = fixtureDirectory().appendingPathComponent("\(command).js")
        guard let code = try? String(contentsOf: file, encoding: .utf8) else {
            recorder.failures.append("missing \(file.path)")
            return recorder
        }
        let context = ExtensionLaunchContext(
            extensionName: fixtureName, extensionTitle: "API Fixture", commandName: command,
            commandMode: .noView, assetsPath: "/tmp", supportPath: "/tmp", preferences: [:], caches: [:],
            arguments: [:], fallbackText: nil, isDarkAppearance: true)
        await runtime.start(session: command, code: code, file: file, mode: .noView, context: context)
        for _ in 0..<100 where !recorder.finished && recorder.failures.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await runtime.stop(session: command)
        return recorder
    }

    @MainActor
    static func runtimeChecks() async {
        let (bridge, services, file) = makeBridge(declaring: ["calculator", "clipboardHistory.read"])
        defer { try? FileManager.default.removeItem(at: file) }
        let host = StubHost(bridge: bridge)

        let probe = await run("probe", host: host)
        check("the probe command finishes", probe.finished, probe.failures.joined(separator: "\n"))
        let bestcastCalls = host.calls.filter { $0.api == "bestcast" }
        check("each member is one bestcast host call with its arguments",
            bestcastCalls.map { "\($0.method) \($0.arguments)" } == [
                #"calculator.evaluate ["2+2"]"#, #"clipboardHistory.search ["x",{}]"#, "notes.read []"
            ], "\(bestcastCalls)")
        check("results, dates and a refusal cross back into JS",
            host.huds == ["4|x-entry|2026|notes.read: undeclared capability notes.read"], "\(host.huds)")
        check("the probe asked once, for the clipboard", services.asked.count == 1)

        host.calls = []
        host.huds = []
        services.asked = []
        let windows = await run("windows", host: host)
        check("the windows command finishes", windows.finished, windows.failures.joined(separator: "\n"))
        check("WindowManagement is backed by bestcast windows calls",
            host.calls.filter { $0.api == "bestcast" }.map(\.method)
                == ["windows.active", "windows.setWindowBounds", "windows.desktops"], "\(host.calls)")
        check("WindowManagement results reach JS", host.huds == ["42|Finder|1"], "\(host.huds)")
        check("the window write moved the window",
            services.frames["42"] == CGRect(x: 10, y: 20, width: 640, height: 600))
    }
}
