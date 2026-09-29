import AppKit
import Network

/// Listens only for what an enabled trigger needs, and runs fired triggers one at a time.
@MainActor
@Observable
final class ExtensionTriggerEngine {
    /// One enabled trigger of one installed extension.
    private struct Armed: Hashable, Sendable {
        let owner: InstalledExtension
        let trigger: ExtensionTrigger
    }

    private struct Pending {
        let armed: Armed
        let event: JSONValue
        /// The app a `replacesSelection` result is typed into, captured when the event fired.
        let targetApp: NSRunningApplication?
    }

    let store: ExtensionTriggerStore
    @ObservationIgnored let runner = ExtensionTriggerRunner()
    @ObservationIgnored weak var manager: ExtensionManager? {
        didSet { runner.manager = manager }
    }

    @ObservationIgnored private weak var clipboardStore: ClipboardStore?
    @ObservationIgnored private weak var hotKeys: HotKeyManager?
    @ObservationIgnored private weak var injector: TextInjector?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var armed: Set<Armed> = []
    @ObservationIgnored private var workspaceTokens: [NotificationToken] = []
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleTasks: [Armed: Task<Void, Never>] = [:]
    /// Bumped whenever the clipboard watch stops, so a stale observation never re-arms itself.
    @ObservationIgnored private var clipboardGeneration = 0
    @ObservationIgnored private var clipboardWatermark = Date.distantFuture
    @ObservationIgnored private var queue: [Pending] = []
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var drainID: UUID?
    @ObservationIgnored private var lastHUD: [String: Date] = [:]

    init(store: ExtensionTriggerStore) {
        self.store = store
        runner.engine = self
    }

    func start(clipboardStore: ClipboardStore, hotKeys: HotKeyManager, injector: TextInjector) {
        self.clipboardStore = clipboardStore
        self.hotKeys = hotKeys
        self.injector = injector
        isStarted = true
        sync()
    }

    /// `<extension>/trigger/<name>`: the hotkey's id, the deeplink's path, the Settings row's key.
    static func key(extension name: String, trigger: String) -> String {
        "\(name)/trigger/\(trigger)"
    }

    // MARK: - Arming

    private func sync() {
        let next = withObservationTracking {
            wanted()
        } onChange: { [weak self] in
            Task { @MainActor in self?.sync() }
        }
        apply(next)
    }

    private func wanted() -> Set<Armed> {
        guard isStarted, let manager, manager.isEnabled, !store.isPaused else { return [] }
        var wanted: Set<Armed> = []
        for owner in manager.installed {
            for trigger in owner.manifest.triggers
            where store.state(extension: owner.manifest.name, trigger: trigger.name).enabled {
                wanted.insert(Armed(owner: owner, trigger: trigger))
            }
        }
        return wanted
    }

    private func apply(_ next: Set<Armed>) {
        if next.isEmpty { cancelRuns() }
        guard next != armed else { return }
        armed = next
        let events = Set(next.map(\.trigger.event))

        if events.contains(.clipboardChanged) {
            if clipboardWatermark == .distantFuture {
                clipboardWatermark = Date()
                watchClipboard(generation: clipboardGeneration)
            }
        } else if clipboardWatermark != .distantFuture {
            clipboardGeneration += 1
            clipboardWatermark = .distantFuture
        }

        let workspaceEvents: Set<ExtensionTriggerEvent> = [
            .appActivated, .appDeactivated, .systemWake, .systemSleep
        ]
        if events.isDisjoint(with: workspaceEvents) {
            workspaceTokens = []
        } else if workspaceTokens.isEmpty {
            observeWorkspace()
        }

        if !events.contains(.networkChanged) {
            networkTask?.cancel()
            networkTask = nil
        } else if networkTask == nil {
            watchNetwork()
        }

        for (item, task) in scheduleTasks where !next.contains(item) {
            task.cancel()
            scheduleTasks[item] = nil
        }
        for item in next where item.trigger.event == .schedule && scheduleTasks[item] == nil {
            scheduleTasks[item] = schedule(item)
        }
    }

    /// The global switch going off: every source stops and nothing queued runs.
    func stopAll() {
        clipboardGeneration += 1
        clipboardWatermark = .distantFuture
        workspaceTokens = []
        networkTask?.cancel()
        networkTask = nil
        for task in scheduleTasks.values { task.cancel() }
        scheduleTasks = [:]
        armed = []
        cancelRuns()
    }

