import AppKit

/// The AI Chat window's toolbar, title and chords; it lives exactly as long as the window does.
@MainActor
final class AIChatWindowChrome: NSObject, WindowChrome, NSToolbarDelegate, NSSearchFieldDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("AIChatWindow")
    private static let sidebar = NSToolbarItem.Identifier("AIChatToggleSidebar")
    private static let newChat = NSToolbarItem.Identifier("AIChatNewChat")
    private static let search = NSToolbarItem.Identifier("AIChatSearch")
    private static let actions = NSToolbarItem.Identifier("AIChatActions")
    private static let escapeKeyCode: UInt16 = 53
    private static let spaceKeyCode: UInt16 = 49

    private let coordinator: AIChatCoordinator
    private let chats: AIChatSurfacesState
    private let find: ChatFindState
    private weak var window: NSWindow?
    private var keyMonitor: Any?
    private let searchItem: NSSearchToolbarItem
    private let actionsButton: NSButton

    private var chat: AIChatState { chats.window }

    init(coordinator: AIChatCoordinator, chats: AIChatSurfacesState, find: ChatFindState) {
        self.coordinator = coordinator
        self.chats = chats
        self.find = find
        searchItem = NSSearchToolbarItem(itemIdentifier: Self.search)
        actionsButton = NSButton(
            image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Actions")
                ?? NSImage(),
            target: nil, action: nil)
        super.init()
        searchItem.searchField.placeholderString = "Find in Chat"
        searchItem.searchField.delegate = self
        searchItem.toolTip = "Find in Chat  ⌘F"
        searchItem.resignsFirstResponderWithCancel = true
        actionsButton.bezelStyle = .toolbar
        actionsButton.toolTip = "Actions  ⌘K"
        actionsButton.target = self
        actionsButton.action = #selector(showActions)
    }

    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - WindowChrome

    func install(in window: NSWindow) {
        self.window = window
        window.identifier = Self.windowIdentifier
        // Inline and leading, as Settings' is, so the title reads as the open chat's name.
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        // The system's own toolbar band, as every document window has: content scrolls beneath it.
        window.titlebarAppearsTransparent = false
        // Dragging across a transcript selects text; it must never move the window.
        window.isMovableByWindowBackground = false

        let toolbar = NSToolbar(identifier: "AIChatToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar

        installKeyMonitor()
        observeTitle()
        observeFind()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace, Self.sidebar, .space, Self.newChat, .sidebarTrackingSeparator,
            .flexibleSpace, Self.search, Self.actions
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.sidebar:
            return button(
                identifier, symbol: "sidebar.left", label: "Sidebar", toolTip: "Show or Hide Sidebar",
                action: #selector(toggleSidebar))
        case Self.newChat:
            return button(
                identifier, symbol: "square.and.pencil", label: "New Chat", toolTip: "New Chat  ⌘N",
                action: #selector(newChatAction))
        case Self.search:
            return searchItem
        case Self.actions:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = actionsButton
            item.label = "Actions"
            return item
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, symbol: String, label: String, toolTip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.label = label
        item.toolTip = toolTip
        item.target = self
        item.action = action
        return item
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        find.query = searchItem.searchField.stringValue
    }

    /// Return walks the matches, ⇧↩ walks back, as Find does in every Mac app.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        find.step(backwards ? -1 : 1, in: chat.session.messages)
        return true
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        find.query = ""
    }

    // MARK: - Actions

    @objc private func newChatAction() { coordinator.newChat() }

    @objc private func toggleSidebar() {
        (window?.contentViewController as? NSSplitViewController)?.toggleSidebar(nil)
    }

    @objc private func showActions() {
        let menu = AIChatActionsMenu.build(
            chat: chat, coordinator: coordinator,
            findInChat: { [weak self] in self?.searchItem.beginSearchInteraction() })
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: actionsButton.bounds.maxY + Theme.Spacing.xs),
            in: actionsButton)
    }

    // MARK: - Private

    /// Re-armed after every read; the hop is because `onChange` fires before the write lands.
    private func observeTitle() {
        withObservationTracking {
            window?.title = coordinator.title(of: chat)
            window?.subtitle = chat.isTemporary ? "Temporary · not saved to history" : ""
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTitle() }
        }
    }

    /// A sidebar hit sets the query from outside, so the field has to be told to show it.
    private func observeFind() {
        withObservationTracking {
            let query = find.query
            if searchItem.searchField.stringValue != query {
                searchItem.searchField.stringValue = query
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeFind() }
        }
    }

    /// The Actions menu's chords work with it closed too, so the window claims them before AppKit.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow
            else { return event }
            if self.handleDictationKey(event, in: window) { return nil }
            guard event.type == .keyDown, !event.isARepeat else { return event }
            return self.handle(event, in: window) ? nil : event
        }
    }

    /// Hold-to-talk needs the release too, and its repeats, which would otherwise type spaces.
    private func handleDictationKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.keyCode == Self.spaceKeyCode else { return false }
        let dictation = coordinator.dictation
        guard event.type == .keyDown else { return dictation.keyUp() }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .option,
            (window.firstResponder as? NSView)?.identifier == ChatComposerTextView.identifier
        else { return false }
        dictation.keyDown(in: .window, isRepeat: event.isARepeat)
        return true
    }

    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = (ASCIIKeyboardLayout.character(for: event) ?? event.charactersIgnoringModifiers)?
            .lowercased()
        if event.keyCode == Self.escapeKeyCode, modifiers.isEmpty,
            coordinator.dictation.cancel(in: .window)
        {
            return true
        }
        if event.keyCode == Self.escapeKeyCode, modifiers.isEmpty, chat.editingMessageID != nil,
            (window.firstResponder as? NSTextView)?.isFieldEditor != true
        {
            coordinator.cancelEdit(in: chat)
            return true
        }
        switch (modifiers, key) {
        case ([.command], "f"):
            searchItem.beginSearchInteraction()
        case ([.command], "g"), ([.command, .shift], "g"):
            find.step(modifiers.contains(.shift) ? -1 : 1, in: chat.session.messages)
        case ([.command], "k"):
            showActions()
        case ([.command], "n"):
            coordinator.newChat()
        case ([.command, .shift], "n"):
            coordinator.newTemporaryChat()
        case ([.command], "r") where AIChatActionsMenu.canRegenerate(chat):
            coordinator.regenerate(in: chat)
        case ([.command, .shift], "c") where chat.lastAssistantText != nil:
            coordinator.copyLastResponse(in: chat)
        case ([.command], ".") where chat.isStreaming:
            coordinator.stopResponse(in: chat)
        case ([.command, .option], ","):
            coordinator.showSettings()
        case ([.command], "o"):
            coordinator.chooseFiles(for: chat)
        case ([.command], "v"):
            // The search and rename fields take a paste as text, whatever the board holds.
            guard (window.firstResponder as? NSTextView)?.isFieldEditor != true else { return false }
            return coordinator.attachPastedFile(
                files: PasteboardFiles.urls(on: .general), to: chat)
        default:
            return false
        }
        return true
    }
}

