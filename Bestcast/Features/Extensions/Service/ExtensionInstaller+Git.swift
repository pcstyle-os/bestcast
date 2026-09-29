import Foundation

extension ExtensionInstaller {
    struct GitInstall: Sendable {
        let installed: InstalledExtension
        let commit: String
    }

    private static let gitExecutable = URL(fileURLWithPath: "/usr/bin/git")

    /// A shallow clone; committed bundles install as they are, anything else goes through `build`.
    func install(
        from git: ExtensionGitURL, onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws -> GitInstall {
        let workspace = ExtensionCleanup.workspace(in: FileManager.default.temporaryDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        onProgress(.cloning)
        let clone = workspace.appendingPathComponent("source", isDirectory: true)
        var arguments = ["clone", "--depth", "1", "--quiet"]
        if let ref = git.ref { arguments += ["--branch", ref] }
        arguments += ["--", git.cloneURL.absoluteString, clone.path]
        // A private repository would otherwise wait forever on a credential prompt nobody sees.
        let quiet = ["GIT_TERMINAL_PROMPT": "0"]
        let cloned = try await run(
            Self.gitExecutable, arguments: arguments, in: workspace, extraEnvironment: quiet)
        guard cloned.status == 0 else {
            throw ExtensionStoreError.downloadFailed(cloned.trimmedOutput)
        }
        let head = try await run(
            Self.gitExecutable, arguments: ["rev-parse", "HEAD"], in: clone, extraEnvironment: quiet)
        let commit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let source = git.subdirectory.map { clone.appendingPathComponent($0, isDirectory: true) }
            ?? clone
        let prepared: URL
        if let prebuilt = Self.prebuiltRoot(in: source) {
            prepared = prebuilt
        } else {
            prepared = try await build(
                at: source, into: workspace.appendingPathComponent("build", isDirectory: true),
                onProgress: onProgress)
        }
        onProgress(.installing)
        return GitInstall(installed: try ExtensionCatalog.install(from: prepared), commit: commit)
    }

    /// `ray build` output sits beside its own manifest, in the folder itself or in `dist/`.
    nonisolated static func prebuiltRoot(in source: URL) -> URL? {
        [source, source.appendingPathComponent("dist", isDirectory: true)].first { root in
            guard let manifest = try? ExtensionManifest.load(directory: root) else { return false }
            let bundles =
                manifest.commands.map { root.appendingPathComponent("\($0.name).js") }
                + manifest.tools.map { root.appendingPathComponent("tools/\($0.name).js") }
            return !bundles.isEmpty
                && bundles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
    }
}
