import AppKit

/// One provider's rows for the query they answer; the launcher shows them only while it stands.
struct ExtensionSearchSection: Identifiable, Equatable {
    let extensionName: String
    let providerName: String
    let title: String
    let query: String
    let items: [ExtensionSearchItem]
    /// The provider's place among every provider, so a late answer still lands in its slot.
    let order: Int

    var id: String { extensionName + "/" + providerName }
}

/// What extensions add outside their own commands: root-search rows, fallbacks, ⌘K, placeholders.
@MainActor
@Observable
final class ExtensionSearchCoordinator {
    static let placeholderTimeout: Duration = .seconds(3)
    static let maxPlaceholderLength = 20_000
    static let maxMessageLength = 120

    private(set) var sections: [ExtensionSearchSection] = []

    @ObservationIgnored private var scheduler = ExtensionSearchScheduler()
    @ObservationIgnored private var searchTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var parsed:
        [String: (owner: InstalledExtension, value: ExtensionContributions)] = [:]
    @ObservationIgnored private unowned let core: AppCore

    init(core: AppCore) {
        self.core = core
    }

    private var manager: ExtensionManager { core.extensions }
    private var store: ExtensionContributionStore { manager.contributionStore }

    /// Parsed once per install: search reads this on every keystroke.
    func contributions(of owner: InstalledExtension) -> ExtensionContributions {
        if let cached = parsed[owner.manifest.name], cached.owner == owner { return cached.value }
        let value = ExtensionContributions(manifest: owner.manifest)
        parsed[owner.manifest.name] = (owner, value)
        return value
    }

    func isEnabled(_ extensionName: String, _ kind: ExtensionContributionKind, _ name: String) -> Bool {
        store.enabled(extensionName, kind, name)
    }

    func setEnabled(
        _ enabled: Bool, _ extensionName: String, _ kind: ExtensionContributionKind, _ name: String
    ) {
        store.set(enabled, extensionName, kind, name)
        if !enabled { manager.contributions.stop(extension: extensionName) }
        if kind == .search { reset() }
    }

    // MARK: - Root search

    /// The sections still answering `query`; an older query's rows never show under a new one.
    func sections(for query: String) -> [ExtensionSearchSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sections.filter { $0.query == trimmed }
    }

    /// Re-run on every query, mode and visibility change, like passive AI's answer.
    func paletteChanged() {
        let palette = core.palette
        guard palette.isVisible, palette.mode == .launcher, palette.argumentEntryID == nil else {
            return reset()
        }
        let previous = scheduler.generation
        let generation = scheduler.noteQuery(palette.query, now: .now)
        guard generation != previous else { return }
        cancelSearches()
        if !sections.isEmpty { sections = [] }
        let providers = activeProviders
        guard !providers.isEmpty, !scheduler.query.isEmpty else { return }
        searchTasks = [
            Task { [weak self] in
                // The sleep's clock and the wall clock drift by microseconds; the margin absorbs it.
                do {
                    try await Task.sleep(for: ExtensionSearchScheduler.debounce + .milliseconds(5))
                } catch {
                    return
                }
                self?.search(providers, generation: generation)
            }
        ]
    }

    func reset() {
        scheduler.reset()
        cancelSearches()
        if !sections.isEmpty { sections = [] }
    }

    private var activeProviders: [(owner: InstalledExtension, provider: ExtensionSearchProvider)] {
        manager.installed.flatMap { owner in
            contributions(of: owner).search
                .filter { isEnabled(owner.manifest.name, .search, $0.name) }
                .map { (owner, $0) }
        }
    }

    private func cancelSearches() {
        searchTasks.forEach { $0.cancel() }
        searchTasks = []
    }

    private func search(
        _ providers: [(owner: InstalledExtension, provider: ExtensionSearchProvider)], generation: Int
    ) {
        guard scheduler.accept(generation: generation) else { return }
        let query = scheduler.query
        let now = Date.now
        for (order, (owner, provider)) in providers.enumerated() {
            guard scheduler.shouldQuery(query: core.palette.query, provider: provider, now: now),
                let input = ExtensionSearchScheduler.input(for: query, provider: provider)
            else { continue }
            searchTasks.append(
                Task { [weak self] in
                    guard let self else { return }
                    let value = try? await self.manager.contributions.runExport(
                        provider.export, of: owner, input: .object(["query": .string(input)]),
                        timeout: ExtensionSearchScheduler.timeout, keepWarm: true,
                        launchType: .background)
                    guard !Task.isCancelled, self.scheduler.accept(generation: generation),
                        self.isEnabled(owner.manifest.name, .search, provider.name), let value
                    else { return }
                    let items = ExtensionSearchOutput.items(
                        from: value, mode: provider.mode, limit: provider.maxResults)
                    guard !items.isEmpty else { return }
                    self.publish(
                        ExtensionSearchSection(
                            extensionName: owner.manifest.name, providerName: provider.name,
                            title: provider.title, query: query, items: items, order: order))
                })
        }
    }

