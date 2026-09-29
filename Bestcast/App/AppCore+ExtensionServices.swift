import AppKit
@preconcurrency import ApplicationServices

/// The narrow seam `@bestcast/api` reaches Bestcast through; nothing else of `AppCore` leaks.
@MainActor
final class AppExtensionServices: ExtensionBestcastServices {
    unowned let core: AppCore

    init(core: AppCore) {
        self.core = core
    }

    private var settings: AppSettings { core.settings }

    func manifest(extension name: String) -> ExtensionManifest? {
        core.extensions.extensionNamed(name)?.manifest
    }

    func isFeatureEnabled(_ capability: ExtensionCapability) -> Bool {
        switch capability {
        case .clipboardHistoryRead: settings.clipboardEnabled
        case .snippetsRead, .snippetsWrite: settings.snippetsEnabled
        case .notesRead, .notesWrite: settings.notesEnabled
        case .quicklinksRead, .quicklinksWrite: settings.quicklinksEnabled
        case .windowsRead, .windowsWrite: settings.windowManagementEnabled
        case .calendarRead: settings.calendarEnabled
        case .calculator: true
        case .aiHandoff, .aiTools: settings.aiEnabled
        }
    }

    func confirm(_ request: ExtensionConsentRequest) async -> ExtensionConsentAnswer {
        var options = [DialogAction(title: "Allow")]
        if request.offersAlways { options.append(DialogAction(title: "Always Allow")) }
        options.append(DialogAction(title: "Don't Allow", role: .cancel))
        let index = await core.choose(
            title: request.title, message: request.message, symbol: "puzzlepiece.extension",
            options: options, defaultIndex: 0)
        switch index {
        case 0: return .allowOnce
        case 1 where request.offersAlways: return .always
        default: return .deny
        }
    }

    // MARK: - Clipboard

    func clipboardSearch(_ query: String, limit: Int, kind: String?) -> [[String: Any]] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let wanted = kind.flatMap(ClipboardItem.Kind.init(rawValue:))
        return core.clipboardStore.items.lazy
            .filter { wanted == nil || $0.kind == wanted }
            .filter { item in
                let text = (item.text ?? "").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .prefix(limit)
            .map(Self.clipboardEntry)
    }

