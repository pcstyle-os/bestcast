import SwiftUI

/// Fill and hover for every lead card, so none can answer a selection differently from another.
private struct LeadCardChrome: ViewModifier {
    @Environment(\.metrics) private var metrics
    let selected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(shape.fill(fill))
            .armedHover($hovered)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
    }

    private var fill: Color {
        if selected { return Theme.Colors.cardSelection }
        if hovered { return Theme.Colors.rowHover }
        return Theme.Colors.cardFill
    }
}

extension View {
    /// Padding stays each card's own: a meeting card is deliberately shorter than an answer.
    func leadCard(selected: Bool) -> some View {
        modifier(LeadCardChrome(selected: selected))
    }
}

/// One side of a two-column lead card: a value line with an optional caption beneath.
struct LeadCardColumn: View {
    @Environment(\.metrics) private var metrics
    let text: AttributedString
    let badge: String?
    var weight: Font.Weight = .medium
    /// The side a card answers from, so the eye lands on the answer first.
    var isSource = false

    var body: some View {
        VStack(spacing: metrics.spacing.xs) {
            Text(text)
                .font(metrics.typography.calcResult.weight(weight))
                .foregroundStyle(isSource ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let badge {
                Text(badge)
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, metrics.spacing.md)
    }
}
