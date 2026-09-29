import Foundation

/// Pins event triggers and composition: the manifest, schedules, consent, backoff, the store, the
/// deeplink form, and the fixture's chain and calls running in the real runtime.
@main
@MainActor
struct ExtensionTriggersTest {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, _ detail: String = "") {
        if condition() {
            print("PASS  \(message)")
        } else {
            failures += 1
            print("FAIL  \(message)\(detail.isEmpty ? "" : "\n      \(detail)")")
        }
    }

    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("ext-fixtures/triggers")

    static func main() async {
        manifestParsing()
        schedules()
        policy()
        await chains()
        await store()
        deepLinks()
        await runtimeFixture()
        print(failures == 0 ? "ext-triggers-test: all passed" : "ext-triggers-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Manifest

    static func manifestParsing() {
        guard let manifest = try? ExtensionManifest.load(directory: fixture) else {
            expect(false, "the fixture manifest loads")
            return
        }
        let triggers = manifest.triggers
        expect(
            triggers.map(\.name) == ["shout", "weekday-morning"],
            "an escaping export path and a schedule trigger without a schedule are dropped",
            "\(triggers.map(\.name))")
        let shout = triggers.first
        expect(shout?.event == .clipboardChanged, "`on` names the event")
        expect(shout?.target == .export("src/upper.js"), "`export` is the target")
        expect(shout?.then == ["src/wrap.js"], "`then` lists the chained exports")
        expect(shout?.throttle == 5, "`throttle` parses below the refresh floor")
        expect(shout?.filter == ExtensionTriggerFilter(kind: "text", match: "^h"), "`filter` is read")
        expect(shout?.replacesSelection == false, "only a selection hotkey may replace the selection")
        let fix = ExtensionTrigger(json: [
            "name": "fix", "on": "selection.hotkey", "export": "a.js", "replacesSelection": true
        ])
        expect(fix?.replacesSelection == true, "`replacesSelection` is read on a selection hotkey")
        expect(shout?.title == "Shout Copied Text", "`title` is read")
        let morning = triggers.last
        expect(morning?.target == .command("echo"), "`command` is the other kind of target")
        expect(morning?.title == "weekday-morning", "a missing title falls back to the name")
        expect(
            morning?.schedule == ExtensionTriggerSchedule(kind: .at(hour: 9, minute: 30), weekdays: [1, 2, 3, 4, 5]),
            "`schedule.at` and weekdays are read")
        expect(
            manifest.exports.map(\.name) == ["shout", "wrap"]
                && manifest.exports.map(\.isPublic) == [true, false],
            "exports are read, private unless marked public")
        expect(manifest.bestcastFiles == ["src/upper.js", "src/wrap.js"], "install copies each named file once")

        let plain = ExtensionManifest(json: [
            "name": "plain", "commands": [["name": "open", "title": "Open"]]
        ])
        expect(plain?.bestcastJSON == nil && plain?.triggers.isEmpty == true, "no `bestcast` means no triggers")

        expect(ExtensionExportPath.isSafe("src/a.js"), "a relative .js path is safe")
        for bad in ["../a.js", "/tmp/a.js", "src/../../a.js", "src/a.ts", "~/a.js", "./a.js", "src//a.js"] {
            expect(!ExtensionExportPath.isSafe(bad), "\(bad) is refused")
        }
    }

    // MARK: - Schedules

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    static func schedules() {
        // 2026-09-25 is a Friday.
        let friday = date("2026-09-25T10:00:00Z")
        let weekdays = ExtensionTriggerSchedule(kind: .at(hour: 9, minute: 30), weekdays: [1, 2, 3, 4, 5])
        expect(
            weekdays.nextFire(after: friday, calendar: calendar) == date("2026-09-28T09:30:00Z"),
            "a weekday time after Friday's has passed fires on Monday")
        expect(
            weekdays.nextFire(after: date("2026-09-28T09:29:59Z"), calendar: calendar)
                == date("2026-09-28T09:30:00Z"),
            "it fires later the same day when the time is still ahead")
        let daily = ExtensionTriggerSchedule(kind: .at(hour: 9, minute: 30))
        expect(
            daily.nextFire(after: date("2026-09-26T09:30:00Z"), calendar: calendar)
                == date("2026-09-27T09:30:00Z"),
            "firing is strictly after the given moment")
        let every = ExtensionTriggerSchedule(kind: .every(900))
        expect(
            every.nextFire(after: friday, calendar: calendar) == date("2026-09-25T10:15:00Z"),
            "`every` adds its interval")
        let workEvery = ExtensionTriggerSchedule(kind: .every(3600), weekdays: [1, 2, 3, 4, 5])
        expect(
            workEvery.nextFire(after: date("2026-09-25T23:30:00Z"), calendar: calendar)
                == date("2026-09-28T00:00:00Z"),
            "`every` skips to the next allowed day's start")
        expect(
            ExtensionTriggerSchedule.isoWeekday(of: friday, calendar: calendar) == 5
                && ExtensionTriggerSchedule.isoWeekday(of: date("2026-09-27T12:00:00Z"), calendar: calendar) == 7,
            "weekdays count from Monday")
        expect(ExtensionTriggerSchedule(json: ["every": "10s"])?.kind == .every(60), "`every` clamps to a minute")
        expect(ExtensionTriggerSchedule(json: ["at": "25:00"]) == nil, "an impossible time is no schedule")
        expect(
            ExtensionTriggerSchedule(json: ["at": "7:05", "weekdays": [0, 6, 9]])?.weekdays == [6],
            "out-of-range weekdays are dropped")
    }

    // MARK: - Policy

    static func trigger(_ extra: [String: Any] = [:]) -> ExtensionTrigger {
        var json: [String: Any] = ["name": "t", "on": "clipboard.changed", "export": "a.js"]
        json.merge(extra) { $1 }
        return ExtensionTrigger(json: json)!
    }

    static func policy() {
        let now = date("2026-09-25T10:00:00Z")
        let throttled = trigger(["throttle": "5s"])
        var state = ExtensionTriggerState()
        expect(
            ExtensionTriggerPolicy.verdict(trigger: throttled, state: state, isPaused: false, now: now) == .off,
            "a trigger does nothing until it is turned on")
        state = ExtensionTriggerPolicy.enabling(state, for: throttled)
        expect(
            ExtensionTriggerPolicy.verdict(trigger: throttled, state: state, isPaused: true, now: now) == .paused,
            "the master pause wins over consent")
        expect(
            ExtensionTriggerPolicy.verdict(trigger: throttled, state: state, isPaused: false, now: now) == .fire,
            "an enabled trigger fires")
        state.lastFired = now.addingTimeInterval(-4)
        expect(
            ExtensionTriggerPolicy.verdict(trigger: throttled, state: state, isPaused: false, now: now) == .throttled,
            "a throttle holds it back")
        state.lastFired = now.addingTimeInterval(-5)
        expect(
            ExtensionTriggerPolicy.verdict(trigger: throttled, state: state, isPaused: false, now: now) == .fire,
            "and lets it go once it has passed")

        expect(
            [0, 1, 2, 3, 9].map { ExtensionTriggerPolicy.backoffDelay(failures: $0) } == [0, 60, 300, 1800, 1800],
            "backoff is 1m, 5m, 30m")
        var failing = ExtensionTriggerPolicy.enabling(ExtensionTriggerState(), for: trigger())
        var disabledAt: Int?
        for attempt in 1...3 {
            let result = ExtensionTriggerPolicy.recording(error: "boom", in: failing, now: now)
            failing = result.state
            if result.didAutoDisable { disabledAt = attempt }
        }
        expect(disabledAt == 3, "the third failure in a row switches it off, once")
        expect(!failing.enabled && failing.autoDisabled && failing.lastError == "boom", "and says why")
        var retry = ExtensionTriggerPolicy.enabling(ExtensionTriggerState(), for: trigger())
        retry = ExtensionTriggerPolicy.recording(error: "boom", in: retry, now: now).state
        expect(
            ExtensionTriggerPolicy.verdict(trigger: trigger(), state: retry, isPaused: false, now: now.addingTimeInterval(59))
                == .backingOff,
            "a failure backs the next run off")
        retry = ExtensionTriggerPolicy.recording(error: nil, in: retry, now: now).state
        expect(retry.failureCount == 0 && retry.lastError == nil, "a success clears the streak")
        let revived = ExtensionTriggerPolicy.enabling(failing, for: trigger())
        expect(revived.enabled && !revived.autoDisabled && revived.failureCount == 0, "turning it on starts over")
        let moved = trigger(["on": "app.activated"])
        expect(
            ExtensionTriggerPolicy.verdict(trigger: moved, state: revived, isPaused: false, now: now) == .off,
            "consent given to one event does not carry to another after an update")
        var bare = ExtensionTriggerState()
        bare.enabled = true
        expect(!ExtensionTriggerPolicy.isOn(trigger(), state: bare), "a switch without a consented event is off")
        let long = ExtensionTriggerPolicy.recording(
            error: String(repeating: "x", count: 5000), in: revived, now: now)
        expect(
            long.state.lastError?.count == ExtensionTriggerPolicy.errorLength,
            "an extension's error text is capped before it is kept")
        expect(
            ExtensionTriggerConsent.explanation(for: trigger(["on": "deeplink"])).contains("web page"),
            "the opt-in says a link trigger can be opened by anything")

        expect(ExtensionTriggerPolicy.allowsHUD(lastShown: nil, now: now), "a first HUD shows")
        expect(!ExtensionTriggerPolicy.allowsHUD(lastShown: now.addingTimeInterval(-9), now: now), "HUDs are spaced")
        expect(ExtensionTriggerPolicy.allowsHUD(lastShown: now.addingTimeInterval(-10), now: now), "by ten seconds")

        let filter = ExtensionTriggerFilter(kind: "text", match: "^h")
        expect(ExtensionTriggerPolicy.matches(filter, kind: "text", text: "hello"), "a matching copy passes")
        expect(!ExtensionTriggerPolicy.matches(filter, kind: "text", text: "world"), "the regex filters")
        expect(!ExtensionTriggerPolicy.matches(filter, kind: "image", text: nil), "the kind filters")
        expect(
            !ExtensionTriggerPolicy.matches(ExtensionTriggerFilter(kind: nil, match: "("), kind: "text", text: "("),
            "an invalid regex never fires")
        expect(ExtensionTriggerPolicy.matches(nil, kind: "file", text: nil), "no filter passes everything")
        expect(ExtensionTriggerPolicy.matches(bundleIds: [], bundleId: nil), "no bundle ids means every app")
        expect(
            ExtensionTriggerPolicy.matches(bundleIds: ["com.apple.Safari"], bundleId: "com.apple.safari")
                && !ExtensionTriggerPolicy.matches(bundleIds: ["com.apple.Safari"], bundleId: "com.apple.mail"),
            "bundle ids narrow app events")
        expect(
            ExtensionTriggerPolicy.clipboardPayload(kind: "text", text: "secret", sharesText: false)
                == ["kind": .string("text")],
            "copied text stays out without its own opt-in")
        expect(
            ExtensionTriggerPolicy.clipboardPayload(kind: "text", text: "hi", sharesText: true)["text"] == .string("hi"),
            "and is shared with it")

        expect(ExtensionTriggerPolicy.composeVerdict(chain: ["a/x"], next: "b/y") == .allowed, "a call is allowed")
        expect(ExtensionTriggerPolicy.composeVerdict(chain: ["a/x", "b/y"], next: "a/x") == .cycle, "a cycle is not")
        expect(
            ExtensionTriggerPolicy.composeVerdict(chain: ["a/1", "a/2", "a/3", "a/4"], next: "a/5") == .tooDeep,
            "nor is a fifth level")
        let queue = (0..<20).reduce([Int]()) { ExtensionTriggerPolicy.enqueue($1, into: $0) }
        expect(queue.count == 16 && queue.first == 4 && queue.last == 19, "a burst keeps the newest events")

        let event = ExtensionTriggerPolicy.event(trigger: "t", type: .deeplink, payload: ["query": .object([:])])
        let props = ExtensionTriggerPolicy.commandLaunchProps(event: event).objectValue
        expect(
            props?["launchType"] == .string("background")
                && props?["launchContext"]?.objectValue?["bestcastTrigger"] == event,
            "a command gets the event as launchContext.bestcastTrigger, in the background")
    }

    static func chains() async {
        var seen: [(ExtensionTriggerTarget, JSONValue)] = []
        let event = ExtensionTriggerPolicy.event(trigger: "t", type: .systemWake, payload: [:])
        let result = await ExtensionTriggerPolicy.runChain(
            event: event, target: .command("c"), then: ["a.js", "b.js"]
        ) { target, input in
            seen.append((target, input))
            if case .export("b.js") = target { return .failure(ExtensionTriggerFailure("b broke")) }
            return .success(.string("step\(seen.count)"))
        }
        expect(result == .failure(ExtensionTriggerFailure("b broke")), "a failing step ends the chain with its error")
        expect(seen.count == 3, "every step before it ran")
        expect(
            seen[safe: 1]?.1.objectValue?["previous"] == .string("step1"),
            "each step sees the value before it as `previous`")
    }

    // MARK: - Store

    static func store() async {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-triggers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ExtensionTriggerStore(fileURL: file)
        store.update(extension: "a", trigger: "t") { $0 = ExtensionTriggerPolicy.enabling($0, for: trigger()) }
        store.update(extension: "b", trigger: "t") { $0.enabled = true }
        store.approve(caller: "a", extension: "b", export: "shorten")
        store.approve(caller: "b", extension: "a", export: "wrap")
        store.approve(caller: "c", extension: "a", export: "wrap")
        store.isPaused = true
        store.flush()

        let reloaded = ExtensionTriggerStore(fileURL: file)
        expect(reloaded.state(extension: "a", trigger: "t").enabled, "consent persists")
        expect(reloaded.isPaused, "the master pause persists")
        expect(reloaded.isApproved(caller: "a", extension: "b", export: "shorten"), "an approval persists")
        expect(!reloaded.isApproved(caller: "c", extension: "b", export: "shorten"), "and names its caller")
        expect(
            reloaded.approvedCallers(extension: "a").map(\.caller) == ["b", "c"],
            "an extension's granted callers are listed")

        reloaded.forget(extension: "a")
        expect(!reloaded.state(extension: "a", trigger: "t").enabled, "uninstall forgets its triggers")
        expect(!reloaded.isApproved(caller: "a", extension: "b", export: "shorten"), "its grants as a caller")
        expect(reloaded.approvedCallers(extension: "a").isEmpty, "and every grant on its exports")
        expect(reloaded.state(extension: "b", trigger: "t").enabled, "and nothing of anyone else's")
        reloaded.revoke(caller: "x", extension: "b", export: "none")
        reloaded.flush()
        expect(!ExtensionTriggerStore(fileURL: file).isApproved(caller: "a", extension: "b", export: "shorten"),
               "the forgetting persists")
    }

    // MARK: - Deeplinks

    static func deepLinks() {
        let link = ExtensionDeepLink.parse(
            url: URL(string: "bestcast://extensions/pc/notes/trigger/capture?text=hi%20there&tag=x")!)
        expect(
            link?.triggerName == "capture" && link?.extensionName == "notes" && link?.ownerOrAuthor == "pc",
            "the trigger form names an extension and a trigger")
        expect(link?.query == ["text": "hi there", "tag": "x"], "its query reaches the event")
        let bare = ExtensionDeepLink.parse(url: URL(string: "bestcast://extensions/notes/trigger/capture")!)
        expect(bare?.triggerName == "capture" && bare?.ownerOrAuthor == nil, "the owner is optional")
        let raycast = ExtensionDeepLink.parse(url: URL(string: "raycast://extensions/notes/trigger/capture")!)
        expect(raycast?.triggerName == nil, "only bestcast:// fires triggers")
        let command = ExtensionDeepLink.parse(url: URL(string: "bestcast://extensions/pc/notes/search")!)
        expect(command?.triggerName == nil && command?.commandName == "search", "a command link is unchanged")
    }

    // MARK: - Runtime

    @MainActor
    final class Recorder: ExtensionRuntimeDelegate {
        var returns: [String] = []
        var failures: [String] = []
        func runtime(_ runtime: ExtensionRuntime, session: String, didRender tree: RenderTree) {}
        func runtime(_ runtime: ExtensionRuntime, session: String, didFail message: String) {
            failures.append(message)
        }
        func runtime(_ runtime: ExtensionRuntime, session: String, navigationDepth: Int) {}
        func runtime(_ runtime: ExtensionRuntime, session: String, didFinish: Void) {}
        func runtime(_ runtime: ExtensionRuntime, session: String, didReturn json: String) {
            returns.append(json)
        }
        func runtime(_ runtime: ExtensionRuntime, log level: String, message: String) {
            if level == "error" { print("      [js] \(message)") }
        }
    }

    /// Answers what a fixture asks for the way Bestcast's bridge would, running each call one-shot.
    @MainActor
    final class StubHost: ExtensionHostAPI {
        var launches: [String] = []

        func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
            switch "\(api).\(method)" {
            case "system.launchCommand":
                let options = arguments.first?.objectValue ?? [:]
                launches.append(options["name"]?.stringValue ?? "")
                guard options["awaitResult"]?.boolValue == true else { return "" }
                let text = options["arguments"]?.objectValue?["text"]?.stringValue ?? ""
                let props: JSONValue = .object([
                    "launchType": .string("background"), "arguments": .object(["text": .string(text)])
                ])
                let value = try await ExtensionTriggersTest.runOnce(
                    fixture.appendingPathComponent("echo.js"), input: props
                ).get()
                return ExtensionTriggerPolicy.json(.object(["result": value]))
            case "bestcastCompose.callExport":
                let input = JSONValue(arguments[safe: 2]?.jsonValue ?? NSNull())
                let value = try await ExtensionTriggersTest.runOnce(
                    fixture.appendingPathComponent("src/upper.js"), input: input
                ).get()
                return ExtensionTriggerPolicy.json(value)
            case "bestcastCompose.listExports":
                return #"[{"extension":"triggers-fixture","name":"shout","description":""}]"#
            default:
                return ""
            }
        }

        func sessionEnded() {}
    }

    static func runtimeURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bestcast/Resources/RaycastRuntime.generated.js")
    }

    /// Boot, load, call the default export, tear down — the lifetime a trigger step gets.
    static func runOnce(
        _ file: URL, input: JSONValue, host: StubHost = StubHost()
    ) async -> Result<JSONValue, ExtensionTriggerFailure> {
        guard let code = try? String(contentsOf: file, encoding: .utf8) else {
            return .failure(ExtensionTriggerFailure("missing \(file.lastPathComponent)"))
        }
        let recorder = Recorder()
        let runtime = ExtensionRuntime(hostAPI: host, runtimeURL: runtimeURL())
        runtime.setDelegate(recorder)
        defer { runtime.shutdown() }
        do {
            try await runtime.boot(config: .current(supportDirectory: FileManager.default.temporaryDirectory))
        } catch {
            return .failure(ExtensionTriggerFailure(error.localizedDescription))
        }
        let context = ExtensionLaunchContext(
            extensionName: "triggers-fixture", extensionTitle: "Triggers Fixture", commandName: "t",
            commandMode: .noView, assetsPath: fixture.path, supportPath: "/tmp", preferences: [:],
            caches: [:], arguments: [:], fallbackText: nil, launchType: .background,
            isDarkAppearance: true)
        await runtime.loadTool(session: "s", code: code, file: file, context: context)
        await runtime.callTool(session: "s", export: "default", input: ExtensionTriggerPolicy.json(input))
        for _ in 0..<200 where recorder.returns.isEmpty && recorder.failures.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if let failure = recorder.failures.first { return .failure(ExtensionTriggerFailure(failure)) }
        guard let json = recorder.returns.first,
            let object = JSONValue(data: Data(json.utf8))?.objectValue,
            object["exported"] == .bool(true)
        else { return .failure(ExtensionTriggerFailure("no value")) }
        return .success(object["value"] ?? .null)
    }

    static func runtimeFixture() async {
        guard let trigger = (try? ExtensionManifest.load(directory: fixture))?.triggers.first else {
            expect(false, "the fixture's trigger loads")
            return
        }
        let event = ExtensionTriggerPolicy.event(
            trigger: trigger.name, type: trigger.event,
            payload: ExtensionTriggerPolicy.clipboardPayload(kind: "text", text: "hello", sharesText: true))
        let result = await ExtensionTriggerPolicy.runChain(
            event: event, target: trigger.target, then: trigger.then
        ) { target, input in
            guard case .export(let path) = target else { return .failure(ExtensionTriggerFailure("not an export")) }
            return await runOnce(fixture.appendingPathComponent(path), input: input)
        }
        expect(result == .success(.string("[HELLO]")), "the clipboard trigger runs upper then wrap", "\(result)")

        let morning = ExtensionTriggerPolicy.event(trigger: "weekday-morning", type: .schedule, payload: [:])
        let echoed = await runOnce(
            fixture.appendingPathComponent("echo.js"),
            input: ExtensionTriggerPolicy.commandLaunchProps(event: morning))
        expect(echoed == .success(.string("schedule")), "a command target reads its launchContext", "\(echoed)")

        let host = StubHost()
        let called = await runOnce(fixture.appendingPathComponent("commands/caller.js"), input: .object([:]), host: host)
        let fields = (try? called.get())?.objectValue
        expect(fields?["echoed"] == .string("hi"), "an awaited launchCommand resolves with the command's value",
               "\(called)")
        expect(fields?["fired"] == .bool(true), "a plain launchCommand still resolves with nothing")
        expect(fields?["shouted"] == .string("YO"), "callExport returns the export's value")
        expect(fields?["exports"]?.arrayValue?.count == 1, "listExports answers from the host")
        expect(host.launches == ["echo", "echo"], "both launches reached the host")
    }
}
