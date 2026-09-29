import AppKit

/// What running one request touches: each feature's own store or service, never a copy of it.
@MainActor
final class BuiltInToolRunner {
    /// A request resolved far enough to describe, so the dialog names what `perform` then does.
    struct Step {
        let subject: String?
        let perform: @MainActor () async throws -> String
    }

    typealias Failure = BuiltInToolRequest.Failure

    private unowned let core: AppCore

    init(core: AppCore) {
        self.core = core
    }

    private var settings: AppSettings { core.settings }

    func prepare(_ request: BuiltInToolRequest) async throws -> Step {
        switch request {
        case .clipboardSearch(let query, let limit):
            return Step(subject: nil) { [self] in clipboardSearch(query, limit: limit) }
        case .clipboardRead(let id):
            return Step(subject: nil) { [self] in try clipboardRead(id) }
        case .clipboardCopy(let text):
            return Step(subject: nil) {
                Paster.copyPlainText(text)
                return "Copied."
            }
        case .snippetsSearch(let query, let limit):
            try requireSnippets()
            return Step(subject: nil) { [self] in snippetsSearch(query, limit: limit) }
        case .snippetsCreate(let name, let text, let keyword):
            try requireSnippets()
            return Step(subject: nil) { [core] in
                let stored = try await core.snippetsStore.create(
                    Snippet(name: name, text: text, keyword: keyword))
                return "Created “\(stored.snippet.name)”."
            }
        case .notesRead:
            try await requireNote()
            return Step(subject: nil) { [core] in
                LoopbackMCP.text(
                    .object([
                        "title": .string(core.notesStore.activeTitle),
                        "markdown": .string(core.notesStore.source)
                    ]))
            }
        case .notesAppend(let text):
            try await requireNote()
            return Step(subject: core.notesStore.activeTitle) { [core] in
                guard core.notesStore.activeID != nil else {
                    throw Failure(message: "The note was closed before the text was added.")
                }
                core.notesCoordinator.updateSource(
                    BuiltInToolText.appending(text, to: core.notesStore.source))
                guard await core.notesStore.flush() else {
                    throw Failure(message: "The note could not be saved.")
                }
                return "Added to “\(core.notesStore.activeTitle)”."
            }
        case .calendarEvents(let interval):
            return Step(subject: nil) { [self] in try calendarEvents(in: interval) }
        case .appsRunning:
            return Step(subject: nil) { [self] in runningApps() }
        case .appsOpen(let name):
            let app = try installedApp(named: name)
            return Step(subject: app.name) {
                AppLauncher.launch(app.url)
                return "Opened \(app.name)."
            }
        case .appsArrangeWindow(let id):
            try requireWindowManagement()
            guard let app = Self.frontmostExternalApp() else {
                throw Failure(message: "No other app has a window in front.")
            }
            let name = app.localizedName ?? "the app"
            return Step(subject: name) { [core, settings] in
                guard
                    core.windowMover.perform(
                        id, target: .external(app), gap: CGFloat(settings.windowGap),
                        cycle: settings.windowCycle)
                else { throw Failure(message: "\(name)’s window could not be moved.") }
                return "Arranged \(name)’s window."
            }
        case .filesSearch(let query, let limit):
            return Step(subject: nil) { [core] in
                let results = try await core.fileSearch.results(for: query)
                return LoopbackMCP.text(
                    .array(
                        results.prefix(limit).map {
                            .object([
                                "path": .string($0.url.path),
                                "kind": .string($0.isDirectory ? "folder" : "file")
                            ])
                        }))
            }
        case .filesRead(let path):
            return Step(subject: nil) { try await Self.readFile(path) }
        case .quicklinksList:
            try requireQuicklinks()
            return Step(subject: nil) { [self] in quicklinksList() }
        case .quicklinksOpen(let name, let argument):
            try requireQuicklinks()
            let (quicklink, link) = try resolveQuicklink(named: name, argument: argument)
            return Step(subject: link) { [settings] in
                do throws(QuicklinkLauncher.Failure) {
                    try await QuicklinkLauncher.open(
                        link, openWithBundleID: quicklink.openWithBundleID,
                        inNewWindow: settings.quicklinkOpensNewWindow)
                } catch {
                    throw Failure(message: error.localizedDescription)
                }
                return "Opened “\(quicklink.name)”."
            }
        case .calculate(let expression):
            return Step(subject: nil) { [self] in try calculate(expression) }
        case .frontmostApp:
            return Step(subject: nil) {
                guard let app = Self.frontmostExternalApp() else { return "No other app is in front." }
                return LoopbackMCP.text(
                    .object([
                        "name": .string(app.localizedName ?? ""),
                        "bundleID": .string(app.bundleIdentifier ?? "")
                    ]))
            }
        case .selectedText:
            return Step(subject: nil) { try Self.selectedText() }
        }
    }

