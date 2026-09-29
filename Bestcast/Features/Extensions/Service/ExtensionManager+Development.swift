import Foundation

/// Linking a folder in place, installing from a Git URL, and reloading what a developer edits.
extension ExtensionManager {
    enum DevelopmentError: LocalizedError {
        case notAnExtension(URL)
        case wrongPlatform(String)

        var errorDescription: String? {
            switch self {
            case .notAnExtension(let folder):
                return "\(folder.lastPathComponent) has no package.json with commands or tools."
            case .wrongPlatform(let title):
                return "\(title) doesn't support macOS."
            }
        }
    }

    /// Read where it is, never copied, so an edit in the folder is what runs next.
    @discardableResult
    func link(folder: URL) async throws -> InstalledExtension {
        let root = ExtensionSourceStore.manifestRoot(of: folder)
        let manifest = await Task.detached(priority: .userInitiated) {
            try? ExtensionManifest.load(directory: root)
        }.value
        guard let manifest else { throw DevelopmentError.notAnExtension(folder) }
        guard manifest.supportsMacOS else { throw DevelopmentError.wrongPlatform(manifest.title) }
        sources.set(
            ExtensionSourceRecord(kind: .linked, path: folder.path, linkedAt: Date()),
            for: manifest.name)
        await refresh()
        return InstalledExtension(manifest: manifest, directory: root, source: .linked)
    }

    /// The folder the developer linked, rather than the `dist/` inside it the scan reads.
    func linkedFolder(of owner: InstalledExtension) -> URL? {
        guard owner.isDevelopment, let record = sources.record(for: owner.manifest.name) else {
            return nil
        }
        return URL(fileURLWithPath: record.path, isDirectory: true)
    }

    /// Three minutes a step: a Git install is unattended code, and a hung build must end.
    func install(
        git: ExtensionGitURL, packageManager: ExtensionPackageManager,
        additionalSearchPaths: [String],
        onProgress: @Sendable @escaping (ExtensionInstaller.Progress) -> Void
    ) async throws -> InstalledExtension {
        let installer = ExtensionInstaller(
            packageManager: packageManager, additionalSearchPaths: additionalSearchPaths,
            commandTimeout: .seconds(180))
        let result = try await installer.install(from: git, onProgress: onProgress)
        sources.set(
            ExtensionSourceRecord(
                kind: .git, path: result.installed.directory.path, url: git.displayString,
                ref: git.ref, commit: result.commit, linkedAt: Date()),
            for: result.installed.manifest.name)
        await refresh()
        return result.installed
    }

    func recordSource(_ kind: ExtensionSourceKind, path: URL, for installed: InstalledExtension) {
        sources.set(
            ExtensionSourceRecord(kind: kind, path: path.path, linkedAt: Date()),
            for: installed.manifest.name)
    }

    /// Stop, then run the same command again, when a change lands in the running one's folder.
    func reloadDevelopmentCommand(changed: Set<URL>) async -> Bool {
        guard let running, let owner = extensionNamed(running.extensionName),
            let folder = linkedFolder(of: owner),
            let command = owner.command(named: running.commandName)
        else { return false }
        let root = folder.resolvingSymlinksInPath().path
        guard
            changed.contains(where: {
                let path = $0.resolvingSymlinksInPath().path
                return path == root || path.hasPrefix(root + "/")
            })
        else { return false }
        await run(owner, command: command, arguments: runningArguments)
        return true
    }
}
