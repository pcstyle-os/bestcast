import Foundation

/// A trigger's `schedule`: `{every: "15m"}` or `{at: "09:30"}`, optionally on some weekdays only.
struct ExtensionTriggerSchedule: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case every(TimeInterval)
        case at(hour: Int, minute: Int)
    }

    let kind: Kind
    /// ISO numbering, 1 = Monday through 7 = Sunday; empty means every day.
    let weekdays: Set<Int>

    init(kind: Kind, weekdays: Set<Int> = []) {
        self.kind = kind
        self.weekdays = weekdays
    }

    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        if let every = ExtensionRefreshPolicy.parse(dict["every"] as? String) {
            kind = .every(every)
        } else if let at = dict["at"] as? String, let time = Self.parseTime(at) {
            kind = .at(hour: time.hour, minute: time.minute)
        } else {
            return nil
        }
        let days = (dict["weekdays"] as? [Int] ?? []).filter { (1...7).contains($0) }
        weekdays = Set(days)
    }

    static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
            (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    /// The first moment strictly after `date` this schedule fires, in `calendar`'s time zone.
    func nextFire(after date: Date, calendar: Calendar) -> Date? {
        switch kind {
        case .every(let interval):
            let candidate = date.addingTimeInterval(interval)
            if allows(candidate, calendar: calendar) { return candidate }
            return nextAllowedDayStart(after: candidate, calendar: calendar)
        case .at(let hour, let minute):
            var cursor = date
            for _ in 0..<8 {
                guard
                    let next = calendar.nextDate(
                        after: cursor, matching: DateComponents(hour: hour, minute: minute, second: 0),
                        matchingPolicy: .nextTime)
                else { return nil }
                if allows(next, calendar: calendar) { return next }
                cursor = next
            }
            return nil
        }
    }

    private func allows(_ date: Date, calendar: Calendar) -> Bool {
        weekdays.isEmpty || weekdays.contains(Self.isoWeekday(of: date, calendar: calendar))
    }

    private func nextAllowedDayStart(after date: Date, calendar: Calendar) -> Date? {
        var day = calendar.startOfDay(for: date)
        for _ in 0..<7 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
            if allows(day, calendar: calendar) { return day }
        }
        return nil
    }

    /// `Calendar` counts from Sunday; the manifest counts from Monday.
    static func isoWeekday(of date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }
}
