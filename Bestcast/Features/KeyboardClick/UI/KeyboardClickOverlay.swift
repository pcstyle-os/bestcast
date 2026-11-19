import AppKit
import SwiftUI

/// Covers the target window, click-through; keys arrive through `sendEvent` while it is key.
final class KeyboardClickPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    /// A click anywhere else takes key away, which ends the session.
    var onResignKey: (() -> Void)?

    init(content: NSView) {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = content
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let onKey else {
            super.sendEvent(event)
            return
        }
        onKey(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class KeyboardClickState {
    enum Mode {
        case hints
        case name
        case scroll
    }

    var mode = Mode.hints
    /// AX space, like every target frame; the overlay draws relative to its top-left.
    var window = CGRect.zero
    var targets: [ClickTarget] = []
    var labels: [String] = []
    var typed = ""

    var matches: [Int] { ClickHints.search(typed, in: targets) }
}

struct KeyboardClickOverlay: View {
    let state: KeyboardClickState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            switch state.mode {
            case .hints: hints
            case .name: names
            case .scroll: scrollKeys
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var hints: some View {
        ForEach(state.targets.indices.filter { state.labels[$0].hasPrefix(state.typed) }, id: \.self) { index in
            placed(state.targets[index].frame, alignment: .leading) {
                HintTag(label: state.labels[index], typed: state.typed)
            }
        }
    }

    @ViewBuilder private var names: some View {
        let matches = state.matches
        ForEach(Array(matches.enumerated()), id: \.element) { rank, index in
            placed(state.targets[index].frame, alignment: .center) {
                RoundedRectangle(cornerRadius: Theme.Radius.recorderKeyCap, style: .continuous)
                    .fill(Theme.Colors.findMatch)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.recorderKeyCap, style: .continuous)
                            .strokeBorder(Theme.Colors.findCurrent, lineWidth: rank == 0 ? 2 : 0)
                    }
            }
        }
        floating {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.Colors.textTertiary)
                Text(state.typed.isEmpty ? "Type a name" : state.typed)
                    .foregroundStyle(state.typed.isEmpty ? Theme.Colors.textTertiary : Theme.Colors.textPrimary)
                Spacer(minLength: Theme.Spacing.xl)
                if !state.typed.isEmpty {
                    Text("\(matches.count)").foregroundStyle(Theme.Colors.textTertiary).monospacedDigit()
                }
            }
            .font(Theme.Typography.rowTitle)
            .frame(width: Self.searchWidth)
        }
    }

    private var scrollKeys: some View {
        floating {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(["H", "J", "K", "L"], id: \.self) { KeyCapChip(text: $0, scale: .compact) }
                Text("Scroll").padding(.trailing, Theme.Spacing.md)
                KeyCapChip(text: "D", scale: .compact)
                KeyCapChip(text: "U", scale: .compact)
                Text("Half page")
            }
            .font(Theme.Typography.rowTrailing)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private static let searchWidth: CGFloat = 260

    /// A target's own box in the overlay, so a tag can hug its leading edge.
    private func placed(
        _ frame: CGRect, alignment: Alignment, @ViewBuilder content: () -> some View
    ) -> some View {
        Color.clear
            .frame(width: frame.width, height: frame.height)
            .overlay(alignment: alignment, content: content)
            .offset(x: frame.minX - state.window.minX, y: frame.minY - state.window.minY)
    }

    /// Along the bottom edge, since a window's own controls crowd its top.
    private func floating(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .background(Theme.Colors.panelScrim)
            .background(GlassEffectView())
            .clipShape(Capsule())
            .shadow(color: Theme.Colors.tooltipShadow, radius: 8, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, Theme.Spacing.xxl)
    }
}

/// The Mac's own find yellow, so a hint reads as a mark on the window rather than a control.
private struct HintTag: View {
    let label: String
    let typed: String

    var body: some View {
        HStack(spacing: 0) {
            Text(label.prefix(typed.count).uppercased()).opacity(0.4)
            Text(label.dropFirst(typed.count).uppercased())
        }
        .font(Theme.Typography.clickHint)
        .foregroundStyle(Theme.Colors.findCurrentInk)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.recorderKeyCap, style: .continuous)
                .fill(Theme.Colors.findCurrent)
                .shadow(color: Theme.Colors.tooltipShadow, radius: 2, y: 1))
        .fixedSize()
    }
}
