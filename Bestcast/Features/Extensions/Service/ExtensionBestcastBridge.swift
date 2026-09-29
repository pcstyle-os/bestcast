import Foundation

/// A refusal the runtime rethrows as `BestcastPermissionError`; the prefix is how JS recognises it.
struct BestcastPermissionError: LocalizedError, Equatable {
    static let marker = "bestcast-permission"

    let capability: String
    let reason: String

    init(_ reason: String, capability: String) {
        self.reason = reason
        self.capability = capability
    }

    var errorDescription: String? { "[\(Self.marker):\(capability)] \(reason)" }
}

/// A plain failure from a Bestcast feature, surfaced to JS as an ordinary `Error`.
struct BestcastServiceError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// What the host knows about the calling command; a background run can never raise a dialog.
struct ExtensionBestcastCallContext: Sendable {
    let canPrompt: Bool
}

struct ExtensionConsentRequest: Equatable, Sendable {
    let title: String
    let message: String?
    /// A write offers Always Allow; a read is remembered after one Allow anyway.
    let offersAlways: Bool
}

enum ExtensionConsentAnswer: Equatable, Sendable {
    case allowOnce
    case always
    case deny
}

/// One window as the bridge sees it, in AX's top-left global space.
struct ExtensionWindowInfo: Equatable, Sendable {
    let id: String
    let app: String
    let bundleID: String
    let title: String
    let frame: CGRect
    let focused: Bool
    let desktopID: String
    let positionable: Bool
    let resizable: Bool
}

/// One display, standing in for a desktop: Spaces are not public, so a screen is the unit.
struct ExtensionDesktopInfo: Equatable, Sendable {
    let id: String
    let size: CGSize
    let active: Bool
}

/// Everything an extension may reach in Bestcast, and nothing more. `AppCore` conforms.
@MainActor
protocol ExtensionBestcastServices: AnyObject {
    func manifest(extension name: String) -> ExtensionManifest?
    func isFeatureEnabled(_ capability: ExtensionCapability) -> Bool
    func confirm(_ request: ExtensionConsentRequest) async -> ExtensionConsentAnswer

    func clipboardSearch(_ query: String, limit: Int, kind: String?) -> [[String: Any]]
    func clipboardRead(id: String) throws -> [String: Any]

    func snippets(matching query: String?) -> [[String: Any]]
    func createSnippet(name: String, text: String, keyword: String?) async throws -> String
    func expandSnippet(
        _ idOrKeyword: String, arguments: [String: String], clipboardHistory: Bool
    ) throws -> String
    func openSnippetEditor(name: String?, text: String, keyword: String?)

    func readNote() async throws -> String
    func appendToNote(_ text: String) async throws

    func quicklinks() -> [[String: Any]]
    func quicklinkName(id: String) -> String?
    func openQuicklink(id: String, query: String?) async throws
    func createQuicklink(name: String, link: String, application: String?) throws -> String
    func openQuicklinkEditor(name: String?, link: String, application: String?)

    func windows() throws -> [ExtensionWindowInfo]
    func desktops() -> [ExtensionDesktopInfo]
    func setWindowFrame(id: String, frame: CGRect) throws
    func setWindowFullScreen(id: String) throws
    func applyWindowLayout(named name: String) throws
    func runWindowCommand(_ command: String) throws

    func calendarEvents(from start: Date, to end: Date) throws -> [[String: Any]]
    func evaluate(_ expression: String) -> [String: Any]?

    func openQuickAI(prompt: String?)
    func openChat(prompt: String?, mention: String?)
    func aiTools() -> [[String: Any]]
    func callAITool(name: String, input: String) async throws -> String
}

/// `@bestcast/api`'s host side: every call is checked, asked about if it must be, then served.
@MainActor
final class ExtensionBestcastBridge {
    var services: ExtensionBestcastServices?
    var grants: ExtensionGrantStore?

    /// Bumped when extensions switch off, so a call waiting on a dialog cannot land afterwards.
    private var generation = 0
    private var consentTail: Task<Void, Never>?
    private var loggedUnknown: Set<String> = []

    func stopAll() {
        generation += 1
    }

