import SwiftUI

extension View {
    /// A dialog's text field: plain, on the control surface, at a chip's height.
    func dialogTextField() -> some View {
        modifier(DialogTextField())
    }
}

/// One line of text a dialog asks for; reference semantics let the caller read it back.
@MainActor
@Observable
final class DialogTextState {
    let prompt: String
    var text: String

    init(prompt: String, text: String) {
        self.prompt = prompt
        self.text = text
    }
}

/// The single field a text dialog shows, focused so typing starts at once.
struct DialogTextInput: View {
    let state: DialogTextState
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var state = state
        TextField("", text: $state.text, prompt: Text(state.prompt))
            .focused($isFocused)
            .dialogTextField()
            .accessibilityLabel(state.prompt)
            .onAppear { isFocused = true }
    }
}

private struct DialogTextField: ViewModifier {
    @Environment(\.metrics) private var metrics

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(metrics.typography.rowTitle)
            .padding(.horizontal, metrics.spacing.lg)
            .frame(height: metrics.size.dialogButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                    .fill(Theme.Colors.controlSurface))
    }
}
