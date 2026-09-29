import SwiftUI

/// Quick AI's own switches, and the presets it can be summoned with.
struct QuickAISettingsSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AISettingsStore.self) private var settings
    @State private var editor: QuickAIPresetEditRequest?

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.askAIFromRootSearch) {
                SettingsRowTitle(.aiQuickAI, "Ask AI from root search")
                Text("A query that reads as a question gets an Ask AI row first. ⌘↵ asks any query.")
            }
            Toggle(isOn: $settings.quickAIFollowUps) {
                SettingsRowTitle(.aiQuickAI, "Follow-up suggestions")
                Text("Up to three next questions under a reply. ⇥ picks one.")
            }
        } header: {
            SettingsSectionHeader(.aiQuickAI)
        }
        Section {
            if settings.quickAIPresets.isEmpty {
                Text("No presets yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.quickAIPresets) { preset in
                QuickAIPresetRow(
                    preset: preset,
                    onEdit: { editor = QuickAIPresetEditRequest(preset: preset, isNew: false) },
                    onDelete: { Task { await confirmDeletion(of: preset) } })
            }
            Button {
                editor = QuickAIPresetEditRequest(preset: QuickAIPreset(name: ""), isNew: true)
            } label: {
                SettingsRowTitle(.aiPresets, "Add Preset")
            }
            .settingsEditorPanel(item: $editor) { request in
                QuickAIPresetEditorPanel(
                    request: request,
                    onSave: { preset in
                        core.quickAICoordinator.savePreset(preset)
                        editor = nil
                    },
                    onCancel: { editor = nil })
            }
        } header: {
            SettingsSectionHeader(.aiPresets)
        } footer: {
            Text("A preset's prompt replaces the system prompt above for the chats it starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func confirmDeletion(of preset: QuickAIPreset) async {
        guard
            await core.confirm(
                title: "Delete “\(preset.name)”?",
                message: "Its global shortcut and launcher row will also be removed.",
                symbol: "sparkles", confirmTitle: "Delete")
        else { return }
        core.quickAICoordinator.deletePreset(id: preset.id)
    }
}

struct QuickAIPresetEditRequest: Identifiable {
    let preset: QuickAIPreset
    let isNew: Bool
    var id: UUID { preset.id }
}

private struct QuickAIPresetRow: View {
    let preset: QuickAIPreset
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SettingsRow(title: preset.name, subtitle: preset.webSearch ? "Web search on" : nil) {
            SymbolImage(name: "sparkles", size: Theme.Size.settingsRowIcon - Theme.Spacing.xs)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
        } trailing: {
            AliasField(entry: AppEntry(preset))
            ShortcutRecorder(action: .aiPreset(id: preset.id))
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit Preset")
            .accessibilityLabel("Edit \(preset.name)")
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete Preset")
            .accessibilityLabel("Delete \(preset.name)")
        }
    }
}

private struct QuickAIPresetEditorPanel: View {
    let request: QuickAIPresetEditRequest
    let onSave: (QuickAIPreset) -> Void
    let onCancel: () -> Void

    @State private var preset: QuickAIPreset

    init(
        request: QuickAIPresetEditRequest, onSave: @escaping (QuickAIPreset) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _preset = State(initialValue: request.preset)
    }

    private var trimmedName: String {
        preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsEditorHeader(
                title: request.isNew ? "Add Preset" : "Edit Preset",
                subtitle: "Its prompt, model and web search apply to the chats it starts."
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.dialogInset)
            .padding(.top, Theme.Spacing.dialogInset)
            .padding(.bottom, Theme.Spacing.xl)

            Form {
                Section {
                    SettingsEditorField("Name", labelFont: .callout.weight(.medium)) {
                        TextField("Name", text: $preset.name, prompt: Text("Code Reviewer"))
                            .settingsEditorTextField()
                    }
                    SystemPromptEditor(text: $preset.systemPrompt)
                        .accessibilityLabel("System prompt")
                }
                Section {
                    AIModelSelectionRows(
                        selection: preset.model,
                        inheritedTitle: "Quick AI's model",
                        select: { preset.model = $0 },
                        modelLabel: { Text("Model") },
                        effortLabel: { Text("Reasoning effort") })
                    Toggle(isOn: $preset.webSearch) {
                        Text("Web search")
                        Text("Where the model supports it. Prompts go to a search engine.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack(spacing: Theme.Spacing.md) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    preset.name = trimmedName
                    onSave(preset)
                }
                .buttonStyle(.modalAction(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
            .padding(Theme.Spacing.dialogInset)
        }
        .frame(width: Theme.Size.editorSheetWidth, height: 540)
        .settingsEditorPanelSurface()
    }
}