    func perform(
        method: String, arguments: [RenderValue], extension name: String,
        context: ExtensionBestcastCallContext
    ) async throws -> Any? {
        guard let services, let grants else {
            throw BestcastServiceError(message: "The Bestcast API is not available.")
        }
        let declared = declaredCapabilities(of: name, services: services)
        let canPrompt = context.canPrompt
        let call = Call(arguments: arguments)

        switch method {
        case "capabilities":
            return ExtensionCapability.allCases.map { capability in
                ["name": capability.rawValue, "state": state(of: capability, name, declared, services, grants)]
            }
        case "requestCapability":
            guard let capability = ExtensionCapability(rawValue: call.string(0) ?? "") else {
                throw BestcastServiceError(message: "Unknown capability \(call.string(0) ?? "").")
            }
            try await authorize(
                capability, subject: { nil }, name: name, declared: declared, isImplicit: false,
                canPrompt: canPrompt, services: services, grants: grants)
            return true
        default:
            break
        }

        guard let route = Self.routes[method] else { throw Self.unknown(method) }
        guard arguments.reduce(0, { $0 + Self.textLength($1) }) <= Self.maxArgumentLength else {
            throw BestcastServiceError(message: "bestcast.\(method) was sent too much text.")
        }
        try await authorize(
            route.capability, subject: { try self.subject(for: method, call: call, services: services) },
            name: name, declared: declared, isImplicit: route.isImplicit, canPrompt: canPrompt,
            skipsPrompt: route.skipsPrompt, services: services, grants: grants)
        guard canPrompt || !route.presents else {
            throw BestcastPermissionError(ExtensionGrantPolicy.denied, capability: route.capability.rawValue)
        }
        return try await serve(method, call: call, name: name, services: services, grants: grants)
    }

    // MARK: - Routing

    private struct Route {
        let capability: ExtensionCapability
        /// Raycast's own API, so no declaration is needed.
        var isImplicit = false
        /// Opens an editor instead of acting; saving there is the consent.
        var skipsPrompt = false
        /// Brings up a window or a dialog, which a background run must never do.
        var presents = false
    }

    /// Far past any real snippet or note, so a call cannot flood a store or hide behind a preview.
    private static let maxArgumentLength = 100_000

    private static func textLength(_ value: RenderValue) -> Int {
        switch value {
        case .string(let text): text.count
        case .array(let items): items.reduce(0) { $0 + textLength($1) }
        case .object(let fields): fields.reduce(0) { $0 + $1.key.count + textLength($1.value) }
        default: 0
        }
    }

    private static let routes: [String: Route] = [
        "clipboardHistory.search": Route(capability: .clipboardHistoryRead),
        "clipboardHistory.read": Route(capability: .clipboardHistoryRead),
        "snippets.list": Route(capability: .snippetsRead),
        "snippets.search": Route(capability: .snippetsRead),
        "snippets.expand": Route(capability: .snippetsRead),
        "snippets.create": Route(capability: .snippetsWrite),
        "snippets.openEditor": Route(
            capability: .snippetsWrite, isImplicit: true, skipsPrompt: true, presents: true),
        "notes.read": Route(capability: .notesRead),
        "notes.append": Route(capability: .notesWrite),
        "quicklinks.list": Route(capability: .quicklinksRead),
        "quicklinks.open": Route(capability: .quicklinksWrite, presents: true),
        "quicklinks.create": Route(capability: .quicklinksWrite),
        "quicklinks.openEditor": Route(
            capability: .quicklinksWrite, isImplicit: true, skipsPrompt: true, presents: true),
        "windows.list": Route(capability: .windowsRead),
        "windows.setBounds": Route(capability: .windowsWrite),
        "windows.applyLayout": Route(capability: .windowsWrite),
        "windows.runCommand": Route(capability: .windowsWrite),
        "windows.active": Route(capability: .windowsRead, isImplicit: true),
        "windows.onActiveDesktop": Route(capability: .windowsRead, isImplicit: true),
        "windows.desktops": Route(capability: .windowsRead, isImplicit: true),
        "windows.setWindowBounds": Route(capability: .windowsWrite, isImplicit: true),
        "calendar.events": Route(capability: .calendarRead),
        "calculator.evaluate": Route(capability: .calculator),
        "ai.openQuickAI": Route(capability: .aiHandoff, presents: true),
        "ai.openChat": Route(capability: .aiHandoff, presents: true),
        "ai.tools.list": Route(capability: .aiTools),
        "ai.tools.call": Route(capability: .aiTools, presents: true)
    ]

    // MARK: - Consent

    private func declaredCapabilities(
        of name: String, services: ExtensionBestcastServices
    ) -> Set<ExtensionCapability> {
        guard let manifest = services.manifest(extension: name) else { return [] }
        #if DEBUG
            let unknown = manifest.unknownCapabilities
            if !unknown.isEmpty, loggedUnknown.insert(name).inserted {
                print("[extension debug] \(name) declares unknown capabilities: \(unknown)")
            }
        #endif
        return manifest.declaredCapabilities
    }

