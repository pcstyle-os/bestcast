import AppKit

/// The launcher rows of every consented Script Command folder, rescanned whenever one changes.
@MainActor
@Observable
final class ScriptCommandLibrary {
    static let entryIDPrefix = "script-command:"
    /// Unattended, so a hung inline script is stopped rather than left running out of sight.
    static let inlineTimeout: Duration = .seconds(30)

    private(set) var headers: [String: ScriptCommandHeader] = [:]
    @ObservationIgnored private var subtitles: [String: String] = [:]
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var watcher: ExtensionFolderWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var inlineTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let sources: ExtensionSourceStore
    @ObservationIgnored private let appIndex: AppIndex

    init(sources: ExtensionSourceStore, appIndex: AppIndex) {
        self.sources = sources
        self.appIndex = appIndex
    }

    static func entryID(for script: URL) -> String { entryIDPrefix + script.path }

    func header(entryID: String) -> ScriptCommandHeader? { headers[entryID] }

    /// Follows the extensions switch: off stops every inline timer and empties the section.
    func setActive(_ active: Bool) async {
        isActive = active
        guard active else {
            watcher = nil
            watchTask?.cancel()
            watchTask = nil
            inlineTasks.values.forEach { $0.cancel() }
            inlineTasks = [:]
            headers = [:]
            subtitles = [:]
            appIndex.setScriptCommands([])
            return
        }
        await reload()
    }

    /// A folder added or removed: rescan, and watch the new set.
    func reload() async {
        guard isActive else { return }
        watch(sources.scriptFolders)
        await rescan()
    }

    private func watch(_ folders: [URL]) {
        watchTask?.cancel()
        watcher = ExtensionFolderWatcher(folders: folders)
        guard let changes = watcher?.changes else { return }
        watchTask = Task { [weak self] in
            for await _ in changes {
                await self?.rescan()
            }
        }
    }

    private func rescan() async {
        let folders = sources.scriptFolders
        let found = await Task.detached(priority: .utility) { Self.scan(folders) }.value
        guard isActive else { return }
        let scanned = Dictionary(
            found.map { (Self.entryID(for: $0.url), $0) }, uniquingKeysWith: { first, _ in first })
        guard scanned != headers else { return }
        headers = scanned
        subtitles = subtitles.filter { scanned[$0.key] != nil }
        restartInline()
        publish()
    }

    /// Non-recursive, like Raycast's own script directories.
    nonisolated static func scan(_ folders: [URL]) -> [ScriptCommandHeader] {
        folders.flatMap { folder in
            let contents =
                (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
            return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url -> ScriptCommandHeader? in
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                        let source = RaycastScriptImport.head(of: url)
                    else { return nil }
                    return ScriptCommandHeader(url: url, source: source)
                }
        }
    }

    /// A script owing a required argument has nothing to run on a timer.
    private func restartInline() {
        inlineTasks.values.forEach { $0.cancel() }
        inlineTasks = [:]
        for (id, header) in headers where header.mode == .inline {
            guard !header.arguments.contains(where: { !$0.isOptional }) else { continue }
            inlineTasks[id] = Task { [weak self] in
                repeat {
                    let result = await ShellCommandRunner.run(
                        header.command.command, arguments: [],
                        loadingShellEnvironment: header.command.loadsShellEnvironment,
                        workingDirectory: header.command.workingDirectory,
                        timeout: Self.inlineTimeout)
                    guard !Task.isCancelled, let self else { return }
                    self.subtitles[id] = result.lastOutputLine
                    self.publish()
                    guard let interval = header.refreshTime else { return }
                    try? await Task.sleep(for: interval)
                } while !Task.isCancelled
            }
        }
    }

    private func publish() {
        let entries = headers.map { id, header in
            AppEntry(
                id: id, name: header.title, url: header.url, bundleID: nil, kind: .scriptCommand,
                subtitle: subtitles[id] ?? header.packageName,
                iconOverride: header.icon.flatMap(Self.icon))
        }
        appIndex.setScriptCommands(
            entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    private static func icon(_ icon: ScriptCommandHeader.Icon) -> EntryIcon? {
        switch icon {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return .artwork(path: url.path, extent: ExtensionIconCache.extent)
        case .emoji(let emoji):
            return emojiArtwork(emoji).map { .artwork(path: $0.path, extent: ExtensionIconCache.extent) }
        }
    }

    /// The launcher draws artwork from a file, so an emoji is rendered to one once and reused.
    private static func emojiArtwork(_ emoji: String) -> URL? {
        let directory = AppPaths.caches().appendingPathComponent("script-icons", isDirectory: true)
        let name = emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
        let file = directory.appendingPathComponent(name + ".png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let side: CGFloat = 128
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let text = NSAttributedString(
                string: emoji, attributes: [.font: NSFont.systemFont(ofSize: side * 0.78)])
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? png.write(to: file, options: .atomic)) == nil ? nil : file
    }
}
