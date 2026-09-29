import SwiftUI

/// Ready-made AI Commands, added in one click; an added one is the reader's to edit like any other.
struct AICommandLibraryPanel: View {
    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppCore.self) private var core
    @Environment(CustomQuickActionStore.self) private var customActions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SettingsEditorHeader(
                title: "AI Command Library",
                subtitle: "Add a command in one click, then change it like one of your own.")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    ForEach(AICommandLibrary.Category.allCases) { category in
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text(category.rawValue)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(AICommandLibrary.entries(in: category), content: row)
                        }
                    }
                }
                .padding(.trailing, Theme.Spacing.md)
                .hideNativeScrollers()
            }
            .overflowFade()
            .thinScrollbar()
            .frame(height: Theme.Size.editorTextHeight * 3)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface()
    }

    private func row(_ entry: AICommandLibrary.Entry) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            SymbolImage(name: entry.symbol, size: Theme.Size.quickActionHeaderIcon)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: Theme.Size.settingsRowIcon)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(entry.name)
                Text(detail(for: entry))
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.md)
            if entry.isAdded(in: customActions.actions) {
                Label("Added", systemImage: "checkmark")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else {
                Button("Add") { core.quickActionCoordinator.addFromLibrary(entry) }
                    .accessibilityLabel("Add \(entry.name)")
            }
        }
    }

    private func detail(for entry: AICommandLibrary.Entry) -> String {
        let asks = AICommandTemplate.arguments(in: entry.prompt).map(\.name)
        let inputs = asks.isEmpty ? [] : ["Asks for " + asks.joined(separator: ", ")]
        return (inputs + [entry.output.title]).joined(separator: " · ")
    }
}
