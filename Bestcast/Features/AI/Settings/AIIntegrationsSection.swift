import SwiftUI

/// Settings → AI → Integrations: which of Bestcast's own features a model may use as tools.
struct AIIntegrationsSection: View {
    @Environment(AISettingsStore.self) private var settings

    var body: some View {
        Section {
            ForEach(BuiltInIntegration.allCases) { integration in
                Toggle(isOn: binding(integration)) {
                    Label {
                        Text(integration.title)
                        Text(integration.summary)
                    } icon: {
                        Image(systemName: integration.symbol)
                            .foregroundStyle(.primary)
                    }
                }
            }
        } header: {
            SettingsSectionHeader(.aiIntegrations)
        } footer: {
            Text(
                "Type @ in a chat to address one. Anything that copies, opens, moves or saves "
                    + "asks every time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(_ integration: BuiltInIntegration) -> Binding<Bool> {
        Binding(
            get: { settings.integrations.contains(integration) },
            set: { isOn in
                if isOn {
                    settings.integrations.insert(integration)
                } else {
                    settings.integrations.remove(integration)
                }
            })
    }
}
