import AppKit
import SwiftUI

/// The open Hyper layer's key list. See docs/features/hotkeys.md#hyper-layers.
@MainActor
final class HyperLayerHUDController {
    struct Item: Identifiable, Equatable {
        let key: Int
        let name: String
        var id: Int { key }
    }

    /// Long enough that a reader who knows the keys never sees the panel flash up.
    static let revealDelay: Duration = .milliseconds(250)

    private let settings: AppSettings
    private let presenter = HUDPresenter(
        anchor: .heightFraction(0.42), dwell: 0, screen: { .underCursor })
    private let state = HyperLayerHUDState()
    private var reveal: Task<Void, Never>?
    private var unflash: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func open(leader: Int, items: [Item]) {
        state.leader = leader
        state.items = items
        state.flashed = nil
        reveal?.cancel()
        // A layer switch while showing re-renders in place; a fresh one waits out the delay.
        if presenter.isShowing {
            present()
            return
        }
        reveal = Task { [weak self] in
            try? await Task.sleep(for: Self.revealDelay)
            guard !Task.isCancelled else { return }
            self?.present()
        }
    }

    func flash(key: Int) {
        state.flashed = key
        unflash?.cancel()
        unflash = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.state.flashed = nil
        }
    }

    func close() {
        reveal?.cancel()
        presenter.dismiss()
    }

    private func present() {
        presenter.show(
            HyperLayerHUDView(state: state).environment(\.metrics, settings.interfaceSize.metrics),
            dwells: false)
    }
}

@MainActor
@Observable
final class HyperLayerHUDState {
    var leader = 0
    var items: [HyperLayerHUDController.Item] = []
    var flashed: Int?
}

/// ✦ and the leader on top, then one row per bound key, in two columns.
struct HyperLayerHUDView: View {
    let state: HyperLayerHUDState
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                KeyCapChip(text: HyperKeyPhysicalKey.hyperGlyph, scale: .compact)
                KeyCapChip(text: glyph(state.leader), scale: .compact)
            }
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.sm, verticalSpacing: 2) {
                ForEach(rows, id: \.first?.key) { row in
                    GridRow {
                        ForEach(row) { item in cell(item) }
                    }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .fixedSize()
        .background(Theme.Colors.panelScrim)
        .background(GlassEffectView())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.menuPanel, style: .continuous))
        .animation(.easeOut(duration: Theme.Duration.hover), value: state.flashed)
    }

    private func cell(_ item: HyperLayerHUDController.Item) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            KeyCapChip(text: glyph(item.key), scale: .compact)
            Text(Self.clipped(item.name))
                .font(Theme.Typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.keyCap + Theme.Spacing.xs, style: .continuous)
                .fill(state.flashed == item.key ? Theme.Colors.controlHover : Color.clear))
    }

    /// Clipped by length, not by layout: a fixed-size panel would otherwise grow with the longest name.
    private static func clipped(_ name: String) -> String {
        name.count > 32 ? name.prefix(31) + "…" : name
    }

    private var rows: [[HyperLayerHUDController.Item]] {
        stride(from: 0, to: state.items.count, by: 2).map {
            Array(state.items[$0..<min($0 + 2, state.items.count)])
        }
    }

    private func glyph(_ keyCode: Int) -> String {
        KeyShortcut(carbonKeyCode: keyCode, carbonModifiers: 0).keycaps.last ?? "?"
    }
}
