import Foundation

/// When a command left to run by itself is due, and when a copy may start one.
enum AICommandSchedulePolicy {
    /// A wake nobody reported still re-plans within this, so a missed slot never waits long.
    static let maxWait: TimeInterval = 15 * 60
    static let clipboardCooldown: TimeInterval = 60
    static let clipboardDailyCap = 30
    static let clipboardMaxCharacters = 10_000

    struct Plan: Equatable, Sendable {
        let due: [UUID]
        let wake: Date
    }

    /// Why a prompt can't run with nobody there, or nil when it can.
    static func backgroundBlocker(for prompt: String) -> String? {
        if AICommandTemplate.isSelectionTransform(prompt) {
            return "A prompt with no placeholder works on a selection, which needs someone there."
        }
        let facts = AICommandTemplate.facts(for: prompt)
        if facts.contains(.selection) {
            return "{selection} needs someone to select text, so it can't run by itself."
        }
        if facts.contains(.browserTab) {
            return "{browser-tab} asks the browser, which can prompt, so it can't run by itself."
        }
        if !AICommandTemplate.missingArguments(in: prompt, values: [:]).isEmpty {
            return "Give every argument a default so it can run without asking."
        }
        return nil
    }

    /// Trimmed, compiled and checked, or nil when nothing is left to automate.
    static func normalized(
        _ automation: AICommandAutomation?, instructions: String
    ) throws(CustomQuickActionError) -> AICommandAutomation? {
        guard var value = automation else { return nil }
        let pattern = value.clipboardPattern?.trimmingCharacters(in: .whitespacesAndNewlines)
        value.clipboardPattern = pattern?.isEmpty == false ? pattern : nil
        guard !value.isEmpty else { return nil }
        if let schedule = value.schedule, !schedule.isValid { throw .invalidSchedule }
        if let pattern = value.clipboardPattern,
            (try? NSRegularExpression(pattern: pattern)) == nil
        {
            throw .invalidClipboardPattern
        }
        if let reason = backgroundBlocker(for: instructions) { throw .cannotRunUnattended(reason) }
        return value
    }

    static func latestSlot(
        of schedule: AICommandSchedule, atOrBefore now: Date, calendar: Calendar
    ) -> Date? {
        slot(of: schedule, from: now, step: -1, calendar: calendar) { $0 <= now }
    }

    static func nextSlot(
        of schedule: AICommandSchedule, after now: Date, calendar: Calendar
    ) -> Date? {
        slot(of: schedule, from: now, step: 1, calendar: calendar) { $0 > now }
    }

    /// However many slots a sleep swallowed, one run catches up on them all.
    static func isDue(
        _ schedule: AICommandSchedule, lastRun: Date, now: Date, sessionStart: Date,
        calendar: Calendar
    ) -> Bool {
        switch schedule {
        case .everyHours(let hours):
            return now.timeIntervalSince(lastRun) >= TimeInterval(hours) * 3_600
        case .atLogin:
            return lastRun < sessionStart
        case .daily, .weekdays:
            guard let slot = latestSlot(of: schedule, atOrBefore: now, calendar: calendar)
            else { return false }
            return slot > lastRun
        }
    }

    static func nextDue(
        _ schedule: AICommandSchedule, lastRun: Date, now: Date, calendar: Calendar
    ) -> Date? {
        switch schedule {
        case .everyHours(let hours): return lastRun.addingTimeInterval(TimeInterval(hours) * 3_600)
        case .atLogin: return nil
        case .daily, .weekdays: return nextSlot(of: schedule, after: now, calendar: calendar)
        }
    }

    /// A command the ledger has not baselined yet is never due: it counts from when it was set.
    static func plan(
        _ commands: [CustomQuickAction], ledger: AICommandRunLedger, now: Date,
        sessionStart: Date, calendar: Calendar
    ) -> Plan {
        var due: [UUID] = []
        var wake = now.addingTimeInterval(maxWait)
        for command in commands {
            guard let schedule = command.automation?.schedule,
                let lastRun = ledger.lastRun(for: command.id)
            else { continue }
            if isDue(
                schedule, lastRun: lastRun, now: now, sessionStart: sessionStart,
                calendar: calendar)
            {
                due.append(command.id)
            } else if let next = nextDue(schedule, lastRun: lastRun, now: now, calendar: calendar) {
                wake = min(wake, max(next, now))
            }
        }
        return Plan(due: due, wake: wake)
    }

    /// Called off-main, so a pathological pattern backtracks away from the main thread.
    static func clipboardTriggers(
        _ text: String, pattern: String, runs: [Date], now: Date, recentReplies: Set<String>
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= clipboardMaxCharacters,
            !recentReplies.contains(trimmed)
        else { return false }
        guard clipboardHasBudget(runs: runs, now: now),
            let regex = try? NSRegularExpression(pattern: pattern)
        else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func clipboardHasBudget(runs: [Date], now: Date) -> Bool {
        let recent = runs.filter { now.timeIntervalSince($0) < 86_400 }
        return recent.count < clipboardDailyCap
            && !recent.contains { now.timeIntervalSince($0) < clipboardCooldown }
    }

    private static func slot(
        of schedule: AICommandSchedule, from now: Date, step: Int, calendar: Calendar,
        accepts: (Date) -> Bool
    ) -> Date? {
        let hour: Int
        let minute: Int
        switch schedule {
        case .daily(let h, let m), .weekdays(let h, let m):
            hour = h
            minute = m
        case .everyHours, .atLogin:
            return nil
        }
        var day = now
        for _ in 0..<8 {
            if let slot = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                accepts(slot),
                !(isWeekdays(schedule) && calendar.isDateInWeekend(slot))
            {
                return slot
            }
            guard let next = calendar.date(byAdding: .day, value: step, to: day) else { return nil }
            day = next
        }
        return nil
    }

    private static func isWeekdays(_ schedule: AICommandSchedule) -> Bool {
        if case .weekdays = schedule { return true }
        return false
    }
}
