import AppKit

/// What a developer or a scripter adds beside the store: links, clones, console, scripts.
@MainActor
final class ExtensionDevelopmentCoordinator {
    private let extensions: ExtensionManager
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let settings: AppSettings
    /// Dialog and message-HUD presentation only — never for state this type owns.
    private unowned let core: AppCore
    let scripts: ScriptCommandLibrary
    private let consoleWindow: ExtensionConsoleWindowController
    private var watcher: ExtensionFolderWatcher?
    private var watchTask: Task<Void, Never>?
    /// Built on first use; the window waits for a full-output script to actually run.
    private lazy var outputPresenter = CommandOutputPresenter(
        activation: core.activationPolicy,
        rerun: { [unowned self] id in self.rerunScript(commandID: id) },
        stop: { [unowned self] id in self.stopScript(runID: id) },
        openSettings: { [unowned self] in self.settingsCoordinator.showSettings(tab: .extensions) })
    private var liveRun: (id: UUID, stop: @Sendable () -> Void)?
    private var gitInstall: Task<InstalledExtension, Error>?

    init(
        extensions: ExtensionManager, appIndex: AppIndex, paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator, settings: AppSettings, core: AppCore
    ) {
        self.extensions = extensions
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.settings = settings
        self.core = core
        scripts = ScriptCommandLibrary(sources: extensions.sources, appIndex: appIndex)
        consoleWindow = ExtensionConsoleWindowController(
            console: extensions.console, activation: core.activationPolicy)
    }

    /// Before the first `setEnabled`, so launch is the same path as the switch.
    func start() {
        extensions.onEnabledChange = { [weak self] enabled in
            guard let self else { return }
            self.watchLinkedFolders(enabled: enabled)
            Task { await self.scripts.setActive(enabled) }
        }
    }

    // MARK: - Linked folders

    private func watchLinkedFolders(enabled: Bool = true) {
        watchTask?.cancel()
        watchTask = nil
        watcher = enabled ? ExtensionFolderWatcher(folders: extensions.sources.linkedDirectories) : nil
        guard let changes = watcher?.changes else { return }
        watchTask = Task { [weak self] in
            for await changed in changes {
                guard let self else { return }
                await self.extensions.refresh()
                if await self.extensions.reloadDevelopmentCommand(changed: changed) {
                    self.core.showMessage("Reloaded")
                }
            }
        }
    }

