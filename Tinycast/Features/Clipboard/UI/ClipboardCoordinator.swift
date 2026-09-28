import AppKit

/// Owns clipboard-history actions: paste, copy, reveal, pin — and the selection that follows.
@MainActor
@Observable
final class ClipboardCoordinator {
    private let clipboardStore: ClipboardStore
    private let clipboardManager: ClipboardManager
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let palette: PaletteState
    private let windowController: PaletteWindowController
    private let paletteCoordinator: PaletteCoordinator
    /// Dialogs, for the one action here that can't be undone.
    private unowned let core: AppCore
    /// One Copy Text at a time: a newer trigger cancels the helper an older one is waiting on.
    @ObservationIgnored private var textTask: Task<Void, Never>?
    /// In memory only: a run outlives the palette hiding between presses, never a relaunch.
    private(set) var pasteQueue = PasteQueue()
    @ObservationIgnored private var pastePacer = PasteQueue.Pacer()
    @ObservationIgnored private var historyWalk = PasteQueue.HistoryWalk()

    init(
        clipboardStore: ClipboardStore,
        clipboardManager: ClipboardManager,
        settings: AppSettings,
        appIndex: AppIndex,
        palette: PaletteState,
        windowController: PaletteWindowController,
        paletteCoordinator: PaletteCoordinator,
        core: AppCore
    ) {
        self.clipboardStore = clipboardStore
        self.clipboardManager = clipboardManager
        self.settings = settings
        self.appIndex = appIndex
        self.palette = palette
        self.windowController = windowController
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Off means the poller stops, the database closes and nothing new is ever recorded.
    func applyEnabled() {
        appIndex.setCommandsVisible([.clipboardHistory, .pasteNextQueuedClip], settings.clipboardEnabled)
        guard settings.clipboardEnabled else {
            pasteQueue = PasteQueue()
            core.applyClipboardTextSearch()
            clipboardManager.stop()
            if palette.mode == .clipboard { palette.prepare(mode: .launcher) }
            clipboardStore.close()
            return
        }
        clipboardStore.open()
        clipboardStore.maxAge = settings.clipboardRetention.maxAge
        clipboardManager.start()
        core.applyClipboardTextSearch()
        // Deferred off the launch path: the palette fills in behind the SQLite read and prune.
        Task { clipboardStore.load() }
    }

    func followSearchResults(query: String, previous: [ClipboardItem], current: [ClipboardItem]) {
        guard palette.isVisible, palette.mode == .clipboard,
            palette.query.trimmingCharacters(in: .whitespaces) == query,
            previous.indices.contains(palette.selection)
        else { return }
        let selectedID = previous[palette.selection].id
        if let index = current.firstIndex(where: { $0.id == selectedID }) {
            palette.selection = index
        }
    }

    /// The setting names an age, the store enforces it; a shortened window culls straight away.
    func applyRetention(_ retention: ClipboardRetention) {
        clipboardStore.maxAge = retention.maxAge
        clipboardStore.enforceLimits()
    }

    /// ↵ runs the configured default and the other chords follow it; false when `chord` has none.
    @discardableResult
    func activate(_ item: ClipboardItem, chord: ClipboardChord = .return) -> Bool {
        guard let action = settings.clipboardDefaultAction.action(for: chord, on: item) else {
            return false
        }
        perform(action, on: item)
        return true
    }

    func perform(_ action: ClipboardDefaultAction, on item: ClipboardItem) {
        switch action {
        case .paste: paste(item)
        case .copy: copyToClipboard(item)
        case .pastePlainText: pasteAsPlainText(item)
        }
    }

    func paste(_ item: ClipboardItem) {
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        // A paste promotes the item, so follow it and keep the moved row highlighted.
        if Paster.paste(item, store: clipboardStore, previousApp: previous) {
            selectClip(item)
        } else {
            reportUnavailable(item)
        }
    }

    /// A file's path stays valid text after the file goes, so this never reports it missing.
    func pasteAsPlainText(_ item: ClipboardItem) {
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        if Paster.pastePlainText(item, store: clipboardStore, previousApp: previous) {
            selectClip(item)
        }
    }

    func pasteKeepingWindowOpen(_ item: ClipboardItem) {
        if !windowController.pasteKeepingWindowOpen(item, store: clipboardStore) {
            reportUnavailable(item)
        }
    }

    /// ⇧⌘A and its menu row: marks the entry at the end of the run, or takes it back out.
    func toggleQueued(_ item: ClipboardItem) {
        pasteQueue.toggle(item.id)
    }

    func clearPasteQueue() {
        pasteQueue = PasteQueue()
    }

    /// ⌃X and its menu row; a queued entry leaves the run too, so no badge counts a gap.
    func deleteClip(_ item: ClipboardItem) {
        clipboardStore.remove(item)
        pasteQueue.dropDeleted { clipboardStore.item(withID: $0) }
    }

    /// The global chord, the launcher row and the ⌘K row alike: the next entry, pasted.
    func pasteNextQueued() {
        // The chord registers whatever the feature switch says, so the switch is read here.
        guard settings.clipboardEnabled else { return }
        if pastePacer.press() == .paste { pasteNextTurn() }
    }

    /// One press's paste; a press that arrived meanwhile follows once this one has landed.
    private func pasteNextTurn() {
        Task {
            await pasteNextStep()
            if pastePacer.finish() { pasteNextTurn() }
        }
    }

    private func pasteNextStep() async {
        guard settings.clipboardEnabled else { return }
        let target = paletteCoordinator.targetApp
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        guard let step = nextPasteStep() else {
            let empty = clipboardStore.items.isEmpty
            return core.showMessage(
                empty ? "Clipboard history is empty" : "No older clips · next press starts over",
                tone: .neutral)
        }
        if await Paster.pasteQueued(step.item, store: clipboardStore, previousApp: target) {
            core.showMessage(step.message)
        } else {
            core.showMessage("\(step.message) · Entry no longer available", tone: .danger)
        }
    }

    /// A marked run takes precedence; with nothing marked, Paste Next walks the history.
    private func nextPasteStep() -> (item: ClipboardItem, message: String)? {
        if pasteQueue.hasPending,
            let step = pasteQueue.advance(resolve: { clipboardStore.item(withID: $0) })
        {
            return (step.item, step.message)
        }
        guard let step = historyWalk.advance(history: clipboardStore.items) else { return nil }
        return (step.item, step.message)
    }

    /// Every pending entry's text in one paste, a line each; images have none and are left out.
    func pasteAllQueued() {
        let target = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        guard let text = pasteQueue.joinedText(resolve: { clipboardStore.item(withID: $0) }) else {
            return core.showMessage("Nothing queued has text to paste", tone: .neutral)
        }
        pasteQueue = PasteQueue()
        Paster.pasteString(text, previousApp: target)
    }

    /// A write only fails on a vanished file, and a palette that just closes explains nothing.
    private func reportUnavailable(_ item: ClipboardItem) {
        guard item.kind == .file else { return }
        core.showMessage("That file has moved or been deleted.", tone: .danger)
    }

    /// The ⌃⇧X chord, the menu row and Settings all land here, so none can skip the confirmation.
    func deleteAllClips() async {
        guard
            await core.confirm(
                title: "Delete All Entries",
                message: "Are you sure you want to proceed with deleting all clipboard history entries?",
                symbol: PaletteMode.clipboard.systemImage, confirmTitle: "Delete All")
        else { return }
        clearHistory()
    }

    /// Reachable with the feature off, so what was kept before can still be erased afterwards.
    private func clearHistory() {
        clipboardStore.open()
        clipboardStore.clearAll()
        pasteQueue.dropDeleted { clipboardStore.item(withID: $0) }
        if !settings.clipboardEnabled { clipboardStore.close() }
    }

    func copyToClipboard(_ item: ClipboardItem) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        if Paster.copy(item, store: clipboardStore) {
            selectClip(item)
        } else {
            reportUnavailable(item)
        }
    }

