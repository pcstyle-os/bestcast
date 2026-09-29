import Foundation

/// Each chat's library index, a file per chat under Caches: a purge costs a re-index, not a chat.
nonisolated struct ChatLibraryStore: Sendable {
    let directory: URL

    func save(_ index: ChatLibraryIndex, for id: UUID) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(index) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: id), options: .atomic)
    }

    func load(_ id: UUID) -> ChatLibraryIndex? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? PropertyListDecoder().decode(ChatLibraryIndex.self, from: data)
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Drops every index whose chat is gone: deleted, pruned, or never sent before it was left.
    func prune(keeping ids: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            let id = UUID(uuidString: (name as NSString).deletingPathExtension)
            guard id.map({ !ids.contains($0) }) ?? true else { continue }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    private func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).plist", directoryHint: .notDirectory)
    }
}
