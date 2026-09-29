import Foundation

/// When each automated command last ran, so a relaunch or a wake neither repeats nor skips a run.
struct AICommandRunLedger: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var schedule: AICommandSchedule?
        var lastRun: Date
        var clipboardRuns: [Date] = []
    }

    private(set) var records: [UUID: Record] = [:]

    func lastRun(for id: UUID) -> Date? { records[id]?.lastRun }

    func clipboardRuns(for id: UUID) -> [Date] { records[id]?.clipboardRuns ?? [] }

    /// A new or changed schedule counts from now, so saving one never fires for a slot already past.
    mutating func reconcile(_ commands: [CustomQuickAction], now: Date) {
        var kept: [UUID: Record] = [:]
        for command in commands {
            guard let automation = command.automation else { continue }
            var record = records[command.id] ?? Record(schedule: automation.schedule, lastRun: now)
            if record.schedule != automation.schedule {
                record.schedule = automation.schedule
                record.lastRun = now
            }
            kept[command.id] = record
        }
        records = kept
    }

    mutating func noteScheduledRun(_ id: UUID, at date: Date) {
        records[id]?.lastRun = date
    }

    mutating func noteClipboardRun(_ id: UUID, at date: Date) {
        guard var record = records[id] else { return }
        record.clipboardRuns = record.clipboardRuns.filter { date.timeIntervalSince($0) < 86_400 }
        record.clipboardRuns.append(date)
        records[id] = record
    }

    static func load(from url: URL) -> Self {
        guard let data = try? Data(contentsOf: url),
            let ledger = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return ledger
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
