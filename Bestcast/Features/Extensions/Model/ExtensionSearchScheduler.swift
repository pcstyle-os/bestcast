import Foundation

/// When a search provider runs, and whether its answer still matters by the time it lands.
struct ExtensionSearchScheduler: Sendable {
    static let debounce: Duration = .milliseconds(150)
    static let timeout: Duration = .milliseconds(800)

    private(set) var generation = 0
    private(set) var query = ""
    private(set) var changedAt = Date.distantPast

    /// Every keystroke is a new generation, so a slower answer to an older query is dropped.
    @discardableResult
    mutating func noteQuery(_ query: String, now: Date) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != self.query else { return generation }
        self.query = trimmed
        changedAt = now
        generation += 1
        return generation
    }

    mutating func reset() {
        query = ""
        changedAt = .distantPast
        generation += 1
    }

    /// Only the query still typed, once it has settled, and only if it addresses this provider.
    func shouldQuery(query: String, provider: ExtensionSearchProvider, now: Date) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == self.query, !trimmed.isEmpty,
            now.timeIntervalSince(changedAt) >= Self.seconds(Self.debounce),
            let input = Self.input(for: trimmed, provider: provider)
        else { return false }
        return input.count >= provider.minLength
    }

    func accept(generation: Int) -> Bool { generation == self.generation }

    static func isExpired(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) > seconds(timeout)
    }

    /// The text the provider is handed: the query past its prefix, or nil when it isn't addressed.
    static func input(for query: String, provider: ExtensionSearchProvider) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = provider.prefix else { return trimmed }
        guard let range = trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) else {
            return nil
        }
        return trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
