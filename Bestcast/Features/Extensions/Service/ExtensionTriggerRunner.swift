import AppKit
import Foundation

/// Who a one-shot run answers to: the exports already on its stack, and where its feedback goes.
struct ExtensionRunScope {
    var chain: [String] = []
    /// Only a run a person started may ask them to approve a cross-extension call.
    var canPrompt = true
    /// Nil shows a toast or HUD as a plain HUD; a trigger passes its throttled one.
    var feedback: (@MainActor (String) -> Void)?
}

/// Runs one export or no-view command in a fresh runtime, one call, then tears it down.
@MainActor
final class ExtensionTriggerRunner {
    /// A trigger step that needs longer is almost certainly waiting on something that never comes.
    static let callTimeout: Duration = .seconds(60)

    weak var manager: ExtensionManager?
    weak var engine: ExtensionTriggerEngine?

    /// A file's default export, handed `input` as its only argument.
    func runExport(
        _ path: String, of owner: InstalledExtension, input: JSONValue, scope: ExtensionRunScope
    ) async -> Result<JSONValue, ExtensionTriggerFailure> {
        guard ExtensionExportPath.isSafe(path), let file = containedFile(path, in: owner) else {
            return .failure(ExtensionTriggerFailure("\(path) is not a file inside the extension."))
        }
        return await runOnce(
            file: file, of: owner, commandName: owner.manifest.name, launchType: .background,
            launchContext: [:], input: input, scope: scope)
    }

    /// A no-view command as a trigger or an awaited `launchCommand` runs it: its props as input.
    func runCommand(
        _ command: ExtensionCommand, of owner: InstalledExtension, props: JSONValue,
        scope: ExtensionRunScope
    ) async -> Result<JSONValue, ExtensionTriggerFailure> {
        guard command.mode == .noView else {
            return .failure(ExtensionTriggerFailure("\(command.title) is not a no-view command."))
        }
        guard let file = owner.bundleURL(for: command) else {
            return .failure(ExtensionTriggerFailure("\(command.title) is not built."))
        }
        let fields = props.objectValue ?? [:]
        let launchType: ExtensionLaunchType =
            fields["launchType"]?.stringValue == ExtensionLaunchType.userInitiated.rawValue
            ? .userInitiated : .background
        let launchContext = (fields["launchContext"]?.objectValue ?? [:]).mapValues {
            RenderValue(json: $0.jsonObject)
        }
        return await runOnce(
            file: file, of: owner, commandName: command.name, launchType: launchType,
            launchContext: launchContext, input: props, scope: scope)
    }

    /// Resolved through symlinks, so a link inside the extension cannot point outside it.
    private func containedFile(_ path: String, in owner: InstalledExtension) -> URL? {
        let root = owner.directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let file = owner.directory.appendingPathComponent(path).resolvingSymlinksInPath()
            .standardizedFileURL
        guard file.path.hasPrefix(root), FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        return file
    }

    private func runOnce(
        file: URL, of owner: InstalledExtension, commandName: String,
        launchType: ExtensionLaunchType, launchContext: [String: RenderValue], input: JSONValue,
        scope: ExtensionRunScope
    ) async -> Result<JSONValue, ExtensionTriggerFailure> {
        guard let manager, manager.isEnabled, let engine, let coordinator = manager.coordinator else {
            return .failure(ExtensionTriggerFailure("Extensions are turned off."))
        }
        let storage = manager.storage
        let schemas = owner.manifest.preferences
        let missing = storage.missingRequiredPreferences(extension: owner.manifest.name, schemas: schemas)
        guard missing.isEmpty else {
            return .failure(ExtensionTriggerFailure("\(owner.title) needs its preferences set first."))
        }
        let support = ExtensionCatalog.supportPath(for: owner.manifest.name)
        let code: String
        do {
            code = try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                return try String(contentsOf: file, encoding: .utf8)
            }.value
        } catch {
            return .failure(ExtensionTriggerFailure("Couldn't read \(file.lastPathComponent)."))
        }
        let host = ExtensionTriggerHost(
            owner: owner, storage: storage, manager: manager, coordinator: coordinator,
            commandName: owner.command(named: commandName)?.name, feedback: scope.feedback)
        let bridge = manager.bridge.scoped(to: host)
        bridge.compose = ExtensionComposeBridge(engine: engine, scope: scope)
        let session = ExtensionToolSession(
            runtime: ExtensionRuntime(hostAPI: bridge, priority: .utility)
        ) { [storage] in
            host.stop()
            bridge.sessionEnded()
            bridge.context = nil
            storage.flush()
        }
        defer { session.end() }
        let context = ExtensionLaunchContext(
            extensionName: owner.manifest.name, extensionTitle: owner.title,
            commandName: commandName, commandMode: .noView, assetsPath: owner.assetsPath,
            supportPath: support.path,
            preferences: storage.resolvedPreferences(extension: owner.manifest.name, schemas: schemas),
            caches: storage.caches(extension: owner.manifest.name), arguments: [:],
            fallbackText: nil, launchType: launchType,
            isDarkAppearance: NSApp.effectiveAppearance.isDark,
            canAccessAI: bridge.ai.canAccess(), launchContext: launchContext,
            isDevelopment: owner.isDevelopment)
        do {
            try await session.load(code: code, file: file, context: context, support: support)
        } catch {
            return .failure(ExtensionTriggerFailure(error.localizedDescription))
        }
        switch await session.call(
            "default", input: ExtensionTriggerPolicy.json(input), timeout: Self.callTimeout)
        {
        case .returned(.value(let value)): return .success(value)
        case .returned(.missing):
            return .failure(ExtensionTriggerFailure("\(file.lastPathComponent) has no default export."))
        case .failed(let message): return .failure(ExtensionTriggerFailure(message))
        }
    }
}