    private func state(
        of capability: ExtensionCapability, _ name: String, _ declared: Set<ExtensionCapability>,
        _ services: ExtensionBestcastServices, _ grants: ExtensionGrantStore
    ) -> String {
        guard !grants.isRefused(capability, extension: name) else { return "denied" }
        let decision = ExtensionGrantPolicy.decide(
            capability: capability, declared: declared,
            grant: grants.grant(for: name, capability: capability), isImplicit: false,
            featureEnabled: services.isFeatureEnabled(capability))
        switch decision {
        case .allow: return "granted"
        case .ask: return "ask"
        case .deny(let reason): return reason == ExtensionGrantPolicy.denied ? "denied" : "undeclared"
        }
    }

    private func authorize(
        _ capability: ExtensionCapability, subject: () throws -> String?, name: String,
        declared: Set<ExtensionCapability>, isImplicit: Bool, canPrompt: Bool,
        skipsPrompt: Bool = false, services: ExtensionBestcastServices, grants: ExtensionGrantStore
    ) async throws {
        let refuse = { (reason: String) in BestcastPermissionError(reason, capability: capability.rawValue) }
        let decision = ExtensionGrantPolicy.decide(
            capability: capability, declared: declared,
            grant: grants.grant(for: name, capability: capability), isImplicit: isImplicit,
            featureEnabled: services.isFeatureEnabled(capability))
        switch decision {
        case .deny(let reason):
            throw refuse(reason)
        case .allow:
            grants.touch(capability, extension: name)
        case .ask where skipsPrompt:
            return
        case .ask:
            guard canPrompt, !grants.isRefused(capability, extension: name) else {
                throw refuse(ExtensionGrantPolicy.denied)
            }
            let started = generation
            let displayName = services.manifest(extension: name)?.title ?? name
            let message = try capability.isWrite ? subject() : nil
            let answer = await ask(
                ExtensionConsentRequest(
                    title: "\(displayName) wants to \(capability.title)",
                    message: message,
                    offersAlways: capability.isWrite),
                services: services)
            guard started == generation, !Task.isCancelled else {
                throw refuse(ExtensionGrantPolicy.denied)
            }
            switch answer {
            case .deny:
                grants.refuse(capability, extension: name)
                throw refuse(ExtensionGrantPolicy.denied)
            case .allowOnce:
                grants.grant(capability, always: false, extension: name)
            case .always:
                grants.grant(capability, always: true, extension: name)
            }
        }
    }

    /// One dialog at a time: a second would be refused by `DialogController` and read as a denial.
    private func ask(
        _ request: ExtensionConsentRequest, services: ExtensionBestcastServices
    ) async -> ExtensionConsentAnswer {
        let previous = consentTail
        let asking = Task { [weak services] in
            await previous?.value
            return await services?.confirm(request) ?? .deny
        }
        consentTail = Task { _ = await asking.value }
        return await asking.value
    }

    // MARK: - Subjects

    private func subject(
        for method: String, call: Call, services: ExtensionBestcastServices
    ) throws -> String? {
        switch method {
        case "snippets.create":
            let draft = call.object(0)
            let name = Self.preview(draft["name"]?.stringValue ?? "")
            let keyword = draft["keyword"]?.stringValue.flatMap { $0.isEmpty ? nil : Self.preview($0) }
            return "Create snippet \u{2018}\(name)\u{2019}" + (keyword.map { " with keyword \($0)" } ?? "")
                + "\n\n\u{201C}\(Self.preview(draft["text"]?.stringValue ?? ""))\u{201D}"
        case "notes.append":
            return "Add to your note: \u{201C}\(Self.preview(call.string(0) ?? ""))\u{201D}"
        case "quicklinks.open":
            let name = services.quicklinkName(id: call.string(0) ?? "") ?? call.string(0) ?? ""
            let query = call.string(1).map { " with \u{201C}\(Self.preview($0))\u{201D}" } ?? ""
            return "Open quicklink \u{2018}\(Self.preview(name))\u{2019}" + query
        case "quicklinks.create":
            let draft = call.object(0)
            return "Create quicklink \u{2018}\(Self.preview(draft["name"]?.stringValue ?? ""))\u{2019} for "
                + Self.preview(draft["link"]?.stringValue ?? "")
        case "windows.setBounds", "windows.setWindowBounds":
            let id = method == "windows.setBounds" ? call.string(0) : call.object(0)["id"]?.stringValue
            let window = try services.windows().first { $0.id == id }
            let label = window.map { Self.preview("\($0.app) \u{2014} \($0.title)") } ?? "a window"
            return "Move and resize \(label)"
        case "windows.applyLayout":
            return "Apply window layout \u{2018}\(Self.preview(call.string(0) ?? ""))\u{2019}"
        case "windows.runCommand":
            return "Run \u{2018}\(Self.preview(call.string(0) ?? ""))\u{2019} on the front window"
        default:
            return nil
        }
    }

