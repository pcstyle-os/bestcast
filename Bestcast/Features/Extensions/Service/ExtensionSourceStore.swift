import Foundation

struct ExtensionSourceRecord: Codable, Sendable, Hashable {
    var kind: ExtensionSourceKind
    /// The linked folder, the installed copy's directory, or the folder it was added from.
    var path: String
    var url: String?
    var ref: String?
    var commit: String?
    var linkedAt: Date
}

/// The whole of `extension-sources.json`.
struct ExtensionSourcesFile: Codable, Sendable, Equatable {
    var extensions: [String: ExtensionSourceRecord] = [:]
    var scriptFolders: [String] = []
}

/// Keyed by manifest name like appearances; a file of its own so neither backups nor
/// `settings.json` can carry a folder that runs code.
@MainActor
@Observable
final class ExtensionSourceStore {
    private(set) var contents: ExtensionSourcesFile
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = ExtensionCatalog.sourcesFile()) {
        self.fileURL = fileURL
        contents =
            (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(ExtensionSourcesFile.self, from: $0) }
            ?? ExtensionSourcesFile()
    }

    /// `ray build -e dist` writes its manifest to `dist/`; a folder without one is read as is.
    nonisolated static func manifestRoot(of folder: URL) -> URL {
        let dist = folder.appendingPathComponent("dist", isDirectory: true)
        let built = dist.appendingPathComponent("package.json").path
        return FileManager.default.fileExists(atPath: built) ? dist : folder
    }

    var linkedDirectories: [URL] {
        contents.extensions.values.filter { $0.kind == .linked }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    var scriptFolders: [URL] {
        contents.scriptFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func record(for extensionName: String) -> ExtensionSourceRecord? {
        contents.extensions[extensionName]
    }

    func set(_ record: ExtensionSourceRecord?, for extensionName: String) {
        contents.extensions[extensionName] = record
        persist()
    }

    func addScriptFolder(_ folder: URL) {
        guard !contents.scriptFolders.contains(folder.path) else { return }
        contents.scriptFolders.append(folder.path)
        persist()
    }

    func removeScriptFolder(_ folder: URL) {
        contents.scriptFolders.removeAll { $0 == folder.path }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(contents) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
