import AppKit
import Observation

/// Runs AI Commands nobody started, on a schedule or on a matching copy, into the AI Inbox.
@MainActor
@Observable
final class AIInboxCoordinator {
    private let settings: AppSettings
    private let aiSettings: AISettingsStore
    private let commands: CustomQuickActionStore
    private let inbox: AIInboxStore
    private let appIndex: AppIndex
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private unowned let core: AppCore

    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Separate from the loop, so a poke ends only the wait and never a run in flight.
    @ObservationIgnored private var sleeper: Task<Void, any Error>?
    @ObservationIgnored private var ledger: AICommandRunLedger
    @ObservationIgnored private let ledgerURL: URL
    @ObservationIgnored private let sessionStart = Date()
    @ObservationIgnored private var wakeObserver: NotificationToken?
    @ObservationIgnored private var queueTail: Task<Void, Never>?
    @ObservationIgnored private lazy var notifier = AIInboxNotifier { [weak self] in self?.show() }

    init(
        settings: AppSettings, aiSettings: AISettingsStore, commands: CustomQuickActionStore,
        inbox: AIInboxStore, appIndex: AppIndex, palette: PaletteState,
        paletteCoordinator: PaletteCoordinator, directory: URL, core: AppCore
    ) {
        self.settings = settings
        self.aiSettings = aiSettings
        self.commands = commands
        self.inbox = inbox
        self.appIndex = appIndex
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.core = core
        ledgerURL = directory.appendingPathComponent("ai-command-runs.json")
        ledger = AICommandRunLedger.load(from: ledgerURL)
    }

    isolated deinit {
        loop?.cancel()
        sleeper?.cancel()
    }

    /// Quick Actions owns AI Commands, so its switch gates their unattended runs as well.
    private var isActive: Bool {
        settings.aiEnabled && settings.quickActionsEnabled && aiSettings.scheduledCommandsEnabled
    }

