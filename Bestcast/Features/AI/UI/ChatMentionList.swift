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
                .accessibilityHint(hint(source.kind))
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
            if let badge = badge(source.kind) {
                Text(badge)
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

    private func hint(_ kind: ChatToolSource.Kind) -> String {
        switch kind {
        case .bestcast: "Bestcast integration"
        case .raycastExtension: "Raycast extension"
        case .mcpServer: "MCP server"
        }
    }

    private func badge(_ kind: ChatToolSource.Kind) -> String? {
        switch kind {
        case .bestcast: nil
        case .raycastExtension: "Extension"
        case .mcpServer: "MCP"
        }
    }
}
