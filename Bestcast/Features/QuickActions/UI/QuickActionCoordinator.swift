import AppKit
import Observation

/// The single funnel for every Quick Action, however it was started.
@MainActor
@Observable
final class QuickActionCoordinator {
    private let settings: AppSettings
    private let store: QuickActionSettingsStore
    private let customActions: CustomQuickActionStore
    private let injector: TextInjector
    private let appIndex: AppIndex
    private let hotKeys: HotKeyManager
    private let favorites: FavoritesStore
    private let visibility: VisibilityStore
    private let ranking: LauncherRankingStore
    private let aliases: AliasStore
    private let paletteCoordinator: PaletteCoordinator
    private let panels = QuickActionPanelController()
    private unowned let core: AppCore

    private static let launcherCommands = Set(
        BuiltInQuickAction.allCases.map(CommandID.init) + [.browseAICommands])

    /// Set by the launcher's Browse AI Commands; the Settings pane opens its library and clears it.
    var libraryRequested = false

    /// One at a time: two runs race for one selection, and the second overwrites the first's work.
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Cancellation is cooperative, so a cancelled run must not hide the pill a newer run showed.
    @ObservationIgnored private var progressOwner: Int?

    init(
        settings: AppSettings, store: QuickActionSettingsStore,
        customActions: CustomQuickActionStore, injector: TextInjector,
        appIndex: AppIndex, hotKeys: HotKeyManager, favorites: FavoritesStore,
        visibility: VisibilityStore, ranking: LauncherRankingStore, aliases: AliasStore,
        paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.store = store
        self.customActions = customActions
        self.injector = injector
        self.appIndex = appIndex
        self.hotKeys = hotKeys
        self.favorites = favorites
        self.visibility = visibility
        self.ranking = ranking
        self.aliases = aliases
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Launcher rows come and go with the switch; the Carbon bindings stay registered.
    func applyEnabled() {
        appIndex.setCommandsVisible(Self.launcherCommands, settings.quickActionsEnabled)
        applyCustomQuickActionsPresence()
        guard settings.quickActionsEnabled else {
            cancel()
            core.applyInstalledAILifecycle()
            return
        }
        core.applyInstalledAILifecycle()
        store.resolveModel(
            appleIntelligenceAvailable: core.aiSettings.isAppleIntelligenceAvailable(),
            fallback: core.aiSettings.defaultModel)
        loadLanguages()
    }

    /// Enabling is consent: reading a selection and typing over it both need Accessibility.
    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.quickActionsEnabled else { return }
        guard enabled else {
            settings.quickActionsEnabled = false
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: "Enable Quick Actions?",
                    message:
                        "Bestcast needs the Accessibility permission to read the text you have "
                        + "selected in other apps and replace it. Nothing is read until you press "
                        + "a shortcut.",
                    symbol: "wand.and.sparkles", confirmTitle: "Continue", tone: .neutral,
                    confirmRole: .standard)
            else { return }
            settings.quickActionsEnabled = true
            // The one prompt for this feature, raised from the gesture that asked for it.
            Permissions.ensureAccessibility()
        }
    }

    func applyCustomQuickActionsPresence() {
        appIndex.setCustomQuickActions(
            settings.quickActionsEnabled ? customActions.actions : [])
    }

    // MARK: - The reader's own actions

    /// The route is stored only once the record is on disk, so a refused save leaves neither behind.
    func addCustomQuickAction(
        _ draft: CustomQuickAction, model: AIModelSelection?
    ) throws(CustomQuickActionError) {
        let action = try customActions.add(draft)
        store.setModelOverride(model, for: .custom(action))
    }

    func updateCustomQuickAction(
        _ draft: CustomQuickAction, model: AIModelSelection?
    ) throws(CustomQuickActionError) {
        try customActions.update(draft)
        store.setModelOverride(model, for: .custom(draft))
    }

    func setOutput(_ output: AICommandOutput, id: UUID) {
        do {
            try customActions.setOutput(output, id: id)
        } catch {
            report(error)
        }
    }

    func addFromLibrary(_ entry: AICommandLibrary.Entry) {
        do {
            _ = try customActions.add(entry.makeCommand(now: Date()))
        } catch {
            report(error)
        }
    }

    func browseLibrary() {
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        libraryRequested = settings.quickActionsEnabled
        core.settingsCoordinator.showSettings(
            tab: .quickActions, revealing: .section(.quickActionsAICommands))
    }

    /// Only the reader's own commands leave: a built-in is not theirs to hand to another app.
    func exportCommands() async {
        guard !customActions.actions.isEmpty,
            let destination = BackupActions.chooseSaveLocation(named: "AI Commands")
        else { return }
        do {
            try AICommandArchive.encode(customActions.actions).write(to: destination, options: .atomic)
            core.showMessage("Exported \(countLabel(customActions.actions.count))")
        } catch {
            await core.showNotice(
                title: "Couldn’t Export AI Commands", message: error.localizedDescription,
                symbol: CustomQuickAction.sfSymbol, tone: .danger)
        }
    }

    func importCommands() async {
        guard let source = BackupActions.chooseJSONFile() else { return }
        do {
            let data = try Data(contentsOf: source)
            let imported = try AICommandArchive.decode(
                data, existing: customActions.actions, now: Date(),
                isKnownSymbol: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
            try customActions.add(contentsOf: imported.commands)
            guard !imported.commands.isEmpty else {
                return core.showMessage("Every AI Command in that file is already here")
            }
            let skipped = imported.duplicates == 0 ? "" : ", \(imported.duplicates) already present"
            core.showMessage("Imported \(countLabel(imported.commands.count))\(skipped)")
        } catch {
            await core.showNotice(
                title: "Couldn’t Import AI Commands", message: error.localizedDescription,
                symbol: CustomQuickAction.sfSymbol, tone: .danger)
        }
    }

    private func countLabel(_ count: Int) -> String {
        count == 1 ? "1 AI Command" : "\(count) AI Commands"
    }

    func deleteCustomQuickAction(id: UUID) async {
        guard let action = customActions.action(id: id) else { return }
        guard
            await core.confirm(
                title: "Delete “\(action.name)”?",
                message: "Its instructions, shortcut and learned ranking go with it.",
                symbol: action.symbol, confirmTitle: "Delete")
        else { return }
        // Unwound only once the row is gone, so a kept record never loses its shortcut.
        do {
            guard let removed = try customActions.remove(id: id) else { return }
            removeCustomQuickActionReferences(removed)
        } catch {
            report(error)
        }
    }

    private func report(_ error: CustomQuickActionError) {
        Task {
            await core.showNotice(
                title: "Couldn’t Save the Change", message: error.localizedDescription,
                symbol: CustomQuickAction.sfSymbol, tone: .danger)
        }
    }

    private func removeCustomQuickActionReferences(_ action: CustomQuickAction) {
        let hotKeyAction = HotKeyAction.quickAction(id: action.id)
        if hotKeys.recordingAction == hotKeyAction { hotKeys.recordingAction = nil }
        hotKeys.setBinding(nil, for: hotKeyAction)
        store.setModelOverride(nil, for: .custom(action))
        favorites.remove(keys: [action.entryID])
        visibility.removeItemKeys([action.entryID])
        aliases.removeKeys([action.entryID])
        ranking.reset(itemKey: action.entryID)
    }

    /// A shortcut has no fields to type into, so a command still owed an argument asks in root search.
    func run(id: UUID, arguments: [String: String] = [:]) {
        guard let action = customActions.action(id: id) else { return }
        let missing = AICommandTemplate.missingArguments(in: action.instructions, values: arguments)
        if settings.quickActionsEnabled, running == nil, !missing.isEmpty {
            paletteCoordinator.showArguments(of: AppEntry(action), values: arguments)
            return
        }
        run(.custom(action), arguments: arguments)
    }

    func run(_ action: QuickAction, arguments: [String: String] = [:]) {
        guard settings.quickActionsEnabled, running == nil else { return }
        let target = paletteCoordinator.targetApp
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        start { [weak self] in
            guard let self else { return }
            if let command = action.customAction {
                await self.begin(command, arguments: arguments, target: target)
            } else {
                await self.begin(action, target: target)
            }
        }
    }

    func cancel() {
        generation += 1
        running?.cancel()
        running = nil
        hideProgress(ownedBy: progressOwner)
        panels.dismiss()
    }

    /// The generation stops a superseded task from clearing the newer handle as it finishes.
    private func start(_ work: @escaping @MainActor () async -> Void) {
        generation += 1
        let mine = generation
        running?.cancel()
        running = Task { [weak self] in
            await work()
            guard let self, mine == self.generation else { return }
            self.running = nil
        }
    }

    private func begin(_ action: QuickAction, target: NSRunningApplication?) async {
        let selection: String
        do {
            selection = try await QuickActionRunner.selection(in: target, using: injector)
        } catch let failure as QuickActionFailure {
            reportRefusal(failure)
            return
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        let state = QuickActionPanelState(
            action: action, original: selection, targetLanguage: targetLanguage)
        let previews = store.settings.previewsResult(action)
        if previews { present(state, target: target) }
        await perform(state, target: target, previewing: previews)
    }

    /// Reads only the facts the prompt names, so a prompt without `{selection}` never takes one.
    private func begin(
        _ command: CustomQuickAction, arguments: [String: String], target: NSRunningApplication?
    ) async {
        guard command.output != .quickAI || settings.aiEnabled else {
            return core.showMessage("Turn on AI in Settings to open Quick AI", tone: .danger)
        }
        let context: SnippetTemplateEngine.ExpansionContext
        do {
            if command.output == .replace || command.output == .paste {
                try requireTypingTarget(target)
            }
            context = try await AICommandContextReader.gather(
                AICommandTemplate.facts(for: command.instructions), target: target,
                injector: injector)
        } catch let failure as QuickActionFailure {
            reportRefusal(failure)
            return
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        guard !Task.isCancelled else { return }
        let rendered = AICommandTemplate.render(command, context: context, arguments: arguments)
        // Quick AI runs the chat's own route and tools, so creativity has nothing to set there.
        guard command.output != .quickAI else {
            return core.quickAICoordinator.ask(rendered.chatPrompt)
        }
        let state = QuickActionPanelState(
            action: .custom(command), original: context.selection, targetLanguage: targetLanguage,
            rendered: rendered, temperature: command.creativity.temperature)
        let previews = command.output == .panel
        if previews { present(state, target: target) }
        await perform(state, target: target, previewing: previews)
    }

    /// Checked before the model runs, so a reply is never written only to have nowhere to land.
    private func requireTypingTarget(_ target: NSRunningApplication?) throws {
        guard let target, !target.isTerminated,
            target.bundleIdentifier != Bundle.main.bundleIdentifier
        else { throw QuickActionFailure.noPasteTarget }
        guard Permissions.isAccessibilityTrusted() else { throw QuickActionFailure.needsAccessibility }
    }

    private func continueInChat(_ state: QuickActionPanelState, reply: String) {
        guard let rendered = state.rendered else { return }
        continueInChat(
            prompt: rendered.chatPrompt, reply: reply, model: store.model(for: state.action))
    }

    /// The exchange is saved first, so the window opens it like any chat from history.
    func continueInChat(prompt: String, reply: String, model: AIModelSelection?) {
        guard settings.aiEnabled else { return }
        let session = ChatSession(
            messages: [
                ChatMessage(role: .user, text: prompt),
                ChatMessage(role: .assistant, text: reply)
            ],
            model: model ?? core.aiSettings.defaultModel)
        core.chatHistory.save(session)
        guard core.chatHistory.conversation(id: session.id) != nil else {
            core.showMessage("The chat could not be saved", tone: .danger)
            return
        }
        core.aiChatCoordinator.openChat(id: session.id)
        core.aiChatCoordinator.showWindow()
    }

    /// A missing permission cannot be fixed from a pill that fades, so it earns a dialog instead.
    private func reportRefusal(_ failure: QuickActionFailure) {
        if failure.opensAutomationSettings {
            NSApp.activate(ignoringOtherApps: true)
            Task {
                guard
                    await core.reportFailure(
                        title: "AI Commands can't read your browser",
                        message: (failure.errorDescription ?? "")
                            + " Bestcast only asks for the front tab's address and title.",
                        symbol: "safari", recovery: "Open System Settings")
                else { return }
                Permissions.openAutomationSettings()
            }
            return
        }
        guard failure.opensAccessibilitySettings else {
            core.showMessage(failure.localizedDescription, tone: .danger)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.reportFailure(
                    title: "Quick Actions can't read your selection",
                    message:
                        "Bestcast needs the Accessibility permission to read the text you have "
                        + "selected and replace it. If Bestcast is already listed, switch it off "
                        + "and on again — a rebuilt app keeps a stale entry.",
                    symbol: "wand.and.sparkles", recovery: "Open System Settings")
            else { return }
            Permissions.openAccessibilitySettings()
        }
    }

    private func perform(
        _ state: QuickActionPanelState, target: NSRunningApplication?, previewing: Bool
    ) async {
        do {
            let text = try await produce(state, previewing: previewing)
            guard !Task.isCancelled else { return }
            state.finish(text)
            if previewing { return }
            guard state.action.customAction?.output != .copy else {
                Paster.copyPlainText(text)
                return core.showMessage("\(state.action.title) copied")
            }
            deliver(text, to: target, state: state)
        } catch is CancellationError {
            return
        } catch let error as TextTranslator.Failure where error.needsDownload {
            // A HUD cannot say where the download lives, so this has to become a panel.
            if !previewing { present(state, target: target) }
            state.requireLanguageDownload()
        } catch {
            report(error, state: state, previewing: previewing)
        }
    }

    /// Without a panel there is nothing on screen saying the model is working, so the pill says it.
    private func produce(
        _ state: QuickActionPanelState, previewing: Bool
    ) async throws -> String {
        guard !previewing else { return try await generate(state, streaming: true) }
        let mine = generation
        progressOwner = mine
        core.showProgress(state.action.progressTitle, onCancel: { [weak self] in self?.cancel() })
        defer { hideProgress(ownedBy: mine) }
        return try await generate(state, streaming: false)
    }

    private func hideProgress(ownedBy owner: Int?) {
        guard let owner, progressOwner == owner else { return }
        progressOwner = nil
        core.hideProgress()
    }

    private func generate(
        _ state: QuickActionPanelState, streaming: Bool
    ) async throws -> String {
        if state.action.usesTranslationFramework {
            return try await TextTranslator.translate(state.original, to: state.targetLanguage)
        }
        let provider = try core.quickActionProvider(for: state.action)
        let onDelta: @MainActor (String) -> Void = { delta in
            guard streaming else { return }
            state.append(delta)
        }
        if let rendered = state.rendered {
            return try await QuickActionRunner.run(
                rendered, temperature: state.temperature, using: provider, onDelta: onDelta)
        }
        return try await QuickActionRunner.run(
            state.action, selection: state.original, using: provider,
            instructionOverride: store.settings.instructionOverride(for: state.action),
            onDelta: onDelta)
    }

    /// A replacement that never lands would otherwise lose the reply, so the clipboard keeps it.
    private func deliver(
        _ text: String, to target: NSRunningApplication?, state: QuickActionPanelState
    ) {
        let action = state.action
        let missed = state.original.isEmpty ? "paste" : "replace the selection"
        injector.replaceSelection(
            with: text, in: target,
            onDelivered: { [weak self] in self?.core.showMessage("\(action.title) applied") },
            onFailed: { [weak self] in
                Paster.copyPlainText(text)
                self?.core.showMessage(
                    "\(action.title) couldn't \(missed) — copied instead", tone: .danger)
            })
    }

    /// A failure the reader cannot see is a hotkey that silently did nothing.
    private func report(_ error: Error, state: QuickActionPanelState, previewing: Bool) {
        guard previewing else {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        state.fail(error.localizedDescription)
    }

    private func present(_ state: QuickActionPanelState, target: NSRunningApplication?) {
        panels.present(
            state,
            metrics: settings.interfaceSize.metrics,
            languages: offeredLanguages,
            onRetranslate: { [weak self] language in
                state.targetLanguage = language
                self?.rerun(state, target: target)
            },
            onReplace: { [weak self] text in
                self?.deliver(text, to: target, state: state)
            },
            onContinue: state.rendered == nil || !settings.aiEnabled
                ? nil
                : { [weak self] text in self?.continueInChat(state, reply: text) })
    }

    private func rerun(_ state: QuickActionPanelState, target: NSRunningApplication?) {
        state.restart()
        start { [weak self] in await self?.perform(state, target: target, previewing: true) }
    }

    private var targetLanguage: Locale.Language {
        let stored = store.settings.targetLanguage
        guard !stored.isEmpty else { return Locale.current.language }
        return Locale.Language(identifier: stored)
    }

    /// Observed, not ignored: it arrives after the pane has painted, and the picker has to notice.
    private(set) var offeredLanguages: [Locale.Language] = []
    @ObservationIgnored private var languageLoad: Task<Void, Never>?

    func loadLanguages() {
        guard offeredLanguages.isEmpty, languageLoad == nil else { return }
        languageLoad = Task { [weak self] in
            let languages = await TextTranslator.supportedLanguages()
            self?.offeredLanguages = languages
        }
    }
}

extension TextTranslator.Failure {
    var needsDownload: Bool {
        if case .notInstalled = self { return true }
        return false
    }
}
