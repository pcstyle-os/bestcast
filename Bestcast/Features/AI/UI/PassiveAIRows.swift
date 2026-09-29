import SwiftUI

/// Root search's AI answer; the reply streams into the subtitle under the question.
struct PassiveAnswerRow: View {
    @Environment(\.metrics) private var metrics
    let answer: PassiveAnswer
    let selected: Bool
    @State private var hovered = false

    private var subtitle: String {
        switch answer.phase {
        case .thinking: return "Thinking…"
        case .failed: return "No answer here. Press Return to ask in Quick AI."
        case .streaming, .done: return answer.text
        }
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            PassiveGlyph(systemName: "sparkles")
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(answer.query)
                    .font(metrics.typography.rowTitle)
                    .lineLimit(1)
                Text(subtitle)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: metrics.spacing.md)
            Text(answer.model.isOnDevice ? "On-Device" : "AI")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.secondary)
        }
        .passiveRow(selected: selected, hovered: $hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI answer to \(answer.query)")
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One suggestion for the text the previous app had selected.
struct PassiveSelectionRow: View {
    @Environment(\.metrics) private var metrics
    let item: PassiveSelectionItem
    let selection: PassiveSelection
    let selected: Bool
    @State private var hovered = false

    /// Only the ask row quotes the text: repeating it under every action reads as noise.
    private var preview: String? {
        guard item == .ask else { return nil }
        let line = selection.text.prefix(200).split(whereSeparator: \.isNewline).first ?? ""
        return "“" + line.trimmingCharacters(in: .whitespaces) + "”"
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            PassiveGlyph(systemName: item.systemImage)
            Text(item.title)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
            if let preview {
                Text(preview)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.md)
            Text(selection.kind.title)
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.secondary)
        }
        .passiveRow(selected: selected, hovered: $hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(
            ["Selected \(selection.kind.title)", preview].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A symbol on the rounded tile launcher rows use, so these rows line up with the icons below.
private struct PassiveGlyph: View {
    @Environment(\.metrics) private var metrics
    let systemName: String

    var body: some View {
        RoundedRectangle(cornerRadius: metrics.radius.thumbnail, style: .continuous)
            .fill(Theme.Colors.controlSurface)
            .frame(width: metrics.size.rowIcon, height: metrics.size.rowIcon)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 12))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            )
    }
}

extension View {
    fileprivate func passiveRow(selected: Bool, hovered: Binding<Bool>) -> some View {
        modifier(PassiveRowChrome(selected: selected, hovered: hovered))
    }
}

private struct PassiveRowChrome: ViewModifier {
    @Environment(\.metrics) private var metrics
    let selected: Bool
    @Binding var hovered: Bool

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, metrics.spacing.md)
            .padding(.vertical, metrics.spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                    .fill(fill)
            )
            .armedHover($hovered)
    }
}

/// ⌘K for the passive rows: every suggestion at once, or the answer's open and copy.
@MainActor
enum PassiveAIActionsMenu {
    static func content(selection: PassiveSelection, core: AppCore) -> PopoverMenuContent {
        PopoverMenuContent(
            header: "Selected \(selection.kind.title)",
            items: selection.items.map { item in
                PopoverMenuItem(title: item.title, systemImage: item.systemImage) {
                    core.passiveAICoordinator.run(item)
                }
            })
    }

    static func content(answer: PassiveAnswer, core: AppCore) -> PopoverMenuContent {
        PopoverMenuContent(
            header: answer.query,
            items: [
                PopoverMenuItem(title: "Open in Quick AI", systemImage: "sparkles", shortcut: "↵") {
                    core.passiveAICoordinator.openAnswerInQuickAI()
                },
                PopoverMenuItem(
                    title: "Copy Answer", systemImage: "doc.on.doc",
                    isEnabled: answer.phase == .done, shortcut: "⇧⌘C"
                ) {
                    _ = core.passiveAICoordinator.copyAnswer()
                }
            ])
    }
}
