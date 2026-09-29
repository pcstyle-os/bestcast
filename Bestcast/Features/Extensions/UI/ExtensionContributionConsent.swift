import SwiftUI

/// The post-install opt-in; reference semantics let the caller read the choices back.
@MainActor
@Observable
final class ExtensionContributionConsentState {
    struct Item: Identifiable, Hashable {
        let kind: ExtensionContributionKind
        let name: String
        let title: String

        var id: String { kind.rawValue + ":" + name }
    }

    let extensionName: String
    let items: [Item]
    private var chosen: Set<String>

    init(
        extensionName: String,
        items: [(kind: ExtensionContributionKind, name: String, title: String)],
        isEnabled: (ExtensionContributionKind, String) -> Bool
    ) {
        self.extensionName = extensionName
        let items = items.map { Item(kind: $0.kind, name: $0.name, title: $0.title) }
        self.items = items
        chosen = Set(items.filter { isEnabled($0.kind, $0.name) }.map(\.id))
    }

    func isOn(_ item: Item) -> Bool { chosen.contains(item.id) }

    func set(_ enabled: Bool, _ item: Item) {
        if enabled {
            chosen.insert(item.id)
        } else {
            chosen.remove(item.id)
        }
    }

    /// Grouped by kind, in the order the kinds are declared.
    var groups: [(kind: ExtensionContributionKind, items: [Item])] {
        ExtensionContributionKind.allCases.compactMap { kind in
            let items = items.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }
}

/// A toggle per contribution, every one off until switched on here or in Settings.
struct ExtensionContributionConsentView: View {
    @Environment(\.metrics) private var metrics
    let state: ExtensionContributionConsentState

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.lg) {
            ForEach(state.groups, id: \.kind) { group in
                VStack(alignment: .leading, spacing: metrics.spacing.sm) {
                    Text(group.kind.title)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    ForEach(group.items) { item in
                        Toggle(
                            item.title,
                            isOn: Binding(get: { state.isOn(item) }, set: { state.set($0, item) })
                        )
                        .toggleStyle(.checkbox)
                    }
                    if group.kind == .search {
                        ExtensionSearchConsentWarning()
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(group.kind.title)
            }
        }
    }
}

/// Said wherever a search provider can be switched on: it sees every query, as it is typed.
struct ExtensionSearchConsentWarning: View {
    @Environment(\.metrics) private var metrics

    var body: some View {
        Label {
            Text(
                "Root search sends everything you type in the launcher to this extension, "
                    + "and runs its code as you type.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.warning)
        }
        .font(.caption)
        .foregroundStyle(Theme.Colors.textSecondary)
    }
}