/// The window's ⌘K menu: Quick AI's actions, plus what only a saved chat in a window can do.
@MainActor
enum AIChatActionsMenu {
    static func canRegenerate(_ chat: AIChatState) -> Bool {
        !chat.isStreaming && !chat.session.messages.isEmpty
    }

    static func build(
        chat: AIChatState, coordinator: AIChatCoordinator, findInChat: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        let saved = coordinator.isSaved(chat)
        if chat.isStreaming {
            menu.addItem(
                ClosureMenuItem("Stop Response", symbol: "stop.fill", key: ".") {
                    coordinator.stopResponse(in: chat)
                })
        }
        menu.addItem(
            ClosureMenuItem("New Chat", symbol: "square.and.pencil", key: "n") {
                coordinator.newChat()
            })
        menu.addItem(
            ClosureMenuItem(
                "New Temporary Chat", symbol: "eye.slash", key: "n", modifiers: [.command, .shift]
            ) {
                coordinator.newTemporaryChat()
            })
        if canRegenerate(chat) {
            menu.addItem(
                ClosureMenuItem("Regenerate Response", symbol: "arrow.clockwise", key: "r") {
                    coordinator.regenerate(in: chat)
                })
        }
        let dictating = coordinator.dictation.isActive(in: .window)
        menu.addItem(
            ClosureMenuItem(
                dictating ? "Stop Dictation" : "Start Dictation",
                symbol: dictating ? "mic.slash" : "mic", key: " ", modifiers: .option
            ) {
                coordinator.dictation.toggle(in: .window)
            })
        addTurnItems(to: menu, chat: chat, coordinator: coordinator)
        menu.addItem(.separator())
        if chat.lastAssistantText != nil {
            menu.addItem(
                ClosureMenuItem(
                    "Copy Last Response", symbol: "doc.on.doc", key: "c", modifiers: [.command, .shift]
                ) {
                    coordinator.copyLastResponse(in: chat)
                })
        }
        if !chat.session.messages.isEmpty {
            menu.addItem(
                ClosureMenuItem("Copy as Markdown", symbol: "text.bubble") {
                    coordinator.copyChat(id: chat.session.id)
                })
        }
        if saved {
            menu.addItem(
                ClosureMenuItem("Export as Markdown…", symbol: "square.and.arrow.up") {
                    coordinator.exportChat(id: chat.session.id)
                })
        }
        menu.addItem(
            ClosureMenuItem("Attach Files or Folder…", symbol: "paperclip", key: "o") {
                coordinator.chooseFiles(for: chat)
            })
        if !chat.pendingAttachments.isEmpty {
            menu.addItem(
                ClosureMenuItem("Remove Attachments", symbol: "paperclip") {
                    coordinator.clearAttachments(in: chat)
                })
        }
        addLibraryItems(to: menu, library: chat.library, chat: chat, coordinator: coordinator)
        if saved {
            menu.addItem(.separator())
            let pinned = coordinator.isPinned(chat)
            menu.addItem(
                ClosureMenuItem(pinned ? "Unpin Chat" : "Pin Chat", symbol: "pin") {
                    coordinator.togglePin(id: chat.session.id)
                })
            menu.addItem(
                ClosureMenuItem("Delete Chat…", symbol: "trash") {
                    Task { await coordinator.deleteChat(id: chat.session.id) }
                })
        }
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem("Chat Instructions…", symbol: "text.quote") {
                coordinator.showsChatInstructions = true
            })
        menu.addItem(
            ClosureMenuItem("Find in Chat", symbol: "magnifyingglass", key: "f", findInChat))
        menu.addItem(
            ClosureMenuItem(
                "AI Settings", symbol: "slider.horizontal.3", key: ",", modifiers: [.command, .option]
            ) {
                coordinator.showSettings()
            })
        return menu
    }

    private static func addLibraryItems(
        to menu: NSMenu, library: ChatLibraryState, chat: AIChatState,
        coordinator: AIChatCoordinator
    ) {
        if library.isIndexing {
            menu.addItem(
                ClosureMenuItem("Stop Reading Files", symbol: "xmark.circle") {
                    coordinator.stopReadingFiles(in: chat)
                })
        } else if !library.isEmpty {
            menu.addItem(
                ClosureMenuItem("Reindex Files", symbol: "arrow.triangle.2.circlepath") {
                    coordinator.reindexFiles(in: chat)
                })
            menu.addItem(
                ClosureMenuItem("Remove Files", symbol: "books.vertical") {
                    coordinator.removeFiles(in: chat)
                })
        }
    }

    /// The hover row's actions for the last turn, so the keyboard reaches them without a pointer.
    private static func addTurnItems(
        to menu: NSMenu, chat: AIChatState, coordinator: AIChatCoordinator
    ) {
        guard !chat.isStreaming else { return }
        if let question = coordinator.lastQuestion(in: chat) {
            menu.addItem(
                ClosureMenuItem("Edit Last Message", symbol: "pencil") {
                    coordinator.beginEdit(question, in: chat)
                })
        }
        let messages = chat.session.messages
        if !messages.isEmpty {
            // An unanswered last question is re-asked whole, never cut back to an earlier reply.
            let target = messages.last?.role == .assistant ? messages.last?.id : nil
            let retry = NSMenuItem(title: "Retry With", action: nil, keyEquivalent: "")
            retry.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            retry.submenu = retryMenu(reply: target, chat: chat, coordinator: coordinator)
            menu.addItem(retry)
        }
        if let reply = messages.last(where: { $0.role == .assistant }) {
            menu.addItem(
                ClosureMenuItem(
                    coordinator.speaker.speakingID == reply.id ? "Stop Speaking" : "Speak Last Reply",
                    symbol: "speaker.wave.2"
                ) {
                    coordinator.speak(reply)
                })
        }
        if !chat.isTemporary, let last = messages.last {
            menu.addItem(
                ClosureMenuItem("Branch Chat", symbol: "arrow.triangle.branch") {
                    coordinator.branch(from: last.id, in: chat)
                })
        }
    }

    private static func retryMenu(
        reply: UUID?, chat: AIChatState, coordinator: AIChatCoordinator
    ) -> NSMenu {
        let menu = NSMenu()
        for group in coordinator.modelGroups {
            menu.addItem(.sectionHeader(title: group.title))
            for option in group.options {
                menu.addItem(
                    ClosureMenuItem(option.title, symbol: "") {
                        coordinator.retry(reply: reply, with: option, in: chat)
                    })
            }
        }
        return menu
    }
}

/// An `NSMenuItem` that runs a closure, so a menu built per open needs no selector per row.
private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(
        _ title: String, symbol: String, key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, _ run: @escaping () -> Void
    ) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func runAction() { run() }
}
