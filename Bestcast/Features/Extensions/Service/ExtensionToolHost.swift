import AppKit

/// The host an AI tool's runtime reaches: user-initiated, since a sent message started it.
@MainActor
final class ExtensionToolHost: ExtensionHostContext {
    let owner: InstalledExtension
    let storage: ExtensionStorage
    private weak var manager: ExtensionManager?
    private weak var coordinator: ExtensionCoordinator?
    private let oauth = ExtensionOAuthSession()

    init(
        owner: InstalledExtension, storage: ExtensionStorage, manager: ExtensionManager,
        coordinator: ExtensionCoordinator
    ) {
        self.owner = owner
        self.storage = storage
        self.manager = manager
        self.coordinator = coordinator
    }

    var activeExtensionName: String? { owner.manifest.name }
    var activeLaunchType: ExtensionLaunchType { .userInitiated }
    var pasteTarget: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
    var applicationURLs: [URL] { coordinator?.applicationURLs ?? [] }

    func stop() { oauth.cancel() }
    func closeMainWindow(clearRootSearch: Bool) {}
    func reopenPalette() { coordinator?.reopenPalette(hasRunningCommand: false) }
    func popToRoot() {}
    func clearSearchBar() {}
    func openPreferences(scope: String) { coordinator?.showExtensionSettings(for: owner) }
    func updateCommandMetadata(subtitle: String?) {}
    func present(toast: ExtensionToast) -> Int { 0 }
    func update(toast id: Int, with toast: ExtensionToast) {}
    func hide(toast id: Int) {}
    func showHUD(_ text: String) { coordinator?.showHUD(text) }

    func confirmAlert(_ alert: ExtensionAlert) async -> Bool {
        await coordinator?.confirmExtensionAlert(alert) ?? false
    }

    func openWithPicker(path: String) async { await manager?.openWithPicker(path: path) }

    func launch(
        command: String, extensionName: String?, arguments: [String: String],
        fallbackText: String?, launchType: ExtensionLaunchType, launchContext: [String: RenderValue]
    ) throws {
        try manager?.launch(
            command: command, extensionName: extensionName ?? owner.manifest.name,
            arguments: arguments, fallbackText: fallbackText, launchType: launchType,
            launchContext: launchContext)
    }

    func launch(_ link: ExtensionDeepLink) throws { try manager?.launch(link) }

    func authorizeOAuth(options: ExtensionOAuthAuthorizeOptions) async throws -> ExtensionOAuthAuthorizeResult
    {
        try await oauth.authorize(options: options)
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