/// A one-shot run's host: no palette, so toasts become HUDs and nothing opens a window.
@MainActor
private final class ExtensionTriggerHost: ExtensionHostContext {
    let owner: InstalledExtension
    let storage: ExtensionStorage
    private weak var manager: ExtensionManager?
    private weak var coordinator: ExtensionCoordinator?
    private let commandName: String?
    private let feedback: (@MainActor (String) -> Void)?

    init(
        owner: InstalledExtension, storage: ExtensionStorage, manager: ExtensionManager,
        coordinator: ExtensionCoordinator, commandName: String?,
        feedback: (@MainActor (String) -> Void)?
    ) {
        self.owner = owner
        self.storage = storage
        self.manager = manager
        self.coordinator = coordinator
        self.commandName = commandName
        self.feedback = feedback
    }

    var activeExtensionName: String? { owner.manifest.name }
    /// The bridge drops feedback for a background run; this host turns it into a throttled HUD.
    var activeLaunchType: ExtensionLaunchType { .userInitiated }
    var pasteTarget: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
    var applicationURLs: [URL] { coordinator?.applicationURLs ?? [] }
    var isUnattended: Bool { true }

    func stop() {}
    func closeMainWindow(clearRootSearch: Bool) {}
    func reopenPalette() {}
    func popToRoot() {}
    func clearSearchBar() {}
    func openPreferences(scope: String) {}

    func updateCommandMetadata(subtitle: String?) {
        guard let commandName else { return }
        manager?.updateCommandMetadata(
            subtitle: subtitle,
            for: ExtensionCommandRef(extensionName: owner.manifest.name, commandName: commandName))
    }

    func present(toast: ExtensionToast) -> Int {
        guard toast.style != .animated else { return 0 }
        showHUD([toast.title, toast.message].compactMap { $0 }.joined(separator: " — "))
        return 0
    }

    func update(toast id: Int, with toast: ExtensionToast) {}
    func hide(toast id: Int) {}

    func showHUD(_ text: String) {
        guard !text.isEmpty else { return }
        if let feedback { feedback(text) } else { coordinator?.showHUD(text) }
    }

    func confirmAlert(_ alert: ExtensionAlert) async -> Bool { false }
    func openWithPicker(path: String) async {}

    /// Only its own commands, in the background: no UI, and no reaching past compose's approvals.
    func launch(
        command: String, extensionName: String?, arguments: [String: String],
        fallbackText: String?, launchType: ExtensionLaunchType, launchContext: [String: RenderValue]
    ) throws {
        guard launchType == .background else {
            throw ExtensionLaunchError.unsupported("A trigger can only launch in the background.")
        }
        guard (extensionName ?? owner.manifest.name) == owner.manifest.name else {
            throw ExtensionLaunchError.unsupported("An automation can only launch its own commands.")
        }
        try manager?.launch(
            command: command, extensionName: owner.manifest.name,
            arguments: arguments, fallbackText: fallbackText, launchType: launchType,
            launchContext: launchContext)
    }

    func launch(_ link: ExtensionDeepLink) throws {
        throw ExtensionLaunchError.unsupported("A trigger cannot open links into Bestcast.")
    }

    /// Signing in opens a browser, which only a command the person opened may do.
    func authorizeOAuth(options: ExtensionOAuthAuthorizeOptions) async throws -> ExtensionOAuthAuthorizeResult
    {
        throw ExtensionLaunchError.unsupported("Signing in from an automation")
    }

    func getOAuthTokens(providerId: String) -> String? {
        ExtensionOAuthKeychain.getTokens(extensionName: owner.manifest.name, providerId: providerId)
    }

    func setOAuthTokens(providerId: String, tokens: String) {
        ExtensionOAuthKeychain.setTokens(tokens, extensionName: owner.manifest.name, providerId: providerId)
    }

    func removeOAuthTokens(providerId: String) {
        ExtensionOAuthKeychain.removeTokens(extensionName: owner.manifest.name, providerId: providerId)
    }
}
