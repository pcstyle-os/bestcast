import SwiftUI

struct CustomQuickActionEditRequest: Identifiable {
    let id = UUID()
    let action: CustomQuickAction?
}

struct CustomQuickActionEditorPanel: View {
    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppCore.self) private var core

    private let existing: CustomQuickAction?
    @State private var name: String
    @State private var iconSymbol: String?
    @State private var instructions: String
    @State private var output: AICommandOutput
    @State private var creativity: AICommandCreativity
    @State private var model: AIModelSelection?
    @State private var automation: AICommandAutomation
    @State private var failure: String?
    @State private var showingIconPicker = false

    private static let iconSymbols = [
        "wand.and.stars", "textformat", "text.append", "text.quote", "text.badge.checkmark",
        "character.cursor.ibeam", "scissors", "arrow.down.right.and.arrow.up.left", "list.bullet",
        "bubble.left.and.text.bubble.right", "envelope", "megaphone", "face.smiling",
        "theatermasks", "graduationcap", "book", "brain", "lightbulb", "sparkles", "checkmark.seal",
        "globe", "curlybraces", "terminal", "chart.bar", "tag", "flag", "bolt", "leaf",
        "paintbrush", "hammer", "heart", "star"
    ]

    private static let placeholder =
        "Make the text below more concise, keeping the writer's voice.\n\n{selection}"

    init(request: CustomQuickActionEditRequest, model: AIModelSelection?) {
        existing = request.action
        _name = State(initialValue: request.action?.name ?? "")
        _iconSymbol = State(initialValue: request.action?.iconSymbol)
        _instructions = State(initialValue: request.action?.instructions ?? "")
        _output = State(initialValue: request.action?.output ?? .panel)
        _creativity = State(initialValue: request.action?.creativity ?? .medium)
        _model = State(initialValue: model)
        _automation = State(initialValue: request.action?.automation ?? AICommandAutomation())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(
                title: existing == nil ? "New AI Command" : "Edit \(existing?.name ?? "")",
                subtitle: "Bestcast fills in the prompt's placeholders when you run it, then asks "
                    + "the model."
            )

            HStack(alignment: .bottom, spacing: Theme.Spacing.lg) {
                nameField
                iconField
            }

            instructionsField

            HStack(spacing: Theme.Spacing.lg) {
                Picker("Result", selection: $output) {
                    ForEach(AICommandOutput.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Picker("Creativity", selection: $creativity) {
                    ForEach(AICommandCreativity.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .help("Ignored by a model that sets its own temperature.")
            }

            QuickActionModelPicker(selection: $model)

            AICommandAutomationFields(automation: $automation, instructions: instructions)

            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.destructive)
            }

            HStack(spacing: Theme.Spacing.md) {
                if let existing {
                    Button("Delete", role: .destructive) {
                        dismiss()
                        Task { await core.quickActionCoordinator.deleteCustomQuickAction(id: existing.id) }
                    }
                    .buttonStyle(.modalAction(.destructive, fillsWidth: false))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface()
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Name")
                .font(.callout.weight(.medium))
            TextField("Make Concise", text: $name)
                .settingsEditorTextField()
        }
    }

    private var iconField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Icon")
                .font(.callout.weight(.medium))
            Button {
                showingIconPicker = true
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    SymbolImage(name: iconSymbol ?? CustomQuickAction.sfSymbol, size: 14)
                    Text(iconSymbol == nil ? "Automatic" : "Custom")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(width: 120)
            }
            .popover(isPresented: $showingIconPicker, arrowEdge: .bottom) {
                SymbolPicker(
                    selection: $iconSymbol, fallback: CustomQuickAction.sfSymbol,
                    symbols: Self.iconSymbols
                ) {
                    showingIconPicker = false
                }
            }
        }
    }

    private var instructionsField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Prompt")
                .font(.callout.weight(.medium))
            TextEditor(text: $instructions)
                .font(.body)
                .settingsEditorTextArea(height: Theme.Size.editorTextHeight * 2)
                .overlay(alignment: .topLeading) {
                    if instructions.isEmpty {
                        Text(Self.placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(Theme.Spacing.md)
                            .allowsHitTesting(false)
                    }
                }
            Text(
                "Placeholders: {selection}, {clipboard}, {browser-tab}, {frontmost-app}, {date}, "
                    + "{time}, and up to three {argument name=\"topic\" default=\"…\"} fields. "
                    + "A prompt with none acts on your selection. Selected, copied and page text "
                    + "is always sent as material, never as instructions."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let draft = CustomQuickAction(
            id: existing?.id ?? UUID(), name: name, iconSymbol: iconSymbol,
            instructions: instructions, output: output, creativity: creativity,
            createdAt: existing?.createdAt ?? Date(),
            automation: automation.isEmpty ? nil : automation)
        do {
            if existing == nil {
                try core.quickActionCoordinator.addCustomQuickAction(draft, model: model)
            } else {
                try core.quickActionCoordinator.updateCustomQuickAction(draft, model: model)
            }
            dismiss()
        } catch {
            failure = error.errorDescription
        }
    }
}
