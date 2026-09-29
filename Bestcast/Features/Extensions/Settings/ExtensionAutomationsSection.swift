import SwiftUI

/// Settings › Extensions › Automations: the master pause, and every trigger that is on or failing.
struct ExtensionAutomationsSection: View {
    @Environment(AppCore.self) private var core

    private struct Row: Identifiable {
        let id: String
        let title: String
        let owner: InstalledExtension
        let trigger: ExtensionTrigger
        let state: ExtensionTriggerState
    }

    var body: some View {
        let engine = core.extensions.triggers
        let store = engine.store
        Section {
            SettingsRow(
                title: "Pause automations",
                subtitle: "Stops every trigger and cross-extension call.",
                anchor: .extensionsAutomations
            ) {
                Toggle(
                    "Pause automations",
                    isOn: Binding(get: { store.isPaused }, set: { store.isPaused = $0 })
                )
                .labelsHidden()
            }
            ForEach(rows(store)) { row in
                SettingsRow(
                    title: row.title, subtitle: row.state.lastError ?? row.trigger.event.title,
                    subtitleLineLimit: 2
                ) {
                    if row.state.autoDisabled {
                        Button("Turn On") {
                            Task { await engine.setEnabled(true, trigger: row.trigger, of: row.owner) }
                        }
                        .accessibilityLabel("Turn on \(row.title)")
                    }
                }
            }
        } header: {
            SettingsSectionHeader(.extensionsAutomations)
        }
    }

    private func rows(_ store: ExtensionTriggerStore) -> [Row] {
        core.extensions.installed.flatMap { owner in
            owner.manifest.triggers.compactMap { trigger -> Row? in
                let state = store.state(extension: owner.manifest.name, trigger: trigger.name)
                guard ExtensionTriggerPolicy.isOn(trigger, state: state) || state.lastError != nil
                    || state.autoDisabled
                else { return nil }
                return Row(
                    id: ExtensionTriggerEngine.key(extension: owner.manifest.name, trigger: trigger.name),
                    title: "\(owner.title): \(trigger.title)", owner: owner, trigger: trigger,
                    state: state)
            }
        }
    }
}
