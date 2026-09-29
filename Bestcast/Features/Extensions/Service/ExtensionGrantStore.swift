import Foundation

/// What each extension may reach through `@bestcast/api`. Its own file, so no backup carries it.
@MainActor
@Observable
final class ExtensionGrantStore {
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// Extension name → its grants, one per capability.
    private var records: [String: [ExtensionGrant]]
    /// A read the user refused, remembered until quit so a loop cannot re-ask it into a nag.
    private var refusals: [String: Set<ExtensionCapability>] = [:]

    init(
        fileURL: URL = AppPaths.applicationSupport()
            .appending(path: "extension-grants.json", directoryHint: .notDirectory),
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.now = now
        records =
            (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: [ExtensionGrant]].self, from: $0) } ?? [:]
    }

    var extensionNames: [String] { records.keys.sorted() }

    func grants(for name: String) -> [ExtensionGrant] {
        (records[name] ?? []).sorted { $0.capability.rawValue < $1.capability.rawValue }
    }

    func grant(for name: String, capability: ExtensionCapability) -> ExtensionGrant? {
        records[name]?.first { $0.capability == capability }
    }

    func isRefused(_ capability: ExtensionCapability, extension name: String) -> Bool {
        refusals[name]?.contains(capability) == true
    }

    func refuse(_ capability: ExtensionCapability, extension name: String) {
        guard !capability.isWrite else { return }
        refusals[name, default: []].insert(capability)
    }

    func grant(_ capability: ExtensionCapability, always: Bool, extension name: String) {
        refusals[name]?.remove(capability)
        guard let grant = ExtensionGrantPolicy.grant(capability, always: always, now: now()) else {
            return
        }
        var list = records[name] ?? []
        list.removeAll { $0.capability == capability }
        list.append(grant)
        records[name] = list
        flush()
    }

    func revoke(_ capability: ExtensionCapability, extension name: String) {
        refusals[name]?.remove(capability)
        guard var list = records[name] else { return }
        list.removeAll { $0.capability == capability }
        records[name] = list.isEmpty ? nil : list
        flush()
    }

    func revokeAll(extension name: String) {
        refusals[name] = nil
        guard records.removeValue(forKey: name) != nil else { return }
        flush()
    }

    /// Uninstall: nothing an extension was allowed survives it.
    func forget(extension name: String) {
        revokeAll(extension: name)
    }

    /// Last-used stamps are cosmetic, so they coalesce rather than write on every call.
    func touch(_ capability: ExtensionCapability, extension name: String) {
        guard var list = records[name],
            let index = list.firstIndex(where: { $0.capability == capability })
        else { return }
        list[index].lastUsedAt = now()
        records[name] = list
        scheduleFlush()
    }

    /// Consent changes write at once: a revoke that a crash could undo is not a revoke.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
