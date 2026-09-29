import Foundation

/// Replies from commands that ran by themselves, newest first.
@MainActor
@Observable
final class AIInboxStore {
    static let capacity = 200
    /// How many latest replies the clipboard trigger ignores, so copying one never re-runs it.
    static let echoWindow = 20

    private(set) var entries: [AIInboxEntry] = []
    /// False when the file wouldn't read; every mutation then refuses rather than overwrite it.
    private(set) var isAvailable = true
    @ObservationIgnored private var loaded = false

    private let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("ai-inbox.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([AIInboxEntry].self, from: data)
        else {
            isAvailable = false
            return
        }
        entries = Array(decoded.sorted { $0.date > $1.date }.prefix(Self.capacity))
    }

    func entry(id: UUID) -> AIInboxEntry? {
        entries.first { $0.id == id }
    }

    func add(_ entry: AIInboxEntry) {
        commit(Array(([entry] + entries).sorted { $0.date > $1.date }.prefix(Self.capacity)))
    }

    func remove(id: UUID) {
        commit(entries.filter { $0.id != id })
    }

    func removeAll() {
        commit([])
    }

    func search(_ query: String) -> [AIInboxEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.commandName.localizedStandardContains(needle)
                || $0.reply.localizedStandardContains(needle)
                || ($0.failure?.localizedStandardContains(needle) ?? false)
        }
    }

    var recentReplies: Set<String> {
        Set(
            entries.prefix(Self.echoWindow).map {
                $0.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            })
    }

    private func commit(_ updated: [AIInboxEntry]) {
        guard isAvailable, updated != entries else { return }
        entries = updated
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(updated) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