    /// Rows landing above the highlight push it down, so ↵ still opens what it did a moment ago.
    private func publish(_ section: ExtensionSearchSection) {
        var next = sections.filter { $0.id != section.id }
        let index = next.firstIndex { $0.order > section.order } ?? next.count
        let start = passiveRowCount(for: section.query) + next[..<index].reduce(0) { $0 + $1.items.count }
        next.insert(section, at: index)
        sections = next
        guard core.palette.mode == .launcher, core.palette.selection >= start else { return }
        core.palette.selection += section.items.count
    }

    /// Passive AI's answer leads the same section, so it counts toward where these rows start.
    private func passiveRowCount(for query: String) -> Int {
        core.passiveAICoordinator.answer?.query == query ? 1 : 0
    }

    // MARK: - Performing a row's action

    func perform(_ action: ExtensionContributionAction, extensionName: String) {
        let palette = core.paletteCoordinator
        switch action {
        case .copy(let text, _):
            palette.hidePalette(restoreFocus: false)
            Paster.copyPlainText(text)
            core.showMessage("Copied to Clipboard")
        case .paste(let text, _):
            let target = palette.targetApp
            palette.hidePalette(restoreFocus: false)
            Paster.pasteString(text, previousApp: target)
        case .open(let target, _):
            let url = target.hasPrefix("/") ? URL(fileURLWithPath: target) : URL(string: target)
            guard let url else { return }
            palette.hidePalette(restoreFocus: false)
            NSWorkspace.shared.open(url)
        case .launch(let command, let arguments, _):
            guard let entry = commandEntry(extensionName: extensionName, command: command) else {
                return core.showMessage("That command isn't available", tone: .danger)
            }
            core.extensionCoordinator.runExtensionCommand(entry, arguments: arguments)
        }
    }

    /// ⌘K on a contributed row: every action it carries, the first being ↵.
    func menu(for item: ExtensionSearchItem, extensionName: String) -> PopoverMenuContent {
        PopoverMenuContent(
            header: item.title,
            items: item.actions.enumerated().map { index, action in
                PopoverMenuItem(
                    title: action.title, systemImage: action.systemImage,
                    shortcut: index == 0 ? "↵" : nil
                ) { [weak self] in
                    self?.perform(action, extensionName: extensionName)
                }
            })
    }

    /// Nil for a command that is gone, or one the reader disabled.
    private func commandEntry(extensionName: String, command: String) -> AppEntry? {
        let reference = ExtensionCommandRef(extensionName: extensionName, commandName: command)
        guard !core.visibility.disabledItemKeys.contains(reference.entryID) else { return nil }
        return manager.launcherEntry(forEntryID: reference.entryID)
    }

    // MARK: - Fallbacks

    var fallbacks: [Fallback] {
        manager.installed.flatMap { owner in
            contributions(of: owner).fallbacks
                .filter { isEnabled(owner.manifest.name, .fallback, $0.command) }
                .map {
                    Fallback.extensionCommand(
                        extensionName: owner.manifest.name, commandName: $0.command)
                }
        }
    }

    func fallbackEntry(for fallback: Fallback) -> AppEntry? {
        guard case .extensionCommand(let extensionName, let commandName) = fallback,
            isEnabled(extensionName, .fallback, commandName)
        else { return nil }
        return commandEntry(extensionName: extensionName, command: commandName)
    }

    /// The query arrives as the command's `fallbackText`, as Raycast hands it.
    func runFallback(_ fallback: Fallback, query: String) {
        guard let entry = fallbackEntry(for: fallback) else { return }
        core.extensionCoordinator.runExtensionCommand(entry, fallbackText: query)
    }

    // MARK: - ⌘K on other rows

    /// Mapped from the row's kind alone; a kind no contribution can target gets no group.
    func rowActions(for entry: AppEntry) -> [PopoverMenuItem] {
        guard let target = Self.target(for: entry.kind) else { return [] }
        var items: [PopoverMenuItem] = []
        for owner in manager.installed {
            let actions = contributions(of: owner).actions.filter {
                $0.targets.contains(target) && isEnabled(owner.manifest.name, .action, $0.name)
            }
            for (index, action) in actions.enumerated() {
                items.append(
                    PopoverMenuItem(
                        title: action.title, icon: .symbol(action.icon ?? "puzzlepiece.extension"),
                        sectionTitle: index == 0 ? owner.title : nil, startsSection: index == 0
                    ) { [weak self] in
                        self?.runRowAction(action, of: owner, on: entry, target: target)
                    })
            }
        }
        return items
    }

