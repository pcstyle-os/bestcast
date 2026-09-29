import SwiftUI

/// Linked extension folders and Script Command folders: code Bestcast reads in place, never copies.
struct ExtensionDevelopmentSection: View {
    @Environment(AppCore.self) private var core

    private var linked: [InstalledExtension] {
        core.extensions.installed.filter(\.isDevelopment)
    }

    private var scriptFolders: [URL] { core.extensions.sources.scriptFolders }

    var body: some View {
        Section {
            if linked.isEmpty {
                Text("No linked folders. Link one above to run an extension from its source.")
                    .foregroundStyle(.secondary)
            }
            ForEach(linked) { owner in
                SettingsRow(
                    title: owner.title,
                    subtitle: core.extensions.linkedFolder(of: owner)?.path ?? owner.directory.path
                ) {
                    Image(systemName: "hammer")
                        .foregroundStyle(.secondary)
                } trailing: {
                    Button("Reveal") { core.extensionDevelopment.reveal(owner) }
                    Button("Console") { core.extensionDevelopment.openConsole(for: owner) }
                    Button("Unlink…") { core.extensionCoordinator.confirmUninstall(owner) }
                }
            }
        } header: {
            SettingsSectionHeader(.extensionsDevelopment)
        }

        Section {
            ForEach(scriptFolders, id: \.self) { folder in
                SettingsRow(title: folder.lastPathComponent, subtitle: folder.path) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                } trailing: {
                    Button("Remove") { core.extensionDevelopment.removeScriptFolder(folder) }
                }
            }
            SettingsRow(
                title: "Add script folder",
                subtitle: "Raycast script commands, each one a launcher row.",
                anchor: .extensionsScriptCommands
            ) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
            } trailing: {
                Button("Add Folder…") { core.extensionDevelopment.addScriptFolder() }
            }
        } header: {
            SettingsSectionHeader(.extensionsScriptCommands)
        }

        if !scriptFolders.isEmpty {
            LauncherItemsSection(
                kind: .scriptCommand, anchor: .extensionsScripts, searchPrompt: "Search scripts…")
        }
    }
}