    func clipboardRead(id: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id), let item = core.clipboardStore.item(withID: uuid) else {
            throw BestcastServiceError(message: "No clipboard entry has the id \(id).")
        }
        switch item.kind {
        case .text: return ["text": item.text ?? ""]
        case .file: return ["file": item.filePath ?? ""]
        case .image: return item.imagePath.map { ["file": $0] } ?? [:]
        }
    }

    private static func clipboardEntry(_ item: ClipboardItem) -> [String: Any] {
        var entry: [String: Any] = [
            "id": item.id.uuidString, "kind": item.kind.rawValue,
            "copiedAt": item.createdAt.ISO8601Format()
        ]
        switch item.kind {
        case .text:
            entry["text"] = item.text ?? ""
            entry["preview"] = BuiltInToolText.preview(item.text ?? "")
        case .file:
            entry["preview"] = item.filePath.map { ($0 as NSString).lastPathComponent } ?? "File"
        case .image:
            entry["preview"] = "Image"
        }
        if let source = item.sourceBundleID { entry["sourceApp"] = source }
        return entry
    }

    // MARK: - Snippets

    func snippets(matching query: String?) -> [[String: Any]] {
        let words = (query ?? "").lowercased().split(whereSeparator: \.isWhitespace)
        return core.snippetsStore.snippets
            .filter { record in
                let snippet = record.snippet
                let haystack = [snippet.name, snippet.keyword ?? "", snippet.text]
                    .joined(separator: "\n").lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            .map { record in
                var entry: [String: Any] = [
                    "id": record.id, "name": record.snippet.name, "text": record.snippet.text,
                    "enabled": record.snippet.isEnabled
                ]
                if let keyword = record.snippet.keyword { entry["keyword"] = keyword }
                return entry
            }
    }

    func createSnippet(name: String, text: String, keyword: String?) async throws -> String {
        let keyword = keyword.flatMap { $0.isEmpty ? nil : $0 }
        return try await core.snippetsStore.create(Snippet(name: name, text: text, keyword: keyword)).id
    }

    func expandSnippet(
        _ idOrKeyword: String, arguments: [String: String], clipboardHistory: Bool
    ) throws -> String {
        let snippets = core.snippetsStore.snippets
        guard
            let record = snippets.first(where: { $0.id == idOrKeyword })
                ?? snippets.first(where: { $0.snippet.isEnabled && $0.snippet.keyword == idOrKeyword })
        else { throw BestcastServiceError(message: "No snippet has the id or keyword \(idOrKeyword).") }
        let context = SnippetTemplateEngine.ExpansionContext(
            clipboardHistory: clipboardHistory ? core.snippetCoordinator.clipboardHistoryForExpansion() : [],
            selection: "", now: Date(), calendar: .current, locale: .current, timeZone: .current)
        let expansion = SnippetTemplateEngine.expand(
            record, snippets: snippets, context: context, userArguments: arguments)
        guard expansion.missingArguments.isEmpty else {
            let names = expansion.missingArguments.map(\.name).joined(separator: ", ")
            throw BestcastServiceError(message: "The snippet needs a value for: \(names).")
        }
        return expansion.text
    }

    func openSnippetEditor(name: String?, text: String, keyword: String?) {
        core.snippetCoordinator.editSnippet(
            nil, prefill: Snippet(name: name ?? "", text: text, keyword: keyword))
    }

    // MARK: - Notes

    func readNote() async throws -> [String: Any] {
        try await requireNote()
        return ["title": core.notesStore.activeTitle, "text": core.notesStore.source]
    }

    func appendToNote(_ text: String) async throws {
        try await requireNote()
        core.notesCoordinator.updateSource(BuiltInToolText.appending(text, to: core.notesStore.source))
        guard await core.notesStore.flush() else {
            throw BestcastServiceError(message: "The note could not be saved.")
        }
    }

    private func requireNote() async throws {
        if !core.notesStore.isLoaded { _ = await core.notesStore.start() }
        guard core.notesStore.activeID != nil else {
            throw BestcastServiceError(message: "There is no open note.")
        }
    }

    // MARK: - Quicklinks

    func quicklinks() -> [[String: Any]] {
        core.quicklinks.enabled.map { quicklink in
            var entry: [String: Any] = [
                "id": quicklink.id.uuidString, "name": quicklink.name, "link": quicklink.link,
                "arguments": SnippetTemplateEngine.declaredArguments(in: quicklink.link).map(\.name)
            ]
            if let app = quicklink.openWithBundleID { entry["application"] = app }
            return entry
        }
    }

    func quicklinkName(id: String) -> String? {
        UUID(uuidString: id).flatMap(core.quicklinks.quicklink(id:))?.name
    }

    func openQuicklink(id: String, query: String?) async throws {
        guard let uuid = UUID(uuidString: id), let quicklink = core.quicklinks.quicklink(id: uuid),
            quicklink.isEnabled
        else { throw BestcastServiceError(message: "No quicklink has the id \(id).") }
        var values: [String: String] = [:]
        if let first = SnippetTemplateEngine.declaredArguments(in: quicklink.link).first, let query {
            values[first.name] = query
        }
        let encoding: SnippetTemplateEngine.ValueEncoding =
            QuicklinkDestination.usesURLEncoding(quicklink.link) ? .percentEncoding : .none
        let context = SnippetTemplateEngine.ExpansionContext(
            clipboard: "", selection: "", now: Date(), calendar: .current, locale: .current,
            timeZone: .current)
        let expansion = SnippetTemplateEngine.expand(
            text: quicklink.link, context: context, userArguments: values, encoding: encoding)
        guard expansion.missingArguments.isEmpty else {
            let names = expansion.missingArguments.map(\.name).joined(separator: ", ")
            throw BestcastServiceError(message: "“\(quicklink.name)” needs a value for: \(names).")
        }
        do throws(QuicklinkLauncher.Failure) {
            try await QuicklinkLauncher.open(
                expansion.text, openWithBundleID: quicklink.openWithBundleID,
                inNewWindow: settings.quicklinkOpensNewWindow)
        } catch {
            throw BestcastServiceError(message: error.localizedDescription)
        }
    }

    func createQuicklink(name: String, link: String, application: String?) throws -> String {
        let draft = Quicklink(
            name: name, link: link, openWithBundleID: application.flatMap(Self.bundleID))
        return try core.quicklinkCoordinator.addQuicklink(draft).id.uuidString
    }

    func openQuicklinkEditor(name: String?, link: String, application: String?) {
        core.quicklinkCoordinator.editQuicklink(
            nil,
            prefill: Quicklink(
                name: name ?? "", link: link, openWithBundleID: application.flatMap(Self.bundleID)))
    }

    /// Raycast names an app by path, bundle id or display name; a quicklink stores a bundle id.
    private static func bundleID(for application: String) -> String? {
        if application.hasPrefix("/") { return Bundle(path: application)?.bundleIdentifier }
        for folder in ["/Applications", "/System/Applications"] {
            if let id = Bundle(path: "\(folder)/\(application).app")?.bundleIdentifier { return id }
        }
        return application.contains(".") ? application : nil
    }

    // MARK: - Windows

    func windows() throws -> [ExtensionWindowInfo] {
        try requireAccessibility()
        let snapshot = WindowInventory.snapshot()
        let focused = focusedWindow()
        let screens = snapshot.screens
        return snapshot.windows.compactMap { window in
            guard let element = snapshot.elements[window.handle] else { return nil }
            let host = WindowPlacementEngine.screen(containing: window.frame, in: screens.map(\.screen))
            let desktop = screens.first { $0.screen.id == host?.id }?.display.uuid ?? ""
            return ExtensionWindowInfo(
                id: Self.windowID(element.window, fallback: "\(window.bundleID):\(window.handle)"),
                app: element.app.localizedName ?? window.bundleID, bundleID: window.bundleID,
                title: window.title, frame: window.frame,
                focused: focused.map { CFEqual($0, element.window) } ?? false,
                desktopID: desktop,
                positionable: AXWindowAccess.isSettable(kAXPositionAttribute, on: element.window),
                resizable: AXWindowAccess.isSettable(kAXSizeAttribute, on: element.window))
        }
    }

    func desktops() -> [ExtensionDesktopInfo] {
        let screens = AXScreens.layoutScreens(geometry: AXGeometry(screens: NSScreen.screens))
        let frontFrame = focusedWindow().flatMap(AXWindowAccess.frame(of:))
        let active =
            frontFrame.flatMap { WindowPlacementEngine.screen(containing: $0, in: screens.map(\.screen)) }?
            .id ?? screens.first?.screen.id
        return screens.map { screen in
            ExtensionDesktopInfo(
                id: screen.display.uuid, size: screen.screen.frame.size, active: screen.screen.id == active)
        }
    }

    func setWindowFrame(id: String, frame: CGRect) throws {
        let window = try element(id: id)
        AXUIElementSetMessagingTimeout(window, AXWindowAccess.messagingTimeout)
        guard AXWindowAccess.isSettable(kAXPositionAttribute, on: window) else {
            throw BestcastServiceError(message: "That window cannot be moved.")
        }
        let canResize = AXWindowAccess.isSettable(kAXSizeAttribute, on: window)
        // Resized either side of the move, so a window near a screen edge is not clamped short.
        if canResize { _ = AXWindowAccess.setSize(frame.size, on: window) }
        _ = AXWindowAccess.setPosition(frame.origin, on: window)
        if canResize { _ = AXWindowAccess.setSize(frame.size, on: window) }
    }

    func setWindowFullScreen(id: String) throws {
        let window = try element(id: id)
        guard AXWindowAccess.isSettable(AXWindowAccess.fullScreenAttribute as String, on: window),
            AXUIElementSetAttributeValue(window, AXWindowAccess.fullScreenAttribute, kCFBooleanTrue)
                == .success
        else { throw BestcastServiceError(message: "That window cannot enter full screen.") }
    }

    func applyWindowLayout(named name: String) throws {
        let layouts = core.windowLayouts.layouts
        guard
            let layout = layouts.first(where: { $0.id.uuidString == name })
                ?? layouts.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
        else { throw BestcastServiceError(message: "No window layout is called “\(name)”.") }
        core.windowLayoutCoordinator.runWindowLayout(id: layout.id)
    }

    func runWindowCommand(_ command: String) throws {
        guard
            let id = WindowCommand.ID(rawValue: command)
                ?? WindowCommand.ID.allCases.first(where: { String(describing: $0) == command })
        else { throw BestcastServiceError(message: "No window command is called “\(command)”.") }
        try requireAccessibility()
        core.windowCommandCoordinator.runWindowCommand(id: id)
    }

    private func requireAccessibility() throws {
        guard Permissions.isAccessibilityTrusted() else {
            throw BestcastServiceError(message: "Bestcast needs Accessibility access to manage windows.")
        }
    }

    private func focusedWindow() -> AXUIElement? {
        BuiltInToolRunner.frontmostExternalApp().flatMap { app in
            AXWindowAccess.targetWindow(in: AXWindowAccess.application(for: app.processIdentifier))
        }
    }

    private func element(id: String) throws -> AXUIElement {
        try requireAccessibility()
        let snapshot = WindowInventory.snapshot()
        let match = snapshot.windows.first { window in
            guard let element = snapshot.elements[window.handle] else { return false }
            return Self.windowID(element.window, fallback: "\(window.bundleID):\(window.handle)") == id
        }
        guard let match, let element = snapshot.elements[match.handle] else {
            throw BestcastServiceError(message: "No window has the id \(id).")
        }
        return element.window
    }

    private static func windowID(_ window: AXUIElement, fallback: String) -> String {
        AXWindowAccess.windowID(of: window).map(String.init) ?? fallback
    }

    // MARK: - Calendar and calculator

    func calendarEvents(from start: Date, to end: Date) throws -> [[String: Any]] {
        guard let events = core.calendarStore.events(in: DateInterval(start: start, end: end)) else {
            throw BestcastServiceError(
                message: "Bestcast has no access to Calendar. Grant it in Bestcast's Calendar settings.")
        }
        return events.map { event in
            [
                "title": event.title, "calendar": event.calendarName, "allDay": event.isAllDay,
                "start": event.start.ISO8601Format(), "end": event.end.ISO8601Format()
            ]
        }
    }

    func evaluate(_ expression: String) -> [String: Any]? {
        let result = CalcEngine.evaluate(
            expression, now: Date(), calendar: .current, rates: core.currencyRates.rates,
            region: RegionCurrency.code, format: .english)
        guard case .value(let display, let copyText)? = result?.payload else { return nil }
        return ["result": display, "raw": copyText]
    }

    // MARK: - AI

    /// A prompt is staged, never sent: the user presses Return on what an extension wrote.
    func openQuickAI(prompt: String?) {
        guard settings.aiEnabled else { return }
        guard let prompt, !prompt.isEmpty else {
            if !core.paletteCoordinator.isShowing(.ai) { core.quickAICoordinator.show() }
            return
        }
        core.aiChats.quickAI.startNewChat()
        core.aiChats.quickAI.draft = prompt
        core.paletteCoordinator.showPalette(mode: .ai)
    }

    func openChat(prompt: String?, mention: String?) {
        guard settings.aiEnabled else { return }
        let draft = [mention.map { "@\($0)" }, prompt].compactMap { $0 }.joined(separator: " ")
        if !draft.isEmpty {
            core.aiChatCoordinator.newChat()
            core.aiChats.window.draft = draft
        }
        core.aiChatCoordinator.showWindow()
    }

    func aiTools() -> [[String: Any]] {
        core.builtInTools.offeredIntegrations.flatMap(BuiltInToolCatalog.tools(for:)).map { tool in
            ["name": tool.wireName, "description": tool.description, "writes": tool.effect == .write]
        }
    }

    func callAITool(name: String, input: String) async throws -> String {
        let result = await core.builtInTools.invoke(
            AIToolCall(id: UUID().uuidString, name: name, arguments: input))
        guard !result.isError else { throw BestcastServiceError(message: result.content) }
        return result.content
    }
}