    private static func target(for kind: AppEntry.Kind) -> ExtensionActionTarget? {
        switch kind {
        case .application: return .app
        case .snippet: return .snippet
        case .quicklink: return .quicklink
        default: return nil
        }
    }

    private func runRowAction(
        _ action: ExtensionActionContribution, of owner: InstalledExtension, on entry: AppEntry,
        target: ExtensionActionTarget
    ) {
        let item = rowPayload(for: entry, target: target)
        switch action.run {
        case .command(let command):
            guard let commandEntry = commandEntry(extensionName: owner.manifest.name, command: command)
            else { return core.showMessage("That command isn't available", tone: .danger) }
            let text = item["path"] ?? item["text"] ?? item["name"]
            core.extensionCoordinator.runExtensionCommand(
                commandEntry, fallbackText: text,
                launchContext: [
                    "kind": .string(target.rawValue), "item": .object(item.mapValues(RenderValue.string))
                ])
        case .export(let export):
            core.paletteCoordinator.hidePalette(restoreFocus: false)
            let input = JSONValue.object([
                "kind": .string(target.rawValue), "item": .object(item.mapValues(JSONValue.string))
            ])
            Task {
                do {
                    let value = try await manager.contributions.runExport(export, of: owner, input: input)
                    let message = ExtensionContributions.line(
                        value.stringValue ?? "", limit: Self.maxMessageLength)
                    if !message.isEmpty { core.showMessage(message) }
                } catch {
                    let reason = ExtensionContributions.line(
                        error.localizedDescription, limit: Self.maxMessageLength)
                    core.showMessage("\(action.title): \(reason)", tone: .danger)
                }
            }
        }
    }

    /// Only what the row already shows, plus a quicklink's own link; never a snippet's body.
    private func rowPayload(for entry: AppEntry, target: ExtensionActionTarget) -> [String: String] {
        var item = ["name": entry.name, "id": entry.id]
        switch target {
        case .app:
            item["path"] = entry.url.path
            item["bundleId"] = entry.bundleID
        case .quicklink:
            item["text"] = Quicklink.id(fromEntryID: entry.id).flatMap(core.quicklinks.quicklink)?.link
        case .snippet, .file, .clipboardText, .clipboardImage:
            break
        }
        return item
    }

    // MARK: - Snippet placeholders

    /// `{ext:<extension>/<name>}`; nil when nothing may answer, which the snippet expands empty.
    func placeholder(_ placeholder: SnippetTemplateEngine.ExternalPlaceholder) async -> String? {
        guard placeholder.namespace == "ext", let slash = placeholder.name.lastIndex(of: "/") else {
            return nil
        }
        let extensionName = String(placeholder.name[..<slash])
        let name = String(placeholder.name[placeholder.name.index(after: slash)...])
        guard let owner = manager.extensionNamed(extensionName),
            let contribution = contributions(of: owner).placeholder(named: name),
            isEnabled(extensionName, .placeholder, name)
        else { return nil }
        var arguments: [String: JSONValue] = [:]
        for argument in contribution.arguments {
            if let value = placeholder.arguments[argument] { arguments[argument] = .string(value) }
        }
        guard
            let value = try? await manager.contributions.runExport(
                contribution.export, of: owner, input: .object(["arguments": .object(arguments)]),
                timeout: Self.placeholderTimeout, launchType: .background),
            let text = value.stringValue
        else { return nil }
        return String(text.prefix(Self.maxPlaceholderLength))
    }

    /// Each opted-in placeholder as the token the snippet editor's Insert… menu offers.
    var placeholderTokens: [String] {
        manager.installed.flatMap { owner in
            contributions(of: owner).placeholders
                .filter { isEnabled(owner.manifest.name, .placeholder, $0.name) }
                .map { placeholder in
                    let arguments = placeholder.arguments.map { " \($0)=\"\"" }.joined()
                    return "{ext:\(owner.manifest.name)/\(placeholder.name)\(arguments)}"
                }
        }
    }

    // MARK: - Consent

    /// After an install: every contribution starts off, and this is where the reader opts in.
    func offerContributions(forExtensionNamed name: String) {
        guard let owner = manager.extensionNamed(name) else { return }
        let items = contributions(of: owner).items
        guard !items.isEmpty else { return }
        let state = ExtensionContributionConsentState(
            extensionName: name, items: items, isEnabled: { isEnabled(name, $0, $1) })
        Task {
            guard await core.confirmContributions(title: owner.title, state: state) else { return }
            for item in state.items {
                setEnabled(state.isOn(item), name, item.kind, item.name)
            }
        }
    }
}
