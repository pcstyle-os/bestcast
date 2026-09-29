import Foundation

/// Opted-in contributions: a capability grant, so no backup or settings file ever carries it.
@MainActor
@Observable
final class ExtensionContributionStore {
    @ObservationIgnored private let fileURL: URL

    /// Extension name → `kind:name` keys; anything absent is off.
    private var enabledKeys: [String: Set<String>]

    init(fileURL: URL) {
        self.fileURL = fileURL
        enabledKeys =
            (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: Set<String>].self, from: $0) } ?? [:]
    }

    func enabled(_ extensionName: String, _ kind: ExtensionContributionKind, _ name: String) -> Bool {
        enabledKeys[extensionName]?.contains(Self.key(kind, name)) ?? false
    }

    func set(
        _ enabled: Bool, _ extensionName: String, _ kind: ExtensionContributionKind, _ name: String
    ) {
        var keys = enabledKeys[extensionName] ?? []
        let changed =
            enabled ? keys.insert(Self.key(kind, name)).inserted : keys.remove(Self.key(kind, name)) != nil
        guard changed else { return }
        enabledKeys[extensionName] = keys.isEmpty ? nil : keys
        persist()
    }

    func forget(extension extensionName: String) {
        guard enabledKeys.removeValue(forKey: extensionName) != nil else { return }
        persist()
    }

    private static func key(_ kind: ExtensionContributionKind, _ name: String) -> String {
        kind.rawValue + ":" + name
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(enabledKeys) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
