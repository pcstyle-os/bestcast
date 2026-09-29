import SwiftUI

/// One chat's own system prompt; it stands in for the one in Settings for this chat alone.
struct ChatInstructionsSheet: View {
    let chat: AIChatState
    let coordinator: AIChatCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(chat: AIChatState, coordinator: AIChatCoordinator) {
        self.chat = chat
        self.coordinator = coordinator
        _text = State(initialValue: chat.session.instructions ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Chat Instructions")
                .font(.headline)
            Text(
                "Sent as this chat's system prompt, in place of the one in AI Settings. "
                    + "Leave it empty to use Settings' prompt.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(Theme.Spacing.sm)
                .frame(height: Theme.Size.editorTextHeight)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.Colors.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .strokeBorder(Theme.Colors.cardStroke, lineWidth: 1)
                )
                .accessibilityLabel("Chat instructions")
            HStack {
                Button("Clear") { text = "" }
                    .disabled(text.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    coordinator.setInstructions(text, in: chat)
                    dismiss()
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Save  ⌘S")
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(width: Theme.Size.chatInstructionsSheet)
        .onAppear { focused = true }
    }
}

/// Above the composer while an edit is open: what Send will do, and the way back out of it.
struct ChatEditingBanner: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label("Editing message: sending replaces it and everything after it", systemImage: "pencil")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.md)
            Button("Cancel", action: cancel)
                .buttonStyle(.borderless)
                .help("Cancel Editing  esc")
                .accessibilityLabel("Cancel editing")
        }
    }
}