    // MARK: - Clipboard

    private func clipboardSearch(_ query: String, limit: Int) -> String {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let matches = core.clipboardStore.items.lazy
            .filter { $0.kind == .text }
            .filter { item in
                let text = (item.text ?? "").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .prefix(limit)
        return LoopbackMCP.text(
            .array(
                matches.map { item in
                    .object([
                        "id": .string(item.id.uuidString),
                        "copied": .string(item.createdAt.ISO8601Format()),
                        "preview": .string(BuiltInToolText.preview(item.text ?? ""))
                    ])
                }))
    }

    private func clipboardRead(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id), let item = core.clipboardStore.item(withID: uuid),
            item.kind == .text, let text = item.text
        else { throw Failure(message: "No text entry has that id.") }
        return text
    }

    // MARK: - Snippets

    private func requireSnippets() throws {
        guard settings.snippetsEnabled else {
            throw Failure(message: "Snippets are switched off in Tinycast.")
        }
    }

    private func snippetsSearch(_ query: String, limit: Int) -> String {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let matches = core.snippetsStore.snippets.lazy.map(\.snippet).filter { snippet in
            let haystack = [snippet.name, snippet.keyword ?? "", snippet.text]
                .joined(separator: "\n").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return LoopbackMCP.text(
            .array(
                matches.prefix(limit).map { snippet in
                    .object([
                        "name": .string(snippet.name),
                        "keyword": snippet.keyword.map(JSONValue.string) ?? .null,
                        "text": .string(snippet.text)
                    ])
                }))
    }

    // MARK: - Notes

    private func requireNote() async throws {
        guard settings.notesEnabled else {
            throw Failure(message: "Notes are switched off in Tinycast.")
        }
        if !core.notesStore.isLoaded { _ = await core.notesStore.start() }
        guard core.notesStore.activeID != nil else {
            throw Failure(message: "There is no open note.")
        }
    }

    // MARK: - Calendar

    private func calendarEvents(in interval: DateInterval) throws -> String {
        guard let events = core.calendarStore.events(in: interval) else {
            throw Failure(
                message: "Tinycast has no access to Calendar. The user can grant it in "
                    + "Tinycast's Calendar settings.")
        }
        return LoopbackMCP.text(
            .array(
                events.map { event in
                    var fields: [String: JSONValue] = [
                        "title": .string(event.title), "calendar": .string(event.calendarName),
                        "start": .string(event.start.ISO8601Format()),
                        "end": .string(event.end.ISO8601Format()),
                        "allDay": .bool(event.isAllDay)
                    ]
                    if event.isDeclined { fields["declined"] = .bool(true) }
                    if let link = event.link { fields["meetingLink"] = .string(link.url.absoluteString) }
                    return .object(fields)
                }))
    }

    // MARK: - Apps & windows

    private func runningApps() -> String {
        let front = Self.frontmostExternalApp()?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .compactMap { app -> JSONValue? in
                guard let name = app.localizedName else { return nil }
                var fields: [String: JSONValue] = ["name": .string(name)]
                if app.processIdentifier == front { fields["frontmost"] = .bool(true) }
                if app.isHidden { fields["hidden"] = .bool(true) }
                return .object(fields)
            }
        return LoopbackMCP.text(.array(apps))
    }

    private func installedApp(named name: String) throws -> AppEntry {
        let apps = core.appIndex.apps.filter { $0.kind == .application }
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        guard
            let app = apps.first(where: { $0.name.lowercased() == wanted })
                ?? apps.first(where: { $0.name.lowercased().hasPrefix(wanted) })
        else { throw Failure(message: "No installed app is called “\(name)”.") }
        return app
    }

    private func requireWindowManagement() throws {
        guard settings.windowManagementEnabled else {
            throw Failure(message: "Window management is switched off in Tinycast.")
        }
        guard Permissions.isAccessibilityTrusted() else {
            throw Failure(message: "Tinycast needs Accessibility access to move windows.")
        }
    }

    /// The chat window makes Tinycast frontmost, so the app behind it is found by window order.
    static func frontmostExternalApp() -> NSRunningApplication? {
        let own = NSRunningApplication.current.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            return front
        }
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                let app = NSRunningApplication(processIdentifier: pid),
                app.activationPolicy == .regular
            else { continue }
            return app
        }
        return nil
    }

    // MARK: - Files

    /// Off the main actor: a read of a slow volume must not stall the interface.
    nonisolated private static func readFile(_ path: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let url = BuiltInFileAccess.standardized(path, home: home)
            // Checked again once resolved, so a link inside home cannot lead outside it.
            let resolved = url.resolvingSymlinksInPath()
            guard BuiltInFileAccess.isReadable(url, home: home),
                BuiltInFileAccess.isReadable(resolved, home: home.resolvingSymlinksInPath())
            else {
                throw Failure(
                    message: "Only files in the home folder, outside ~/Library and hidden "
                        + "folders, can be read.")
            }
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { throw Failure(message: "No file is there.") }
            guard (values?.fileSize ?? 0) <= BuiltInFileAccess.maxBytes else {
                throw Failure(
                    message: "The file is larger than \(BuiltInFileAccess.maxBytes / 1024) KB.")
            }
            guard let data = try? Data(contentsOf: resolved),
                let text = String(data: data, encoding: .utf8)
            else { throw Failure(message: "The file is not UTF-8 text.") }
            return text
        }.value
    }

    // MARK: - Quicklinks

    private func requireQuicklinks() throws {
        guard settings.quicklinksEnabled else {
            throw Failure(message: "Quicklinks are switched off in Tinycast.")
        }
    }

    private func quicklinksList() -> String {
        LoopbackMCP.text(
            .array(
                core.quicklinks.enabled.map { quicklink in
                    let arguments = SnippetTemplateEngine.declaredArguments(in: quicklink.link)
                    return .object([
                        "name": .string(quicklink.name), "link": .string(quicklink.link),
                        "arguments": .array(arguments.map { .string($0.name) })
                    ])
                }))
    }

    private func resolveQuicklink(
        named name: String, argument: String?
    ) throws -> (Quicklink, String) {
        let wanted = name.lowercased()
        guard let quicklink = core.quicklinks.enabled.first(where: { $0.name.lowercased() == wanted })
        else { throw Failure(message: "No quicklink is called “\(name)”.") }
        let first = SnippetTemplateEngine.declaredArguments(in: quicklink.link).first
        var values: [String: String] = [:]
        if let first, let argument { values[first.name] = argument }
        let encoding: SnippetTemplateEngine.ValueEncoding =
            QuicklinkDestination.usesURLEncoding(quicklink.link) ? .percentEncoding : .none
        // No selection and no clipboard: a model's link carries only what it was asked to fill.
        let context = SnippetTemplateEngine.ExpansionContext(
            clipboard: "", selection: "", now: Date(), calendar: .current, locale: .current,
            timeZone: .current)
        let expansion = SnippetTemplateEngine.expand(
            text: quicklink.link, context: context, userArguments: values, encoding: encoding)
        guard expansion.missingArguments.isEmpty else {
            let names = expansion.missingArguments.map(\.name).joined(separator: ", ")
            throw Failure(message: "“\(quicklink.name)” needs a value for: \(names).")
        }
        return (quicklink, expansion.text)
    }

    // MARK: - Calculator

    private func calculate(_ expression: String) throws -> String {
        let result = CalcEngine.evaluate(
            expression, now: Date(), calendar: .current, rates: core.currencyRates.rates,
            region: RegionCurrency.code, format: .english)
        switch result?.payload {
        case .value(_, let copyText)?: return copyText
        case .error(let message)?: throw Failure(message: message)
        case nil: throw Failure(message: "Tinycast's calculator cannot evaluate that.")
        }
    }

    // MARK: - System

    /// Accessibility only: never a prompt, and never a synthetic ⌘C into someone else's app.
    private static func selectedText() throws -> String {
        guard Permissions.isAccessibilityTrusted() else {
            throw Failure(message: "Tinycast needs Accessibility access to read a selection.")
        }
        guard let app = frontmostExternalApp() else { throw Failure(message: "No other app is in front.") }
        switch AccessibilityText.read(in: app) {
        case .text(let text): return text
        case .noFocusedElement: throw Failure(message: "Nothing is focused in the frontmost app.")
        case .empty: throw Failure(message: "Nothing is selected in the frontmost app.")
        }
    }
}
