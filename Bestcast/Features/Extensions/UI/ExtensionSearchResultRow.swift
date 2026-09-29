import SwiftUI

/// A contributed root-search row, drawn by the host: the extension supplies text, never a view.
struct ExtensionSearchResultRow: View {
    @Environment(\.metrics) private var metrics
    let item: ExtensionSearchItem
    /// The provider's name, where the trailing slot has nothing of the extension's own to say.
    let source: String
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            ExtensionSearchGlyph(systemName: item.icon ?? "puzzlepiece.extension")
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(item.title)
                    .font(metrics.typography.rowTitle)
                    .lineLimit(item.style == .answer ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: item.style == .answer)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: metrics.spacing.md)
            Text(item.accessory ?? source)
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(fill)
        )
        .armedHover($hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(
            [item.subtitle, item.accessory ?? source].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }
}

/// The rounded tile launcher rows use, so contributed rows line up with the icons below them.
private struct ExtensionSearchGlyph: View {
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
