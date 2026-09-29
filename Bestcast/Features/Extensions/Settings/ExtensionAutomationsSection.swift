import SwiftUI

/// Settings › Extensions › Automations: the master pause, and every trigger that stopped on an error.
struct ExtensionAutomationsSection: View {
    @Environment(AppCore.self) private var core

    private struct Problem: Identifiable {
        let id: String
        let title: String
        let owner: String
        let trigger: String
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
            ForEach(problems(store)) { problem in
                SettingsRow(
                    title: problem.title, subtitle: problem.state.lastError, subtitleLineLimit: 2
                ) {
                    if problem.state.autoDisabled {
                        Button("Turn On") {
                            engine.setEnabled(true, trigger: problem.trigger, of: problem.owner)
                        }
                    }
                }
            }
        } header: {
            SettingsSectionHeader(.extensionsAutomations)
        }
    }

    private func problems(_ store: ExtensionTriggerStore) -> [Problem] {
        core.extensions.installed.flatMap { owner in
            owner.manifest.triggers.compactMap { trigger -> Problem? in
                let state = store.state(extension: owner.manifest.name, trigger: trigger.name)
                guard state.lastError != nil || state.autoDisabled else { return nil }
                return Problem(
                    id: ExtensionTriggerEngine.key(extension: owner.manifest.name, trigger: trigger.name),
                    title: "\(owner.title): \(trigger.title)", owner: owner.manifest.name,
                    trigger: trigger.name, state: state)
            }
        }
    }
}