    /// A clipped preview states the whole length, so a write cannot hide its tail past the cut.
    private static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > 120 else { return flat }
        return String(flat.prefix(120)) + "\u{2026} (\(text.count) characters)"
    }

    // MARK: - Serving

    private func serve(
        _ method: String, call: Call, name: String, services: ExtensionBestcastServices,
        grants: ExtensionGrantStore
    ) async throws -> Any? {
        switch method {
        case "clipboardHistory.search":
            let options = call.object(1)
            let limit = options["limit"]?.doubleValue.map { max(1, min(Int($0), 200)) } ?? 20
            return services.clipboardSearch(
                call.string(0) ?? "", limit: limit, kind: options["kind"]?.stringValue)
        case "clipboardHistory.read":
            return try services.clipboardRead(id: call.string(0) ?? "")
        case "snippets.list":
            return services.snippets(matching: nil)
        case "snippets.search":
            return services.snippets(matching: call.string(0) ?? "")
        case "snippets.create":
            let draft = call.object(0)
            let id = try await services.createSnippet(
                name: draft["name"]?.stringValue ?? "", text: draft["text"]?.stringValue ?? "",
                keyword: draft["keyword"]?.stringValue)
            return ["id": id]
        case "snippets.expand":
            let values = call.object(1).compactMapValues(\.stringValue)
            let clipboard =
                grants.grant(for: name, capability: .clipboardHistoryRead) != nil
                && services.isFeatureEnabled(.clipboardHistoryRead)
                && services.manifest(extension: name)?.declaredCapabilities
                    .contains(.clipboardHistoryRead) == true
            return try services.expandSnippet(
                call.string(0) ?? "", arguments: values, clipboardHistory: clipboard)
        case "snippets.openEditor":
            let draft = call.object(0)
            services.openSnippetEditor(
                name: draft["name"]?.stringValue, text: draft["text"]?.stringValue ?? "",
                keyword: draft["keyword"]?.stringValue)
            return nil
        case "notes.read":
            return try await services.readNote()
        case "notes.append":
            try await services.appendToNote(call.string(0) ?? "")
            return nil
        case "quicklinks.list":
            return services.quicklinks()
        case "quicklinks.open":
            try await services.openQuicklink(id: call.string(0) ?? "", query: call.string(1))
            return nil
        case "quicklinks.create":
            let draft = call.object(0)
            let id = try services.createQuicklink(
                name: draft["name"]?.stringValue ?? "", link: draft["link"]?.stringValue ?? "",
                application: Self.application(draft["application"]))
            return ["id": id]
        case "quicklinks.openEditor":
            let draft = call.object(0)
            services.openQuicklinkEditor(
                name: draft["name"]?.stringValue, link: draft["link"]?.stringValue ?? "",
                application: Self.application(draft["application"]))
            return nil
        default:
            return try await serveRest(method, call: call, services: services)
        }
    }

    private func serveRest(
        _ method: String, call: Call, services: ExtensionBestcastServices
    ) async throws -> Any? {
        switch method {
        case "windows.list":
            return try services.windows().map(Self.bestcastWindow)
        case "windows.setBounds":
            let id = call.string(0) ?? ""
            guard let current = try services.windows().first(where: { $0.id == id }) else {
                throw BestcastServiceError(message: "No window has the id \(id).")
            }
            let bounds = call.object(1)
            let frame = CGRect(
                x: bounds["x"]?.doubleValue ?? current.frame.minX,
                y: bounds["y"]?.doubleValue ?? current.frame.minY,
                width: bounds["width"]?.doubleValue ?? current.frame.width,
                height: bounds["height"]?.doubleValue ?? current.frame.height)
            try services.setWindowFrame(id: id, frame: frame)
            return nil
        case "windows.applyLayout":
            try services.applyWindowLayout(named: call.string(0) ?? "")
            return nil
        case "windows.runCommand":
            try services.runWindowCommand(call.string(0) ?? "")
            return nil
        case "windows.active":
            guard let window = try services.windows().first(where: \.focused) else {
                throw BestcastServiceError(message: "No active window.")
            }
            return Self.raycastWindow(window)
        case "windows.onActiveDesktop":
            let active = services.desktops().first(where: \.active)?.id
            return try services.windows().filter { $0.desktopID == active }.map(Self.raycastWindow)
        case "windows.desktops":
            return services.desktops().map { desktop in
                [
                    "id": desktop.id, "active": desktop.active, "screenId": desktop.id,
                    "size": ["width": desktop.size.width, "height": desktop.size.height],
                    "type": "User"
                ] as [String: Any]
            }
        case "windows.setWindowBounds":
            return try setRaycastBounds(call.object(0), services: services)
        case "calendar.events":
            let range = call.object(0)
            guard let start = Self.date(range["from"]), let end = Self.date(range["to"]), start <= end
            else { throw BestcastServiceError(message: "calendar.events needs `from` and `to` dates.") }
            return try services.calendarEvents(from: start, to: end)
        case "calculator.evaluate":
            return services.evaluate(call.string(0) ?? "")
        case "ai.openQuickAI":
            services.openQuickAI(prompt: call.string(0))
            return nil
        case "ai.openChat":
            let options = call.object(0)
            services.openChat(
                prompt: options["prompt"]?.stringValue, mention: options["mention"]?.stringValue)
            return nil
        case "ai.tools.list":
            return services.aiTools()
        case "ai.tools.call":
            return try await services.callAITool(name: call.string(0) ?? "", input: call.string(1) ?? "{}")
        default:
            throw Self.unknown(method)
        }
    }

    private func setRaycastBounds(
        _ options: [String: RenderValue], services: ExtensionBestcastServices
    ) throws -> Any? {
        let id = options["id"]?.stringValue ?? ""
        if options["bounds"]?.stringValue == "fullscreen" {
            try services.setWindowFullScreen(id: id)
            return nil
        }
        guard let current = try services.windows().first(where: { $0.id == id }) else {
            throw BestcastServiceError(message: "No window has the id \(id).")
        }
        let bounds = options["bounds"]?.objectValue ?? [:]
        let position = bounds["position"]?.objectValue ?? [:]
        let size = bounds["size"]?.objectValue ?? [:]
        let frame = CGRect(
            x: position["x"]?.doubleValue ?? current.frame.minX,
            y: position["y"]?.doubleValue ?? current.frame.minY,
            width: size["width"]?.doubleValue ?? current.frame.width,
            height: size["height"]?.doubleValue ?? current.frame.height)
        try services.setWindowFrame(id: id, frame: frame)
        return nil
    }

    // MARK: - Shapes

    private static func bestcastWindow(_ window: ExtensionWindowInfo) -> [String: Any] {
        [
            "id": window.id, "app": window.app, "bundleId": window.bundleID, "title": window.title,
            "bounds": [
                "x": window.frame.minX, "y": window.frame.minY,
                "width": window.frame.width, "height": window.frame.height
            ],
            "focused": window.focused, "desktopId": window.desktopID
        ]
    }

    private static func raycastWindow(_ window: ExtensionWindowInfo) -> [String: Any] {
        [
            "id": window.id, "active": window.focused, "desktopId": window.desktopID,
            "bounds": [
                "position": ["x": window.frame.minX, "y": window.frame.minY],
                "size": ["width": window.frame.width, "height": window.frame.height]
            ],
            "positionable": window.positionable, "resizable": window.resizable,
            "fullScreenSettable": window.resizable,
            "application": ["name": window.app, "bundleId": window.bundleID, "path": ""]
        ]
    }

    private static func date(_ value: RenderValue?) -> Date? {
        value?.dateValue ?? value?.stringValue.flatMap(RenderValue.parseDate)
    }

    /// Raycast passes an app as a name, a path, a bundle id or an `Application` object.
    private static func application(_ value: RenderValue?) -> String? {
        if let object = value?.objectValue {
            return object["bundleId"]?.stringValue ?? object["path"]?.stringValue
                ?? object["name"]?.stringValue
        }
        return value?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func unknown(_ method: String) -> BestcastServiceError {
        BestcastServiceError(message: "Unknown host call 'bestcast.\(method)'.")
    }

    private struct Call {
        let arguments: [RenderValue]

        func string(_ index: Int) -> String? {
            index < arguments.count ? arguments[index].stringValue : nil
        }

        func object(_ index: Int) -> [String: RenderValue] {
            index < arguments.count ? arguments[index].objectValue ?? [:] : [:]
        }
    }
}
