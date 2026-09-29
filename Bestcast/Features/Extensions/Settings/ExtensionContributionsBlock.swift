import SwiftUI

/// The post-install dialog's toggles, kept here for good; rows only, for the enclosing `Grid`.
struct ExtensionContributionsBlock: View {
    let installed: InstalledExtension
    @Environment(ExtensionSearchCoordinator.self) private var coordinator

    private var items: [ExtensionContributionConsentState.Item] {
        coordinator.contributions(of: installed).items.map {
            ExtensionContributionConsentState.Item(kind: $0.kind, name: $0.name, title: $0.title)
        }
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            GridRow {
                Divider()
                    .gridCellColumns(2)
            }
            GridRow {
                Text("Contributions")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .gridCellColumns(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Spacing.xs)
            }
            ForEach(items) { item in
                row(item)
            }
        }
    }

    private func row(_ item: ExtensionContributionConsentState.Item) -> some View {
        let name = installed.manifest.name
        return GridRow(alignment: .center) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(item.title)
                Text(item.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.kind == .search {
                    ExtensionSearchConsentWarning()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridColumnAlignment(.leading)
            Toggle(
                "",
                isOn: Binding(
                    get: { coordinator.isEnabled(name, item.kind, item.name) },
                    set: { coordinator.setEnabled($0, name, item.kind, item.name) })
            )
            .labelsHidden()
            .accessibilityLabel(item.title)
            .frame(width: 200, alignment: .trailing)
            .gridColumnAlignment(.trailing)
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}
