import SwiftUI

/// The rows ⌘K disabled, each with its way back; custom commands and quicklinks use their panes.
struct DisabledCommandsList: View {
    @Environment(VisibilityStore.self) private var visibility
    @Environment(AppIndex.self) private var appIndex

    var body: some View {
        let keys = visibility.disabledItemKeys.sorted()
        LabeledContent {
            if keys.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
        } label: {
            SettingsRowTitle(.generalSearch, "Disabled commands")
            Text("Off in search, hotkeys and deeplinks until enabled here.")
        }
        ForEach(keys, id: \.self) { key in
            DisabledCommandRow(entry: appIndex.apps.first { $0.preferenceKey == key }, key: key) {
                visibility.setDisabled(false, key: key)
            }
        }
    }
}

/// An entry whose feature is off is out of the index, so its stored key stands in for the name.
private struct DisabledCommandRow: View {
    let entry: AppEntry?
    let key: String
    let onEnable: () -> Void

    var body: some View {
        let name = entry?.name ?? key
        LabeledContent {
            Button("Enable", action: onEnable)
                .accessibilityLabel("Enable \(name)")
        } label: {
            Label {
                Text(name).lineLimit(1)
            } icon: {
                if let entry {
                    AppIconView(app: entry)
                        .frame(
                            width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
                }
            }
        }
    }
}
