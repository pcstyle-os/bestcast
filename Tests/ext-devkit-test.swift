// Dev mode, the console, Git URLs and Script Command folders, then a linked fixture booted for real.

import Foundation

@main
struct ExtensionDevkitTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print("PASS  \(label)")
        } else {
            failures += 1
            print("FAIL: \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("ext-fixtures/devkit", isDirectory: true)

    static func main() async {
        gitURLs()
        consoleBuffer()
        scriptHeaders()
        manifests()
        launchContext()
        await sourceStore()
        await linkedFixtureBoots()
        print(failures == 0 ? "Extension devkit tests passed" : "\(failures) tests failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Install from Git

    static func gitURLs() {
        let bare = ExtensionGitURL("https://github.com/raycast/extensions")
        check("a bare repository parses", bare?.owner == "raycast" && bare?.repository == "extensions")
        check("a bare repository has no ref", bare?.ref == nil && bare?.subdirectory == nil)
        check(
            "the clone URL ends in .git",
            bare?.cloneURL.absoluteString == "https://github.com/raycast/extensions.git")

        let nested = ExtensionGitURL(
            "https://github.com/raycast/extensions/tree/main/extensions/linear")
        check("a tree URL carries its ref", nested?.ref == "main")
        check("a tree URL carries its folder", nested?.subdirectory == "extensions/linear")
        check(
            "the display string round-trips",
            nested?.displayString == "https://github.com/raycast/extensions/tree/main/extensions/linear")

        check("a .git suffix is dropped", ExtensionGitURL("https://github.com/a/b.git")?.repository == "b")
        check("http is refused", ExtensionGitURL("http://github.com/a/b") == nil)
        check("another host is refused", ExtensionGitURL("https://gitlab.com/a/b") == nil)
        check("an owner alone is refused", ExtensionGitURL("https://github.com/a") == nil)
        check("a leading dash is refused", ExtensionGitURL("https://github.com/-a/b") == nil)
        check("a dot-dot folder is refused", ExtensionGitURL("https://github.com/a/b/tree/main/..") == nil)
        check("a blob URL is refused", ExtensionGitURL("https://github.com/a/b/blob/main/x") == nil)
    }

    // MARK: - Console

    static func consoleBuffer() {
        var buffer = ExtensionConsoleBuffer(capacity: 3)
        let now = Date(timeIntervalSince1970: 0)
        for index in 0..<5 {
            buffer.append(level: .log, message: "line \(index)", at: now)
        }
        check("the ring keeps its capacity", buffer.entries.count == 3)
        check("the oldest lines leave first", buffer.entries.first?.message == "line 2")
        check("ids keep counting past the cap", buffer.entries.last?.id == 4)

        buffer.append(level: .error, message: "boom", stack: "at hello.js:3", at: now)
        check("a level filter narrows", buffer.filtered(level: .error, query: "").count == 1)
        check("the query reads the stack", buffer.filtered(level: nil, query: "HELLO.JS").count == 1)
        check("an empty query is every line", buffer.filtered(level: nil, query: " ").count == 3)
        check(
            "copied text folds the stack under the line",
            ExtensionConsoleBuffer.text(of: buffer.filtered(level: .error, query: ""))
                == "[error] boom\nat hello.js:3")
        check("unknown runtime levels read as log", ExtensionConsoleLevel(runtimeLevel: "debug") == .log)
        check("the default capacity is 500", ExtensionConsoleBuffer().capacity == 500)
        buffer.clear()
        check("clear empties the buffer", buffer.entries.isEmpty)
    }

    // MARK: - Script Command folders

    static func header(_ name: String) -> ScriptCommandHeader? {
        let url = fixtures.appendingPathComponent("scripts/\(name)")
        guard let source = RaycastScriptImport.head(of: url) else { return nil }
        return ScriptCommandHeader(url: url, source: source)
    }

    static func scriptHeaders() {
        let inline = header("inline.sh")
        check("a schemaVersion 1 script parses", inline?.title == "Uptime")
        check("inline mode is read", inline?.mode == .inline)
        check("refreshTime clamps to ten seconds", inline?.refreshTime == .seconds(10))
        check("an emoji icon is an emoji", inline?.icon == .emoji("⏱"))
        check("packageName is kept", inline?.packageName == "System")
        check("the id is stable across parses", inline?.command.id == header("inline.sh")?.command.id)

        let greet = header("greet.sh")
        check("compact mode is read", greet?.mode == .compact)
        check("needsConfirmation is honoured", greet?.needsConfirmation == true)
        check("argument1 becomes a required argument", greet?.arguments.first?.isOptional == false)
        check("a compact script has no refresh", greet?.refreshTime == nil)
        check(
            "a relative icon resolves beside the script",
            greet?.icon == .file(fixtures.appendingPathComponent("scripts/images/greet.png")))

        check("a script without schemaVersion is skipped", header("unversioned.sh") == nil)
        check("an https icon is skipped", ScriptCommandHeader.icon("https://x/y.png", script: fixtures) == nil)
        check("an unknown refresh unit is none", ScriptCommandHeader.refreshTime("5w") == nil)
        check("an hour refresh is an hour", ScriptCommandHeader.refreshTime("1h") == .seconds(3600))
    }

    // MARK: - Manifests

    static func manifests() {
        let toolsOnly = try? ExtensionManifest.load(
            directory: fixtures.appendingPathComponent("tools-only"))
        check("a tools-only manifest is accepted", toolsOnly?.tools.map(\.name) == ["lookup"])
        check("a tools-only manifest has no commands", toolsOnly?.commands.isEmpty == true)
        check(
            "a bestcast section alone is accepted",
            ExtensionManifest(json: ["name": "x", "bestcast": ["hooks": [String]()]]) != nil)
        check("an empty manifest is refused", ExtensionManifest(json: ["name": "x"]) == nil)
    }

    static func context(isDevelopment: Bool) -> ExtensionLaunchContext {
        ExtensionLaunchContext(
            extensionName: "devkit-linked", extensionTitle: "Linked Fixture", commandName: "hello",
            commandMode: .noView, assetsPath: "/tmp", supportPath: "/tmp", preferences: [:],
            caches: [:], arguments: [:], fallbackText: nil, isDarkAppearance: true,
            isDevelopment: isDevelopment)
    }

    static func launchContext() {
        func environment(_ context: ExtensionLaunchContext) -> [String: Any]? {
            let json = try? JSONSerialization.jsonObject(with: Data(context.jsonString().utf8))
            return (json as? [String: Any])?["environment"] as? [String: Any]
        }
        check(
            "a linked launch says isDevelopment",
            environment(context(isDevelopment: true))?["isDevelopment"] as? Bool == true)
        check(
            "any other launch does not",
            environment(context(isDevelopment: false))?["isDevelopment"] as? Bool == false)
    }

    // MARK: - Source records

    @MainActor
    static func sourceStore() async {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("devkit-\(UUID().uuidString)/extension-sources.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ExtensionSourceStore(fileURL: file)
        let linked = fixtures.appendingPathComponent("linked")
        store.set(
            ExtensionSourceRecord(
                kind: .linked, path: linked.path, url: nil, ref: nil, commit: nil,
                linkedAt: Date(timeIntervalSince1970: 0)),
            for: "devkit-linked")
        store.addScriptFolder(fixtures)
        store.addScriptFolder(fixtures)

        let reread = ExtensionSourceStore(fileURL: file)
        check("a record survives a relaunch", reread.record(for: "devkit-linked")?.kind == .linked)
        check("linked folders come from records", reread.linkedDirectories.map(\.path) == [linked.path])
        check("a script folder is added once", reread.scriptFolders.count == 1)
        check("a folder without dist/ is read as is", ExtensionSourceStore.manifestRoot(of: linked) == linked)
        reread.set(nil, for: "devkit-linked")
        reread.removeScriptFolder(fixtures)
        check("forgetting a record leaves nothing", ExtensionSourceStore(fileURL: file).contents.extensions.isEmpty)
        check("the linked folder itself stays", FileManager.default.fileExists(atPath: linked.path))
    }

    // MARK: - A linked fixture, booted

    @MainActor
    final class Host: ExtensionHostAPI {
        var huds: [String] = []

        func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
            if api == "feedback", method == "showHUD" { huds.append(arguments.first?.stringValue ?? "") }
            return ""
        }

        func sessionEnded() {}
    }

    @MainActor
    final class Recorder: ExtensionRuntimeDelegate {
        var lines: [(level: String, message: String, stack: String?)] = []
        var finished = false
        var failures: [String] = []

        func runtime(_ runtime: ExtensionRuntime, session: String, didRender tree: RenderTree) {}
        func runtime(_ runtime: ExtensionRuntime, session: String, didFail message: String) {
            failures.append(message)
        }
        func runtime(_ runtime: ExtensionRuntime, session: String, navigationDepth: Int) {}
        func runtime(_ runtime: ExtensionRuntime, session: String, didFinish: Void) { finished = true }
        func runtime(_ runtime: ExtensionRuntime, log level: String, message: String) {}
        func runtime(_ runtime: ExtensionRuntime, log level: String, message: String, stack: String?) {
            lines.append((level, message, stack))
        }
    }

    @MainActor
    static func linkedFixtureBoots() async {
        let root = fixtures.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeURL = root.appendingPathComponent("Bestcast/Resources/RaycastRuntime.generated.js")
        let host = Host()
        let recorder = Recorder()
        let runtime = ExtensionRuntime(hostAPI: host, runtimeURL: runtimeURL)
        runtime.setDelegate(recorder)
        do {
            try await runtime.boot(
                config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        } catch {
            check("the runtime boots", false, "\(error)")
            return
        }
        let file = fixtures.appendingPathComponent("linked/hello.js")
        let code = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        await runtime.start(
            session: "dev", code: code, file: file, mode: .noView, context: context(isDevelopment: true))
        for _ in 0..<40 where !recorder.finished {
            try? await Task.sleep(for: .milliseconds(50))
        }
        check("the linked command finishes", recorder.finished, recorder.failures.joined(separator: "|"))
        check("environment.isDevelopment reaches the command", host.huds == ["dev"], "\(host.huds)")
        check(
            "console.log is forwarded as log",
            recorder.lines.contains { $0.level == "log" && $0.message == "hello from hello" })
        check("console.warn keeps its level", recorder.lines.contains { $0.level == "warn" })
        let error = recorder.lines.first { $0.level == "error" }
        check("an Error's headline stays on the line", error?.message == "wrapped Error: kaboom")
        check("an Error's stack travels apart", error?.stack?.isEmpty == false, "\(String(describing: error))")
        check("a host call is timed", recorder.lines.contains { $0.level == "timing" })
        await runtime.stop(session: "dev")
    }
}