    private func cancelRuns() {
        queue = []
        drainTask?.cancel()
        drainTask = nil
        drainID = nil
    }

    /// Uninstall: its consent, the grants it held or gave, and its selection shortcuts.
    func forget(_ owner: InstalledExtension) {
        let name = owner.manifest.name
        store.forget(extension: name)
        store.flush()
        let prefix = Self.key(extension: name, trigger: "")
        lastHUD = lastHUD.filter { !$0.key.hasPrefix(prefix) }
        guard let hotKeys else { return }
        for id in hotKeys.boundExtensionTriggerIDs where id.hasPrefix(prefix) {
            let action = HotKeyAction.extensionTrigger(id: id)
            if hotKeys.recordingAction == action { hotKeys.recordingAction = nil }
            hotKeys.setBinding(nil, for: action)
        }
    }

    // MARK: - Sources

    private func watchClipboard(generation: Int) {
        guard generation == clipboardGeneration, let clipboardStore else { return }
        let items = withObservationTracking {
            clipboardStore.items
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchClipboard(generation: generation) }
        }
        guard let newest = items.max(by: { $0.createdAt < $1.createdAt }),
            newest.createdAt > clipboardWatermark
        else { return }
        clipboardWatermark = newest.createdAt
        let kind = newest.kind.rawValue
        let text = newest.kind == .image ? nil : newest.text
        for item in armed where item.trigger.event == .clipboardChanged {
            guard ExtensionTriggerPolicy.matches(item.trigger.filter, kind: kind, text: text) else {
                continue
            }
            let shares = store.state(
                extension: item.owner.manifest.name, trigger: item.trigger.name
            ).sharesClipboardText
            enqueue(
                item,
                payload: ExtensionTriggerPolicy.clipboardPayload(
                    kind: kind, text: text, sharesText: shares))
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let ownBundle = Bundle.main.bundleIdentifier
        func observe(
            _ name: Notification.Name, _ event: ExtensionTriggerEvent, readsApp: Bool
        ) -> NotificationToken {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                let bundleId = app?.bundleIdentifier
                let appName = app?.localizedName
                guard !readsApp || (bundleId != nil && bundleId != ownBundle) else { return }
                MainActor.assumeIsolated {
                    self?.workspaceEvent(event, bundleId: bundleId, name: appName)
                }
            }
            return NotificationToken(token, center: center)
        }
        workspaceTokens = [
            observe(NSWorkspace.didActivateApplicationNotification, .appActivated, readsApp: true),
            observe(NSWorkspace.didDeactivateApplicationNotification, .appDeactivated, readsApp: true),
            observe(NSWorkspace.didWakeNotification, .systemWake, readsApp: false),
            observe(NSWorkspace.willSleepNotification, .systemSleep, readsApp: false)
        ]
    }

    private func workspaceEvent(_ event: ExtensionTriggerEvent, bundleId: String?, name: String?) {
        var payload: [String: JSONValue] = [:]
        if let bundleId {
            payload = ["bundleId": .string(bundleId), "name": .string(name ?? bundleId)]
        }
        for item in armed where item.trigger.event == event {
            guard bundleId == nil
                || ExtensionTriggerPolicy.matches(bundleIds: item.trigger.bundleIds, bundleId: bundleId)
            else { continue }
            enqueue(item, payload: payload)
        }
    }

    /// Reachability only: no interface, address or network name ever reaches an extension.
    private func watchNetwork() {
        networkTask = Task { [weak self] in
            var reachable: Bool?
            for await path in NWPathMonitor() {
                let now = path.status == .satisfied
                defer { reachable = now }
                guard let was = reachable, was != now else { continue }
                self?.fire(.networkChanged, payload: ["reachable": .bool(now)])
            }
        }
    }

    /// Sleeps in short steps, so a changed clock or a wake is noticed well before a far fire time.
    private func schedule(_ item: Armed) -> Task<Void, Never>? {
        guard let schedule = item.trigger.schedule else { return nil }
        return Task { [weak self] in
            var after = Date()
            while !Task.isCancelled, let next = schedule.nextFire(after: after, calendar: .current) {
                while !Task.isCancelled, next.timeIntervalSinceNow > 0 {
                    try? await Task.sleep(for: .seconds(min(next.timeIntervalSinceNow, 900)))
                }
                guard !Task.isCancelled else { return }
                self?.enqueue(item, payload: ["scheduledAt": .string(next.ISO8601Format())])
                after = max(next, Date())
            }
        }
    }

    private func fire(_ event: ExtensionTriggerEvent, payload: [String: JSONValue]) {
        for item in armed where item.trigger.event == event { enqueue(item, payload: payload) }
    }

    /// The `selection.hotkey` chord: reads the selection, as Quick Actions do, then fires.
    func fireHotKey(id: String) {
        guard let item = armed.first(where: {
            $0.trigger.event == .selectionHotkey
                && Self.key(extension: $0.owner.manifest.name, trigger: $0.trigger.name) == id
        }) else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        guard Permissions.ensureAccessibility() else { return }
        Task {
            var selection = AccessibilityText.selection(in: app)
            if selection == nil { selection = await injector?.copySelection(from: app) }
            guard let selection, !selection.isEmpty else {
                showHUD("Nothing is selected", for: id)
                return
            }
            enqueue(item, payload: ["selection": .string(selection)], targetApp: app)
        }
    }

    /// `bestcast://extensions/<extension>/trigger/<name>?…`: a person clicked it, so errors show.
    func runDeepLink(_ link: ExtensionDeepLink) {
        guard let name = link.triggerName, let manager else { return }
        let candidates = manager.installed.filter { link.matches(manifestName: $0.manifest.name) }
        guard let item = armed.first(where: { item in
            item.trigger.event == .deeplink && item.trigger.name == name
                && candidates.contains(item.owner)
        }) else {
            manager.coordinator?.showHUD("No automation named '\(name)' is turned on")
            return
        }
        enqueue(item, payload: ["query": .object(link.query.mapValues(JSONValue.string))])
    }

    // MARK: - Running

    private func enqueue(
        _ item: Armed, payload: [String: JSONValue],
        targetApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) {
        let name = item.owner.manifest.name
        let now = Date()
        let verdict = ExtensionTriggerPolicy.verdict(
            trigger: item.trigger, state: store.state(extension: name, trigger: item.trigger.name),
            isPaused: store.isPaused, now: now)
        guard verdict == .fire else { return }
        store.update(extension: name, trigger: item.trigger.name) { $0.lastFired = now }
        let event = ExtensionTriggerPolicy.event(
            trigger: item.trigger.name, type: item.trigger.event, payload: payload)
        let app = targetApp?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : targetApp
        queue = ExtensionTriggerPolicy.enqueue(
            Pending(armed: item, event: event, targetApp: app), into: queue)
        drain()
    }

    private func drain() {
        guard drainTask == nil else { return }
        let id = UUID()
        drainID = id
        drainTask = Task { [weak self] in
            while !Task.isCancelled, let self, !self.queue.isEmpty {
                await self.run(self.queue.removeFirst())
            }
            guard let self, self.drainID == id else { return }
            self.drainTask = nil
            self.drainID = nil
        }
    }

    private func run(_ pending: Pending) async {
        let owner = pending.armed.owner
        let trigger = pending.armed.trigger
        let name = owner.manifest.name
        guard armed.contains(pending.armed) else { return }
        let key = Self.key(extension: name, trigger: trigger.name)
        let scope = ExtensionRunScope(
            canPrompt: false, feedback: { [weak self] text in self?.showHUD(text, for: key) })
        let result = await ExtensionTriggerPolicy.runChain(
            event: pending.event, target: trigger.target, then: trigger.then
        ) { target, input in
            switch target {
            case .export(let path):
                return await runner.runExport(path, of: owner, input: input, scope: scope)
            case .command(let command):
                guard let command = owner.command(named: command) else {
                    return .failure(ExtensionTriggerFailure("\(owner.title) has no command '\(command)'."))
                }
                return await runner.runCommand(command, of: owner, props: input, scope: scope)
            }
        }
        // Pausing or switching off cancels the run; that is not the trigger failing.
        guard !Task.isCancelled else { return }
        var didAutoDisable = false
        store.update(extension: name, trigger: trigger.name) { state in
            var message: String?
            if case .failure(let failure) = result { message = failure.message }
            let recorded = ExtensionTriggerPolicy.recording(error: message, in: state, now: Date())
            state = recorded.state
            didAutoDisable = recorded.didAutoDisable
        }
        if didAutoDisable {
            manager?.coordinator?.showHUD(
                "\(trigger.title) was turned off after \(ExtensionTriggerPolicy.failureLimit) failures")
        }
        guard trigger.replacesSelection, case .success(.string(let text)) = result,
            let app = pending.targetApp,
            store.state(extension: name, trigger: trigger.name).allowsTyping
        else { return }
        injector?.replaceSelection(with: text, in: app)
    }

    private func showHUD(_ text: String, for key: String) {
        let now = Date()
        guard ExtensionTriggerPolicy.allowsHUD(lastShown: lastHUD[key], now: now) else { return }
        lastHUD[key] = now
        manager?.coordinator?.showHUD(text)
    }

    // MARK: - Composition

    func callExport(
        _ name: String, of target: String, input: JSONValue, caller: String, scope: ExtensionRunScope
    ) async -> Result<JSONValue, ExtensionTriggerFailure> {
        guard let manager, manager.isEnabled else {
            return .failure(ExtensionTriggerFailure("Extensions are turned off."))
        }
        guard !store.isPaused else {
            return .failure(ExtensionTriggerFailure("Automations are paused in Settings."))
        }
        guard let owner = manager.extensionNamed(target) else {
            return .failure(ExtensionTriggerFailure("\(target) is not installed."))
        }
        guard let export = owner.manifest.exports.first(where: { $0.name == name }) else {
            return .failure(ExtensionTriggerFailure("\(owner.title) has no export named '\(name)'."))
        }
        if target != caller {
            guard export.isPublic else {
                return .failure(ExtensionTriggerFailure("\(owner.title)’s \(name) is not public."))
            }
            if !store.isApproved(caller: caller, extension: target, export: name) {
                let callerTitle = manager.extensionNamed(caller)?.title ?? caller
                guard scope.canPrompt, let coordinator = manager.coordinator else {
                    return .failure(ExtensionTriggerFailure(
                        "\(callerTitle) needs approval to use \(owner.title)’s \(name) first."))
                }
                guard await coordinator.confirmCompose(
                    caller: callerTitle, target: owner.title, export: name,
                    description: export.description)
                else { return .failure(ExtensionTriggerFailure("Not allowed.")) }
                store.approve(caller: caller, extension: target, export: name)
            }
        }
        let key = ExtensionTriggerPolicy.callKey(extension: target, export: name)
        if let refusal = Self.refusal(chain: scope.chain, next: key) { return .failure(refusal) }
        var inner = scope
        inner.chain.append(key)
        return await runner.runExport(export.path, of: owner, input: input, scope: inner)
    }

    /// The caller's own exports, and every other extension's public ones.
    func listExports(caller: String) -> [(extension: String, export: ExtensionExport)] {
        (manager?.installed ?? []).flatMap { owner in
            owner.manifest.exports
                .filter { owner.manifest.name == caller || $0.isPublic }
                .map { (extension: owner.manifest.name, export: $0) }
        }
    }

    static func refusal(chain: [String], next: String) -> ExtensionTriggerFailure? {
        switch ExtensionTriggerPolicy.composeVerdict(chain: chain, next: next) {
        case .allowed: return nil
        case .cycle: return ExtensionTriggerFailure("\(next) was called again while still running.")
        case .tooDeep:
            return ExtensionTriggerFailure(
                "Calls nested more than \(ExtensionTriggerPolicy.composeDepthLimit) deep.")
        }
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool, trigger: String, of owner: String) {
        store.update(extension: owner, trigger: trigger) { state in
            if enabled {
                state = ExtensionTriggerPolicy.enabling(state)
            } else {
                state.enabled = false
            }
        }
    }

    func displayName(hotKeyID id: String) -> String? {
        for owner in manager?.installed ?? [] {
            for trigger in owner.manifest.triggers
            where Self.key(extension: owner.manifest.name, trigger: trigger.name) == id {
                return "\(owner.title): \(trigger.title)"
            }
        }
        return nil
    }
}