    func applyEnabled() {
        appIndex.setCommandsVisible([.aiInbox], settings.aiEnabled)
        if !settings.aiEnabled, palette.mode == .aiInbox { palette.prepare(mode: .launcher) }
        guard isActive else { return stop() }
        inbox.load()
        // Claims the delegate at launch, so a banner clicked before any run still opens the inbox.
        _ = notifier
        observeWake()
        guard loop == nil else { return poke() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runDue()
                await self.sleepUntilDue()
            }
        }
    }

    /// An edited command re-plans at once, so a new schedule never waits out the old wake.
    func commandsChanged() {
        guard isActive else { return }
        poke()
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        sleeper = nil
        wakeObserver = nil
    }

    private func poke() {
        sleeper?.cancel()
    }

    /// Task.sleep runs on the continuous clock, and the wake observer cuts it short besides.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poke() }
        }
        wakeObserver = NotificationToken(token, center: center)
    }

    private func plan(at now: Date) -> AICommandSchedulePolicy.Plan {
        let before = ledger
        ledger.reconcile(commands.actions, now: now)
        if ledger != before { ledger.save(to: ledgerURL) }
        return AICommandSchedulePolicy.plan(
            commands.actions, ledger: ledger, now: now, sessionStart: sessionStart,
            calendar: .current)
    }

    private func sleepUntilDue() async {
        let wake = plan(at: Date()).wake
        let sleeper = Task { try await Task.sleep(for: .seconds(max(1, wake.timeIntervalSinceNow))) }
        self.sleeper = sleeper
        _ = await sleeper.result
    }

    /// The run is marked before it starts, so a failing command waits for its next slot.
    private func runDue() async {
        let now = Date()
        let due = plan(at: now).due
        guard !due.isEmpty else { return }
        for id in due { ledger.noteScheduledRun(id, at: now) }
        ledger.save(to: ledgerURL)
        for id in due {
            guard isActive, !Task.isCancelled, let command = commands.action(id: id),
                let schedule = command.automation?.schedule
            else { continue }
            let cause: AIInboxEntry.Cause = schedule == .atLogin ? .login : .schedule
            await run(command, cause: cause, clipboard: Self.shareableClipboard())
        }
    }

    // MARK: - Clipboard trigger

    /// Only rows clipboard history kept arrive here, so concealed copies never reach a model.
    func clipboardCaptured(_ item: ClipboardItem) {
        guard isActive, let text = item.text else { return }
        let now = Date()
        let replies = inbox.recentReplies
        let candidates = commands.actions.compactMap { command in
            command.automation?.clipboardPattern.map {
                (command.id, $0, ledger.clipboardRuns(for: command.id))
            }
        }
        guard !candidates.isEmpty else { return }
        Task {
            let matched = await Task.detached(priority: .utility) {
                candidates.filter {
                    AICommandSchedulePolicy.clipboardTriggers(
                        text, pattern: $0.1, runs: $0.2, now: now, recentReplies: replies)
                }.map(\.0)
            }.value
            for id in matched {
                // A second copy may have matched while this one's regex ran off-main.
                guard isActive, let command = commands.action(id: id),
                    command.automation?.clipboardPattern != nil,
                    AICommandSchedulePolicy.clipboardHasBudget(
                        runs: ledger.clipboardRuns(for: id), now: now)
                else { continue }
                ledger.reconcile(commands.actions, now: now)
                ledger.noteClipboardRun(id, at: now)
                ledger.save(to: ledgerURL)
                await run(command, cause: .clipboard, clipboard: text)
            }
        }
    }

    /// A scheduled run reads the pasteboard with nobody watching, so a marked secret stays put.
    private static func shareableClipboard() -> String {
        let pasteboard = NSPasteboard.general
        if let types = pasteboard.types,
            !Set(types).isDisjoint(with: ClipboardManager.sensitiveTypes)
        {
            return ""
        }
        return pasteboard.string(forType: .string) ?? ""
    }

    // MARK: - Running

    /// Scheduled and clipboard runs share one queue, so only one ever talks to a model at a time.
    private func run(
        _ command: CustomQuickAction, cause: AIInboxEntry.Cause, clipboard: String
    ) async {
        let previous = queueTail
        let next = Task { [weak self] in
            await previous?.value
            guard let self, self.isActive, !Task.isCancelled else { return }
            await self.perform(command, cause: cause, clipboard: clipboard)
        }
        queueTail = next
        await withTaskCancellationHandler {
            await next.value
        } onCancel: {
            next.cancel()
        }
    }

    private func perform(
        _ command: CustomQuickAction, cause: AIInboxEntry.Cause, clipboard: String
    ) async {
        let started = Date()
        var prompt = ""
        let entry: AIInboxEntry
        do {
            let context = try await AICommandContextReader.gather(
                AICommandTemplate.facts(for: command.instructions),
                target: NSWorkspace.shared.frontmostApplication, injector: core.textInjector,
                clipboard: clipboard)
            let rendered = AICommandTemplate.render(command, context: context)
            prompt = rendered.chatPrompt
            let provider = try core.quickActionProvider(for: .custom(command))
            let reply = try await QuickActionRunner.run(
                rendered, temperature: command.creativity.temperature, using: provider)
            entry = AIInboxEntry(
                command: command, cause: cause, date: started, prompt: prompt, reply: reply)
        } catch is CancellationError {
            return
        } catch {
            entry = AIInboxEntry(
                command: command, cause: cause, date: started, prompt: prompt, reply: "",
                failure: error.localizedDescription)
        }
        // Switched off mid-run: nothing lands, as though the run had never started.
        guard isActive, !Task.isCancelled else { return }
        inbox.add(entry)
        if command.automation?.notifies == true { await notifier.post(entry) }
    }

    // MARK: - The inbox

    func show() {
        guard settings.aiEnabled else { return }
        inbox.load()
        paletteCoordinator.showPalette(mode: .aiInbox)
    }

    func toggle() {
        guard settings.aiEnabled else { return }
        inbox.load()
        paletteCoordinator.togglePalette(mode: .aiInbox)
    }

    /// Asked from the editor's switch, the one moment the reader is expecting the prompt.
    func requestNotificationPermission() async -> Bool {
        _ = notifier
        return await AIInboxNotifier.requestAuthorization()
    }

    func copy(_ entry: AIInboxEntry) {
        guard entry.failure == nil else { return }
        Paster.copyPlainText(entry.reply)
        core.showMessage("Reply copied")
    }

    func openInChat(_ entry: AIInboxEntry) {
        guard entry.failure == nil, settings.aiEnabled else { return }
        let model = commands.action(id: entry.commandID).flatMap {
            core.quickActionSettings.model(for: .custom($0))
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.quickActionCoordinator.continueInChat(
            prompt: entry.prompt, reply: entry.reply, model: model)
    }

    func delete(id: UUID) {
        inbox.remove(id: id)
    }

    func deleteAll() async {
        guard !inbox.entries.isEmpty,
            await core.confirm(
                title: "Delete every AI Inbox reply?",
                message: "Replies from scheduled and clipboard-triggered AI Commands go for good.",
                symbol: CommandID.aiInbox.sfSymbol, confirmTitle: "Delete All")
        else { return }
        inbox.removeAll()
    }
}
