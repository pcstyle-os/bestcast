import SwiftUI

/// Actions menu for a launcher app, from right-click or the Actions pill.
@MainActor
enum AppActionsMenu {
    /// Resolved by the screen that owns the visible order; every row runs its chord's call.
    @MainActor
    struct FavoriteActions {
        let isFavorite: Bool
        let canMoveUp: Bool
        let canMoveDown: Bool
        let toggle: () -> Void
        let move: (Int) -> Void
    }

    static func content(
        app: AppEntry, searchQuery: String, core: AppCore, running: Bool,
        favorites: FavoriteActions, onResetRanking: @escaping () -> Void,
        onTogglePin: @escaping () -> Void, onHideFromSearch: @escaping () -> Void,
        onDisable: @escaping () -> Void
    ) -> PopoverMenuContent {
        let primarySymbol =
            switch app.kind {
            case .application, .command, .extensionCommand: "list.dash.header.rectangle"
            default: "list.bullet.rectangle"
            }
        var items: [PopoverMenuItem] = [
            PopoverMenuItem(
                title: app.kind.descriptor.openVerb, systemImage: primarySymbol,
                shortcut: "↵"
            ) { core.launcherCoordinator.launch(app, searchQuery: searchQuery) }
        ]
        if app.canRevealInFinder {
            items.append(
                PopoverMenuItem(title: "Show in Finder", systemImage: "folder", shortcut: "⌘↵") {
                    core.launcherCoordinator.showInFinder(app)
                })
        }
        // A query-driven row lives only for its query, so no preference could outlive it.
        let isPersistent = !CommandCatalog.isQueryDriven(app)
        if isPersistent {
            items.append(
                PopoverMenuItem(
                    title: favorites.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: favorites.isFavorite ? "star.slash" : "star", startsSection: true,
                    shortcut: "⇧⌘F", action: favorites.toggle))
        }
        if favorites.canMoveUp {
            items.append(
                PopoverMenuItem(
                    title: "Move Favorite Up", systemImage: "arrow.up", shortcut: "⌥⌘↑"
                ) {
                    favorites.move(-1)
                })
        }
        if favorites.canMoveDown {
            items.append(
                PopoverMenuItem(
                    title: "Move Favorite Down", systemImage: "arrow.down", shortcut: "⌥⌘↓"
                ) {
                    favorites.move(1)
                })
        }
        if isPersistent {
            let pinned = core.favorites.isPinned(app)
            items.append(
                PopoverMenuItem(
                    title: pinned ? "Unpin from Search" : "Pin to Search",
                    systemImage: pinned ? "pin.slash" : "pin", shortcut: "⌘.", action: onTogglePin))
            items += personalization(app: app, core: core)
        }
        if core.launcherRanking.hasRanking(for: app.preferenceKey) {
            items.append(
                PopoverMenuItem(title: "Reset Ranking", systemImage: "arrow.counterclockwise") {
                    onResetRanking()
                })
        }
        if isPersistent, app.canHideFromSearch {
            items.append(
                PopoverMenuItem(
                    title: "Hide from Search", systemImage: "eye.slash", shortcut: "⇧⌘H",
                    action: onHideFromSearch))
        }
        if isPersistent, app.canDisable {
            items.append(
                PopoverMenuItem(
                    title: "Disable Command", systemImage: "nosign", shortcut: "⇧⌘D",
                    action: onDisable))
        }
        if isPersistent {
            items += copyItems(app: app, core: core)
        }
        if running, app.kind == .application {
            items.append(
                PopoverMenuItem(
                    title: "Restart Application", systemImage: "arrow.clockwise", startsSection: true,
                    shortcut: "⌘R"
                ) {
                    core.launcherCoordinator.restart(app)
                })
            items.append(
                PopoverMenuItem(
                    title: "Quit Application", systemImage: "power", shortcut: "⌃⇧Q",
                    isDestructive: true
                ) {
                    core.launcherCoordinator.quit(app)
                })
        }
        if app.kind == .application {
            items.append(
                PopoverMenuItem(
                    title: "Uninstall Application", systemImage: "trash", startsSection: true,
                    isDestructive: true
                ) {
                    core.uninstallCoordinator.beginUninstall(app)
                })
        }
        if app.kind == .extensionCommand {
            if core.extensions.isBackgroundSchedulable(for: app) {
                let enabled = core.extensions.isBackgroundEnabled(for: app)
                items.append(
                    PopoverMenuItem(
                        title: enabled ? "Disable Background Refresh" : "Enable Background Refresh",
                        systemImage: enabled ? "pause.circle" : "play.circle", startsSection: true
                    ) {
                        core.extensions.toggleBackgroundRefresh(for: app)
                    })
                if enabled {
                    items.append(
                        PopoverMenuItem(title: "Refresh Now", systemImage: "arrow.clockwise") {
                            core.extensions.refreshNow(app)
                        })
                }
            }
            items.append(
                PopoverMenuItem(
                    title: "Configure Extension", systemImage: "slider.horizontal.3", startsSection: true,
                    shortcut: "⇧⌘,"
                ) {
                    core.extensionCoordinator.showExtensionSettings(for: app)
                })
            items.append(
                PopoverMenuItem(title: "Uninstall Extension", systemImage: "trash", isDestructive: true) {
                    core.extensionCoordinator.confirmUninstall(app)
                })
        }
        items += core.extensionSearch.rowActions(for: app)
        return PopoverMenuContent(header: app.name, items: items)
    }

