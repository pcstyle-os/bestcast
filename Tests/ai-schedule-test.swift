// Scheduled and triggered AI Commands: next fire, catch-up, caps, eligibility and the inbox.

import Foundation

@main
@MainActor
struct AIScheduleTests {
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
        slotsFollowTheCalendar()
        missedSlotsCatchUpOnce()
        intervalsAndLoginCountFromTheLastRun()
        theLedgerBaselinesNewSchedules()
        planWakesForTheNextSlot()
        clipboardTriggersAreCapped()
        onlyUnattendedPromptsQualify()
        automationRoundTripsAndValidates()
        storeKeepsCommandsWhoseAutomationBroke()
        inboxIsCappedSearchableAndPersisted()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-09-28 is a Monday.
    static func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 9) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    static func slotsFollowTheCalendar() {
        let daily = AICommandSchedule.daily(hour: 9, minute: 0)
        let weekdays = AICommandSchedule.weekdays(hour: 9, minute: 0)
        expect(
            AICommandSchedulePolicy.latestSlot(of: daily, atOrBefore: date(28, 10), calendar: calendar)
                == date(28, 9),
            "after nine, today's slot is the latest")
        expect(
            AICommandSchedulePolicy.latestSlot(of: daily, atOrBefore: date(28, 8), calendar: calendar)
                == date(27, 9),
            "before nine, yesterday's slot is the latest")
        expect(
            AICommandSchedulePolicy.latestSlot(
                of: weekdays, atOrBefore: date(4, 10, month: 10), calendar: calendar)
                == date(2, 9, month: 10),
            "a weekday schedule looks back past the weekend to Friday")
        expect(
            AICommandSchedulePolicy.nextSlot(
                of: weekdays, after: date(2, 10, month: 10), calendar: calendar)
                == date(5, 9, month: 10),
            "a weekday schedule skips the weekend going forward")
        expect(
            AICommandSchedulePolicy.nextSlot(of: daily, after: date(28, 9), calendar: calendar)
                == date(29, 9),
            "a slot exactly now is past, so the next is tomorrow's")
        expect(
            AICommandSchedulePolicy.latestSlot(
                of: .everyHours(2), atOrBefore: date(28, 9), calendar: calendar) == nil,
            "an interval has no calendar slots")
    }

    static func missedSlotsCatchUpOnce() {
        let daily = AICommandSchedule.daily(hour: 9, minute: 0)
        func due(_ lastRun: Date, _ now: Date) -> Bool {
            AICommandSchedulePolicy.isDue(
                daily, lastRun: lastRun, now: now, sessionStart: .distantPast, calendar: calendar)
        }
        expect(due(date(28, 8), date(28, 9, 30)), "a slot passed since the last run is due")
        expect(!due(date(28, 9, 30), date(28, 12)), "a slot already run is not due again")
        expect(due(date(28, 9, 30), date(1, 10, month: 10)), "three days asleep still catch up")
        expect(
            !due(date(1, 10, month: 10), date(1, 10, 1, month: 10)),
            "and only once: the catch-up run covers every missed slot")
    }

    static func intervalsAndLoginCountFromTheLastRun() {
        let every = AICommandSchedule.everyHours(4)
        expect(
            !AICommandSchedulePolicy.isDue(
                every, lastRun: date(28, 8), now: date(28, 11, 59), sessionStart: .distantPast,
                calendar: calendar),
            "an interval is not due early")
        expect(
            AICommandSchedulePolicy.isDue(
                every, lastRun: date(28, 8), now: date(28, 12), sessionStart: .distantPast,
                calendar: calendar),
            "an interval is due once it elapses")
        expect(
            AICommandSchedulePolicy.nextDue(
                every, lastRun: date(28, 8), now: date(28, 9), calendar: calendar) == date(28, 12),
            "an interval's next fire is the last run plus the interval")
        expect(
            AICommandSchedulePolicy.isDue(
                .atLogin, lastRun: date(27, 20), now: date(28, 8, 1), sessionStart: date(28, 8),
                calendar: calendar),
            "a login run is due once per session")
        expect(
            !AICommandSchedulePolicy.isDue(
                .atLogin, lastRun: date(28, 8, 1), now: date(28, 12), sessionStart: date(28, 8),
                calendar: calendar),
            "and not again in the same session")
        expect(
            AICommandSchedulePolicy.nextDue(
                .atLogin, lastRun: date(28, 8), now: date(28, 9), calendar: calendar) == nil,
            "a login run never wakes the loop")
    }

    static func command(
        _ schedule: AICommandSchedule?, pattern: String? = nil, prompt: String = "Plan {date}"
    ) -> CustomQuickAction {
        CustomQuickAction(
            name: "Auto", instructions: prompt,
            automation: AICommandAutomation(schedule: schedule, clipboardPattern: pattern))
    }

    static func theLedgerBaselinesNewSchedules() {
        var morning = command(.daily(hour: 9, minute: 0))
        let plain = CustomQuickAction(name: "Plain", instructions: "Plan {date}")
        var ledger = AICommandRunLedger()
        let plan = AICommandSchedulePolicy.plan(
            [morning], ledger: ledger, now: date(28, 10), sessionStart: .distantPast,
            calendar: calendar)
        expect(plan.due.isEmpty, "a command the ledger never saw is not due")
        ledger.reconcile([morning, plain], now: date(28, 10))
        expect(ledger.lastRun(for: morning.id) == date(28, 10), "a new schedule counts from now")
        expect(ledger.lastRun(for: plain.id) == nil, "a command with no automation is not tracked")
        expect(
            AICommandSchedulePolicy.plan(
                [morning], ledger: ledger, now: date(28, 10, 5), sessionStart: .distantPast,
                calendar: calendar
            ).due.isEmpty,
            "saving a schedule never fires for a slot already past today")
        ledger.reconcile([morning], now: date(29, 11))
        expect(ledger.lastRun(for: morning.id) == date(28, 10), "an unchanged schedule keeps its run")
        morning.automation?.schedule = .daily(hour: 7, minute: 0)
        ledger.reconcile([morning], now: date(29, 12))
        expect(ledger.lastRun(for: morning.id) == date(29, 12), "a changed schedule re-baselines")
        ledger.noteClipboardRun(morning.id, at: date(28, 12))
        ledger.noteClipboardRun(morning.id, at: date(29, 13))
        expect(ledger.clipboardRuns(for: morning.id) == [date(29, 13)], "day-old clipboard runs age out")
        ledger.reconcile([], now: date(29, 14))
        expect(ledger.records.isEmpty, "a deleted command leaves the ledger")

        ledger.reconcile([morning], now: date(29, 12))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-schedule-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        ledger.save(to: url)
        expect(AICommandRunLedger.load(from: url) == ledger, "the ledger round-trips through its file")
        expect(
            AICommandRunLedger.load(from: url.appendingPathExtension("missing")).records.isEmpty,
            "a missing ledger starts empty")
    }

    static func planWakesForTheNextSlot() {
        let soon = command(.daily(hour: 9, minute: 0))
        let later = command(.everyHours(6))
        let clipboardOnly = command(nil, pattern: "x")
        var ledger = AICommandRunLedger()
        ledger.reconcile([soon, later, clipboardOnly], now: date(27, 9))
        let plan = AICommandSchedulePolicy.plan(
            [soon, later, clipboardOnly], ledger: ledger, now: date(28, 8, 50),
            sessionStart: .distantPast, calendar: calendar)
        expect(plan.due == [later.id], "only the elapsed interval is due")
        expect(plan.wake == date(28, 9), "the loop wakes for the nearest slot")
        let idle = AICommandSchedulePolicy.plan(
            [clipboardOnly], ledger: ledger, now: date(28, 8), sessionStart: .distantPast,
            calendar: calendar)
        expect(
            idle.wake == date(28, 8).addingTimeInterval(AICommandSchedulePolicy.maxWait),
            "with nothing scheduled the loop still re-checks, in case a wake went unreported")
    }

    static func clipboardTriggersAreCapped() {
        let now = date(28, 12)
        func triggers(
            _ text: String, _ pattern: String = "^https?://", runs: [Date] = [],
            replies: Set<String> = []
        ) -> Bool {
            AICommandSchedulePolicy.clipboardTriggers(
                text, pattern: pattern, runs: runs, now: now, recentReplies: replies)
        }
        expect(triggers("https://example.com"), "a matching copy triggers")
        expect(!triggers("plain words"), "a copy the pattern misses does not")
        expect(!triggers("   \n"), "a blank copy never triggers")
        expect(
            !triggers("https://" + String(repeating: "a", count: 10_000)),
            "an oversized copy never triggers")
        expect(!triggers("https://a.b", replies: ["https://a.b"]), "copying a reply never loops")
        expect(
            !triggers("https://a.b", runs: [now.addingTimeInterval(-59)]),
            "a second match inside the cooldown waits")
        expect(
            triggers("https://a.b", runs: [now.addingTimeInterval(-61)]),
            "a match after the cooldown runs")
        let full = (1...AICommandSchedulePolicy.clipboardDailyCap).map {
            now.addingTimeInterval(TimeInterval(-120 * $0))
        }
        expect(!triggers("https://a.b", runs: full), "the daily cap stops a busy clipboard")
        let stale = full.map { $0.addingTimeInterval(-86_400) }
        expect(triggers("https://a.b", runs: stale), "runs older than a day no longer count")
        expect(!triggers("https://a.b", "("), "a broken pattern never triggers")
    }

    static func onlyUnattendedPromptsQualify() {
        func blocked(_ prompt: String) -> Bool {
            AICommandSchedulePolicy.backgroundBlocker(for: prompt) != nil
        }
        expect(blocked("Fix the grammar."), "a selection transform needs a selection")
        expect(blocked("Summarise {selection}"), "{selection} needs someone there")
        expect(blocked("Summarise {browser-tab}"), "{browser-tab} would raise a prompt")
        expect(blocked("Ideas for {argument name=\"topic\"}"), "a required argument would ask")
        expect(
            !blocked("Ideas for {argument name=\"topic\" default=\"work\"}"),
            "an argument with a default can run")
        expect(!blocked("Plan my day for {date}"), "a date-only prompt can run")
        expect(!blocked("Summarise {clipboard} for {frontmost-app}"), "clipboard and app can run")
    }

    static func automationRoundTripsAndValidates() {
        let record = CustomQuickAction(
            name: "Auto", instructions: "Summarise {clipboard}",
            automation: AICommandAutomation(
                schedule: .weekdays(hour: 8, minute: 30), clipboardPattern: "^http", notifies: true))
        let data = try? JSONEncoder().encode(record)
        let back = data.flatMap { try? JSONDecoder().decode(CustomQuickAction.self, from: $0) }
        expect(back == record, "an automated command round-trips through its file")
        let json = """
            {"id":"\(UUID().uuidString)","name":"Old","instructions":"Do it.","createdAt":0}
            """
        let old = try? JSONDecoder().decode(CustomQuickAction.self, from: Data(json.utf8))
        expect(old != nil && old?.automation == nil, "a record without automation reads as none")

        func normalized(_ automation: AICommandAutomation?, _ prompt: String = "Plan {date}")
            -> Result<AICommandAutomation?, CustomQuickActionError>
        {
            do throws(CustomQuickActionError) {
                return .success(
                    try AICommandSchedulePolicy.normalized(automation, instructions: prompt))
            } catch {
                return .failure(error)
            }
        }
        expect(
            normalized(AICommandAutomation(schedule: .daily(hour: 24, minute: 0)))
                == .failure(.invalidSchedule),
            "an hour past 23 is refused")
        expect(
            normalized(AICommandAutomation(schedule: .everyHours(0)))
                == .failure(.invalidSchedule),
            "a zero interval is refused")
        expect(
            normalized(AICommandAutomation(clipboardPattern: "(")) == .failure(.invalidClipboardPattern),
            "a pattern that won't compile is refused")
        expect(
            normalized(AICommandAutomation(clipboardPattern: "  ", notifies: true)) == .success(nil),
            "an automation with nothing to do is dropped")
        expect(
            normalized(AICommandAutomation(clipboardPattern: " a+ ")) == .success(
                AICommandAutomation(clipboardPattern: "a+")),
            "a pattern is trimmed")
        if case .failure(.cannotRunUnattended) = normalized(
            AICommandAutomation(schedule: .atLogin), "Fix {selection}")
        {
            expect(true, "a prompt needing someone can't be automated")
        } else {
            expect(false, "a prompt needing someone can't be automated")
        }
    }

    static func storeKeepsCommandsWhoseAutomationBroke() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-schedule-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CustomQuickActionStore(directory: directory)
        do {
            try store.add(command(.atLogin, prompt: "Fix {selection}"))
            expect(false, "the store refuses an automation its prompt can't run")
        } catch {
            expect(store.actions.isEmpty, "the store refuses an automation its prompt can't run")
        }
        let good = command(.daily(hour: 9, minute: 0))
        _ = try? store.add(good)
        expect(store.actions.first?.automation?.schedule == good.automation?.schedule, "a valid one saves")

        let edited = CustomQuickAction(
            id: good.id, name: "Auto", instructions: "Plan {date}",
            automation: AICommandAutomation(schedule: .daily(hour: 99, minute: 0)))
        let data = try? JSONEncoder().encode([edited])
        try? data?.write(to: directory.appendingPathComponent("quick-actions.json"))
        let reloaded = CustomQuickActionStore(directory: directory)
        reloaded.load()
        expect(
            reloaded.actions.count == 1 && reloaded.actions.first?.automation == nil,
            "a hand-broken automation is dropped, and its command kept")
    }

    static func inboxIsCappedSearchableAndPersisted() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-schedule-inbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = AIInboxStore(directory: directory)
        inbox.load()
        let source = CustomQuickAction(name: "Digest", instructions: "Plan {date}")
        let other = CustomQuickAction(name: "Links", instructions: "Explain {clipboard}")
        for index in 0..<(AIInboxStore.capacity + 5) {
            inbox.add(
                AIInboxEntry(
                    command: index.isMultiple(of: 2) ? source : other, cause: .schedule,
                    date: date(1, 0, month: 9).addingTimeInterval(TimeInterval(index * 60)),
                    prompt: "p", reply: "reply \(index)"))
        }
        expect(inbox.entries.count == AIInboxStore.capacity, "the inbox is capped")
        expect(inbox.entries.first?.reply == "reply 204", "newest first")
        expect(inbox.entries.last?.reply == "reply 5", "the oldest fall off")
        expect(inbox.search("links").allSatisfy { $0.commandName == "Links" }, "search reads the name")
        expect(inbox.search("reply 150").count == 1, "search reads the reply")
        expect(inbox.search("").count == AIInboxStore.capacity, "an empty query lists everything")
        expect(inbox.recentReplies.contains("reply 204"), "the latest replies are remembered")
        expect(!inbox.recentReplies.contains("reply 5"), "only the latest few")
        inbox.add(
            AIInboxEntry(
                command: source, cause: .clipboard, date: date(28, 9), prompt: "p", reply: "",
                failure: "No network"))
        expect(inbox.entries.first?.summary == "No network", "a failure is its own summary")
        let failed = inbox.entries[0].id
        inbox.remove(id: failed)
        expect(inbox.entry(id: failed) == nil, "an entry deletes")

        let reread = AIInboxStore(directory: directory)
        reread.load()
        expect(reread.entries == inbox.entries, "the inbox persists")
        reread.removeAll()
        let empty = AIInboxStore(directory: directory)
        empty.load()
        expect(empty.entries.isEmpty, "clearing persists")

        try? Data("not json".utf8).write(to: directory.appendingPathComponent("ai-inbox.json"))
        let broken = AIInboxStore(directory: directory)
        broken.load()
        broken.add(AIInboxEntry(command: source, cause: .login, date: date(28, 9), prompt: "p", reply: "r"))
        let kept = try? String(contentsOf: directory.appendingPathComponent("ai-inbox.json"), encoding: .utf8)
        expect(!broken.isAvailable && kept == "not json", "an unreadable inbox is never overwritten")
    }
}
