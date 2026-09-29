import SwiftUI

/// The `@` picker: what a turn can be addressed to, with the one Return or ⇥ would take lit.
struct ChatMentionList: View {
    @Environment(\.metrics) private var metrics
    let sources: [ChatToolSource]
    let selected: Int
    let onPick: (ChatToolSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                Button {
                    onPick(source)
                } label: {
                    row(source, isSelected: index == selected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(source.title), @\(source.handle)")
                .accessibilityHint(source.isBuiltIn ? "Tinycast integration" : "MCP server")
                .accessibilityAddTraits(index == selected ? .isSelected : [])
            }
        }
        .padding(metrics.spacing.xs)
        .background {
            Color.clear.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: Theme.Radius.menuPanel, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools to address")
    }

    private func row(_ source: ChatToolSource, isSelected: Bool) -> some View {
        HStack(spacing: metrics.spacing.md) {
            Image(systemName: source.symbol)
                .symbolRenderingMode(.hierarchical)
                .frame(width: metrics.size.chatAttachmentGlyph)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("@\(source.handle)")
            Text(source.title)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer(minLength: 0)
            if !source.isBuiltIn {
                Text("MCP")
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            isSelected ? Theme.Colors.selection : .clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.menuRow, style: .continuous))
        .contentShape(Rectangle())
    }
}