    /// Unmarked, so a converted colour enters history itself — it is one you meant to keep.
    func copyColor(_ color: ColorValue, as format: ColorFormat) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(format.string(for: color))
    }

    func revealClip(_ item: ClipboardItem) {
        guard let url = clipURL(for: item) else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(url)
    }

    /// Nil only for a vanished file, which the HUD reports rather than hand over a dead path.
    func dragPayload(for item: ClipboardItem) -> ClipDragPayload? {
        let payload = item.dragPayload
        guard case .file = payload else { return payload }
        return clipURL(for: item).map(ClipDragPayload.file)
    }

    func openClip(_ item: ClipboardItem) {
        guard let url = clipURL(for: item) else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.open(url)
    }

    /// Unmarked, so the path enters history like any other copy the reader meant to make.
    func copyClipPath(_ item: ClipboardItem) {
        guard let path = item.filePath else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(path)
        core.showMessage("Copied path")
    }

    /// ⇧⌘T / “Copy Text” — OCRs the image in the bundled helper and copies what it reads.
    func copyImageText(_ item: ClipboardItem) {
        guard let path = item.imagePath ?? item.filePath else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.showProgress("Reading text…")
        let changeCount = NSPasteboard.general.changeCount
        textTask?.cancel()
        textTask = Task {
            do {
                // A stat on an unmounted or network volume can stall, so it stays off the main actor.
                let exists = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
                try Task.checkCancellation()
                guard exists else {
                    return item.kind == .file
                        ? reportUnavailable(item)
                        : core.showMessage("That image is no longer available.", tone: .danger)
                }
                let text = try await ClipboardTextWorker.extract(item)
                guard !text.isEmpty else { return core.showMessage("No text found", tone: .neutral) }
                guard NSPasteboard.general.changeCount == changeCount else {
                    return core.showMessage("Clipboard changed, text not copied", tone: .neutral)
                }
                Paster.copyPlainText(text)
                core.showMessage("Copied text")
            } catch is CancellationError {
            } catch {
                core.showMessage("Couldn’t read the text", tone: .danger)
            }
        }
    }

    /// Nil once the file is gone, so every action reports rather than silently no-opping.
    private func clipURL(for item: ClipboardItem) -> URL? {
        let url = clipboardStore.imageURL(for: item) ?? clipboardStore.fileURL(for: item)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            reportUnavailable(item)
            return nil
        }
        return url
    }

    /// Pin or unpin an entry; the selection and scroll follow the row as it moves.
    func togglePinnedClip(_ item: ClipboardItem) {
        clipboardStore.togglePinned(item)
        selectClip(item)
        palette.followToken = UUID()
    }

    /// Select `item`'s row as currently filtered; a moved row isn't always index 0.
    private func selectClip(_ item: ClipboardItem) {
        palette.selection =
            clipboardStore.rowIndex(
                of: item, in: palette.query, filter: palette.clipboardFilter) ?? 0
    }
}