    func linkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        panel.message = "Choose an extension's source folder. It is read in place, never copied."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            do {
                let linked = try await extensions.link(folder: folder)
                watchLinkedFolders()
                core.showMessage("Linked \(linked.title)")
            } catch {
                await report("Couldn\u{2019}t Link Folder", error: error)
            }
        }
    }

    /// Forgets the link through the ordinary uninstall, which leaves a linked folder on disk.
    func unlink(_ owner: InstalledExtension) {
        Task {
            await extensions.uninstall(owner)
            watchLinkedFolders()
            core.showMessage("Unlinked \(owner.title)")
        }
    }

    func reveal(_ owner: InstalledExtension) {
        let folder = extensions.linkedFolder(of: owner) ?? owner.directory
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: - Console

    func openConsole(for owner: InstalledExtension) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        consoleWindow.show(extensionName: owner.manifest.name, title: owner.title)
    }

    /// What the ⌘K panel offers: a linked extension always, any other once the hidden pref is on.
    func consoleOpener(for running: ExtensionCommandRef?) -> (() -> Void)? {
        guard let running, let owner = extensions.extensionNamed(running.extensionName),
            owner.isDevelopment || settings.extensionsShowConsole
        else { return nil }
        return { [weak self] in self?.openConsole(for: owner) }
    }

    // MARK: - Installing from Git

    func installFromGit(_ text: String) {
        guard let url = ExtensionGitURL(text) else {
            core.showMessage("Not a GitHub repository URL", tone: .danger)
            return
        }
        Task { await installFromGit(url, verb: "Install") }
    }

    func updateFromGit(_ owner: InstalledExtension) {
        guard let recorded = extensions.sources.record(for: owner.manifest.name)?.url,
            let url = ExtensionGitURL(recorded)
        else { return }
        Task { await installFromGit(url, verb: "Update") }
    }

    /// A clone runs whatever its build scripts say, so it asks every time, updates included.
    private func installFromGit(_ url: ExtensionGitURL, verb: String) async {
        NSApp.activate(ignoringOtherApps: true)
        guard
            await core.confirm(
                title: "\(verb) from Git?",
                message:
                    "This will download and build code from \(url.displayString). Build scripts "
                    + "run on your Mac.",
                symbol: "arrow.down.circle", confirmTitle: verb, tone: .neutral,
                confirmRole: .standard)
        else { return }
        let packageManager = settings.extensionPackageManager
        let searchPaths = settings.extensionCustomSearchPaths
        guard gitInstall == nil else { return }
        let install = Task {
            try await extensions.install(
                git: url, packageManager: packageManager, additionalSearchPaths: searchPaths,
                onProgress: { progress in
                    Task { @MainActor [weak self] in self?.showGitProgress(progress) }
                })
        }
        gitInstall = install
        showGitProgress(.cloning)
        let result = await install.result
        gitInstall = nil
        core.hideProgress()
        switch result {
        case .success(let installed):
            core.showMessage("\(verb == "Update" ? "Updated" : "Installed") \(installed.title)")
        case .failure(let error):
            guard !install.isCancelled else { return }
            await report("Couldn\u{2019}t \(verb) from Git", error: error)
        }
    }

    /// A step that lands after the install ended must not bring the pill back.
    private func showGitProgress(_ progress: ExtensionInstaller.Progress) {
        guard gitInstall != nil else { return }
        core.showProgress(progress.message, onCancel: { [weak self] in self?.gitInstall?.cancel() })
    }

    // MARK: - Script Command folders

    func addScriptFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder of Raycast script commands."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            guard
                await core.confirm(
                    title: "Add \(folder.lastPathComponent)?",
                    message:
                        "Scripts in this folder will be runnable from the launcher, and inline "
                        + "scripts run on a timer.",
                    symbol: "terminal", confirmTitle: "Add", tone: .neutral, confirmRole: .standard)
            else { return }
            extensions.sources.addScriptFolder(folder)
            await scripts.reload()
        }
    }

    func removeScriptFolder(_ folder: URL) {
        extensions.sources.removeScriptFolder(folder)
        Task { await scripts.reload() }
    }

    /// The one funnel: owed arguments reopen the row, confirmation asks, the mode picks the report.
    func runScript(_ app: AppEntry, values: [String: String]) {
        guard settings.extensionsEnabled, let header = scripts.header(entryID: app.id) else { return }
        guard let arguments = header.command.positionalValues(from: values) else {
            paletteCoordinator.showArguments(of: app, values: values)
            return
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        Task { await perform(header, arguments: arguments) }
    }

    private func perform(_ header: ScriptCommandHeader, arguments: [String]) async {
        if header.needsConfirmation {
            guard
                await core.confirm(
                    title: header.title, message: "Are you sure you want to run this script?",
                    symbol: "terminal", confirmTitle: "Run", tone: .neutral,
                    confirmRole: .standard)
            else { return }
        }
        guard header.mode != .fullOutput else {
            await streamOutput(of: header, arguments: arguments)
            return
        }
        let command = header.command
        let result = await ShellCommandRunner.run(
            command.command, arguments: arguments,
            loadingShellEnvironment: command.loadsShellEnvironment,
            workingDirectory: command.workingDirectory)
        let line = result.lastOutputLine
        guard result.succeeded else {
            core.showMessage(line ?? result.standardError ?? "\(header.title) failed", tone: .danger)
            return
        }
        core.showMessage(line ?? "Ran \(header.title)")
    }

    private func streamOutput(of header: ScriptCommandHeader, arguments: [String]) async {
        let command = header.command
        let session = ShellCommandRunner.stream(
            command.command, arguments: arguments,
            loadingShellEnvironment: command.loadsShellEnvironment,
            workingDirectory: command.workingDirectory)
        let runID = outputPresenter.begin(
            commandID: command.id, name: header.title, commandText: header.url.path,
            symbol: "terminal")
        liveRun = (runID, session.stop)
        defer { if liveRun?.id == runID { liveRun = nil } }
        for await event in session.events {
            switch event {
            case .output(let text):
                outputPresenter.append(text, to: runID)
            case .finished(let result):
                outputPresenter.finish(
                    CommandOutcome(
                        summary: result.succeeded ? "Finished successfully." : summary(of: result),
                        hint: nil, succeeded: result.succeeded, finishedAt: Date()),
                    for: runID)
            }
        }
    }

    private func summary(of result: ShellCommandResult) -> String {
        switch result.termination {
        case .launchFailed(let detail): "The script could not be started. \(detail)"
        case .stopped: "Stopped"
        case .exited(let status): "The script exited with status \(status)."
        }
    }

    private func rerunScript(commandID: UUID) {
        guard let header = scripts.headers.values.first(where: { $0.command.id == commandID }) else {
            return
        }
        guard !header.arguments.contains(where: { !$0.isOptional }) else {
            paletteCoordinator.showArguments(
                of: AppEntry(
                    id: ScriptCommandLibrary.entryID(for: header.url), name: header.title,
                    url: header.url, bundleID: nil, kind: .scriptCommand),
                values: [:])
            return
        }
        Task { await perform(header, arguments: []) }
    }

    private func stopScript(runID: UUID) {
        guard let liveRun, liveRun.id == runID else { return }
        liveRun.stop()
    }

    private func report(_ title: String, error: Error) async {
        await core.showNotice(
            title: title, message: error.localizedDescription, symbol: "exclamationmark.triangle",
            tone: .danger)
    }
}