    /// An extension command's Configure Extension row, further down, already answers ⇧⌘,.
    private static func personalization(app: AppEntry, core: AppCore) -> [PopoverMenuItem] {
        var items: [PopoverMenuItem] = []
        if app.kind != .extensionCommand {
            items.append(
                PopoverMenuItem(
                    title: "Configure \(app.kind.descriptor.label)", systemImage: "gearshape",
                    shortcut: "⇧⌘,"
                ) {
                    core.launcherCoordinator.configure(app)
                })
        }
        if let action = app.hotKeyAction {
            let binding = core.hotKeys.binding(for: action)
            items.append(
                PopoverMenuItem(
                    title: binding == nil ? "Record Hotkey" : "Change Hotkey",
                    icon: .symbol("keyboard"), shortcut: "⌥⌘R",
                    detail: binding.map { $0.keycaps.joined() }
                ) {
                    core.launcherCoordinator.recordHotKey(for: app)
                })
        }
        let alias = core.aliases.alias(for: app.preferenceKey)
        items.append(
            PopoverMenuItem(
                title: alias == nil ? "Add Alias" : "Edit Alias", icon: .symbol("text.cursor"),
                shortcut: "⌥⌘A", detail: alias
            ) {
                core.launcherCoordinator.editAlias(for: app)
            })
        return items
    }

    /// Only an app has a bundle ID worth copying; a deeplink goes wherever a hotkey could.
    private static func copyItems(app: AppEntry, core: AppCore) -> [PopoverMenuItem] {
        var items = [
            PopoverMenuItem(
                title: "Copy Name", systemImage: "doc.on.doc", startsSection: true, shortcut: "⌥⌘C"
            ) {
                core.launcherCoordinator.copyName(app)
            }
        ]
        if app.kind == .application, app.bundleID != nil {
            items.append(
                PopoverMenuItem(title: "Copy Bundle ID", systemImage: "number", shortcut: "⇧⌘B") {
                    core.launcherCoordinator.copyBundleID(app)
                })
        }
        if app.hasDeepLink {
            items.append(
                PopoverMenuItem(title: "Copy Deeplink", systemImage: "link", shortcut: "⇧⌘C") {
                    core.launcherCoordinator.copyDeepLink(app)
                })
        }
        return items
    }
}
