import SwiftUI

/// Settings → AI → Passive AI: each helper's own switch, and the route answers take.
struct PassiveAISettingsSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AISettingsStore.self) private var settings
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        @Bindable var passive = settings.passive
        return Section {
            AIModelSelectionRows(
                selection: passive.model,
                inheritedTitle: "On-Device (Apple Intelligence)",
                select: choose,
                modelLabel: {
                    SettingsRowTitle(.aiPassive, "Passive AI model")
                    Text("Clipboard summaries stay on this Mac whatever is picked.")
                },
                effortLabel: {
                    Text("Reasoning effort")
                }
            )
            Toggle(isOn: $passive.inlineAnswers) {
                SettingsRowTitle(.aiPassive, "Answers in root search")
                Text("A question typed into the launcher gets a short answer after a pause.")
            }
            Toggle(isOn: $passive.selectionSuggestions) {
                SettingsRowTitle(.aiPassive, "Selected text suggestions")
                Text(
                    appSettings.quickActionsEnabled
                        ? "Opening the launcher over selected text offers actions for it."
                        : "Needs Quick Actions, whose Accessibility access reads the selection.")
            }
            .settingsEnabled(appSettings.quickActionsEnabled)
            Toggle(isOn: $passive.clipboardIntelligence) {
                SettingsRowTitle(.aiPassive, "Clipboard intelligence")
                Text("Tags copied text by kind and summarizes long clips, on this Mac only.")
            }
        } header: {
            SettingsSectionHeader(.aiPassive)
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        if !settings.passive.isOnDevice {
            return "Root search questions go to the selected provider. Nothing else leaves this Mac."
        }
        return AppleIntelligenceProvider.status().isAvailable
            ? "Everything runs on Apple Intelligence. Nothing leaves this Mac."
            : "Answers and summaries need Apple Intelligence; kinds and suggestions do not."
    }

    /// Answers carry what is typed, so moving them off the Mac is confirmed rather than assumed.
    private func choose(_ model: AIModelSelection?) {
        guard let model, !model.isOnDevice else {
            settings.passive.model = model
            return
        }
        Task {
            guard
                await core.confirm(
                    title: "Send root search questions to this provider?",
                    message:
                        "A question typed into the launcher is sent after a short pause, before "
                        + "you press Return. Selections and clipboard text stay on this Mac.",
                    symbol: "network", confirmTitle: "Use Provider", tone: .neutral,
                    confirmRole: .standard)
            else { return }
            settings.passive.model = model
        }
    }
}
