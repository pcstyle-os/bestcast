import SwiftUI

/// Settings › Extensions › Permissions: what each extension may reach through `@bestcast/api`.
struct ExtensionPermissionsSection: View {
    @Environment(AppCore.self) private var core

    private var grants: ExtensionGrantStore { core.extensions.grants }

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("No extension uses the Bestcast API.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.name) { entry in
                    SettingsRow(title: entry.title, subtitle: summary(of: entry)) {
                        ExtensionSettingsIcon(systemName: "puzzlepiece.extension")
                    } trailing: {
                        Button("Revoke All") { grants.revokeAll(extension: entry.name) }
                            .disabled(grants.grants(for: entry.name).isEmpty)
                            .accessibilityLabel("Revoke all for \(entry.title)")
                    }
                    ForEach(capabilities(of: entry), id: \.self) { capability in
                        capabilityRow(capability, of: entry)
                    }
                }
            }
        } header: {
            SettingsSectionHeader(.extensionsPermissions)
        }
    }

    private struct Entry {
        let name: String
        let title: String
        let declared: Set<ExtensionCapability>
    }

    /// Installed extensions that declare anything, plus any that were granted without declaring.
    private var entries: [Entry] {
        let installed = core.extensions.installed
        let named = Set(installed.map(\.manifest.name))
        let declaring = installed.compactMap { item -> Entry? in
            let declared = item.manifest.declaredCapabilities
            guard !declared.isEmpty || !grants.grants(for: item.manifest.name).isEmpty else { return nil }
            return Entry(name: item.manifest.name, title: item.title, declared: declared)
        }
        let orphans = grants.extensionNames.filter { !named.contains($0) }.map {
            Entry(name: $0, title: $0, declared: [])
        }
        return (declaring + orphans).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func capabilities(of entry: Entry) -> [ExtensionCapability] {
        let granted = Set(grants.grants(for: entry.name).map(\.capability))
        return ExtensionCapability.allCases.filter { entry.declared.contains($0) || granted.contains($0) }
    }

    private func summary(of entry: Entry) -> String {
        let count = grants.grants(for: entry.name).count
        return count == 0 ? "Nothing allowed yet" : "\(count) allowed"
    }

    private func capabilityRow(_ capability: ExtensionCapability, of entry: Entry) -> some View {
        let grant = grants.grant(for: entry.name, capability: capability)
        return SettingsRow(title: Self.sentence(capability.title), subtitle: status(capability, grant)) {
            if grant != nil {
                Button("Revoke") { grants.revoke(capability, extension: entry.name) }
                    .accessibilityLabel("Revoke \(capability.title) for \(entry.title)")
            }
        }
        .padding(.leading, SettingsListMetrics.iconSize + Theme.Spacing.lg)
    }

    private func status(_ capability: ExtensionCapability, _ grant: ExtensionGrant?) -> String {
        guard let grant else {
            if !capability.needsPrompt { return "Allowed by declaring it" }
            return capability.isWrite ? "Asks every time" : "Asks on first use"
        }
        let when = grant.grantedAt.formatted(date: .abbreviated, time: .shortened)
        var parts = [capability.isWrite && grant.always ? "Always allowed since \(when)" : "Allowed \(when)"]
        if let used = grant.lastUsedAt {
            parts.append("last used \(used.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private static func sentence(_ phrase: String) -> String {
        phrase.prefix(1).uppercased() + phrase.dropFirst()
    }
}
