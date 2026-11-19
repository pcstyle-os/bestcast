import AppKit
import SwiftUI

/// The on-screen keystroke overlay. See docs/features/keystroke-overlay.md.
@MainActor
final class KeystrokeOverlayController {
    let state = KeystrokeOverlayState()
    /// Called when macOS refuses the tap; the setting has already been switched back off.
    var onTapRefused: (() -> Void)?

    private let settings: AppSettings
    private var feed = KeystrokeFeed()
    private lazy var tap = KeystrokeTap { [weak self] press in self?.record(press) }
    private var panel: KeystrokeOverlayPanel?
    private var expiry: Task<Void, Never>?

    /// Above the Dock, which a screencast keeps in frame.
    private static let defaultLift: CGFloat = 72

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Brings the tap and the panel in line with the settings.
    func apply() {
        state.size = settings.keystrokeOverlaySize
        if settings.keystrokeOverlayEnabled {
            guard tap.install() else {
                settings.keystrokeOverlayEnabled = false
                onTapRefused?()
                return
            }
        } else {
            tap.tearDown()
            expiry?.cancel()
            feed = KeystrokeFeed()
            state.items = []
        }
        layout()
    }

    /// Placing mode: the panel takes the mouse and shows sample keys until it is dropped.
    func toggleMoving() {
        state.moving.toggle()
        layout()
    }

    /// A layer swallows its keys before the tap sees them, so Hyper reports the press itself.
    func recordLayer(leader: Int, key: Int) {
        guard settings.keystrokeOverlayEnabled else { return }
        let glyphs = [leader, key].compactMap { KeyShortcut(carbonKeyCode: $0, carbonModifiers: 0).keycaps.last }
        record(KeystrokePress(keycaps: [HyperKeyPhysicalKey.hyperGlyph] + glyphs, typed: nil, isShortcut: true))
    }

    private func record(_ press: KeystrokePress) {
        feed.record(press, at: .now, filter: settings.keystrokeOverlayFilter)
        publish()
    }

    private func publish() {
        state.items = feed.items
        expiry?.cancel()
        guard let next = feed.nextExpiry else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled, let self else { return }
            feed.prune(at: .now)
            publish()
        }
    }

    /// The panel stays up while enabled, empty and click-through between keys, so items can fade.
    private func layout() {
        guard state.moving || settings.keystrokeOverlayEnabled else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        let size = CGSize(
            width: state.size.pointSize * 36, height: state.size.pointSize * 3.4)
        let anchor = placedAnchor(for: size)
        panel.setFrame(
            CGRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height),
            display: true)
        panel.ignoresMouseEvents = !state.moving
        panel.orderFrontRegardless()
    }

    /// The saved spot while a display still shows it, else above the Dock on the main display.
    private func placedAnchor(for size: CGSize) -> CGPoint {
        if let saved = settings.keystrokeOverlayAnchor,
            let screen = NSScreen.screens.first(where: { $0.frame.contains(saved) })
        {
            let visible = screen.visibleFrame
            return CGPoint(
                x: min(max(saved.x, visible.minX + size.width / 2), visible.maxX - size.width / 2),
                y: min(max(saved.y, visible.minY), visible.maxY - size.height))
        }
        let visible = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: visible.midX, y: visible.minY + Self.defaultLift)
    }

    private func makePanel() -> KeystrokeOverlayPanel {
        let host = NSHostingView(rootView: KeystrokeOverlayView(state: state))
        host.sizingOptions = []
        let panel = KeystrokeOverlayPanel(content: host)
        panel.onDropped = { [weak self, weak panel] in
            guard let self, let frame = panel?.frame else { return }
            settings.keystrokeOverlayAnchor = CGPoint(x: frame.midX, y: frame.minY)
            state.moving = false
            layout()
        }
        self.panel = panel
        return panel
    }
}

@MainActor
@Observable
final class KeystrokeOverlayState {
    var items: [KeystrokeFeed.Item] = []
    var size = KeystrokeOverlaySize.medium
    var moving = false
}

/// Click-through, except while placing it, when a drag moves it and the release drops it.
final class KeystrokeOverlayPanel: NSPanel {
    var onDropped: (() -> Void)?
    private var grab: (mouse: NSPoint, origin: NSPoint)?

    init(content: NSView) {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = content
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            grab = (NSEvent.mouseLocation, frame.origin)
        case .leftMouseDragged:
            guard let grab else { break }
            let mouse = NSEvent.mouseLocation
            setFrameOrigin(
                NSPoint(x: grab.origin.x + mouse.x - grab.mouse.x, y: grab.origin.y + mouse.y - grab.mouse.y))
        case .leftMouseUp:
            guard grab != nil else { break }
            grab = nil
            onDropped?()
        default:
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct KeystrokeOverlayView: View {
    let state: KeystrokeOverlayState

    /// What placing shows when nothing was typed, so there is something to drag.
    private static let sample: [KeystrokeFeed.Item] = [
        .init(id: -1, content: .keys(["⌘", "K"], count: 1), updated: .distantPast),
        .init(id: -2, content: .text("hello"), updated: .distantPast),
        .init(id: -3, content: .keys(["✦", "W"], count: 2), updated: .distantPast),
    ]

    var body: some View {
        let shown = state.moving && state.items.isEmpty ? Self.sample : state.items
        HStack(spacing: state.size.pointSize * 0.4) {
            ForEach(shown) { item in
                pill(item).transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .overlay {
            if state.moving {
                RoundedRectangle(cornerRadius: Theme.Radius.dialog, style: .continuous)
                    .strokeBorder(Theme.Colors.dropGuide, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .animation(.easeOut(duration: Theme.Duration.hover), value: state.items)
    }

    private func pill(_ item: KeystrokeFeed.Item) -> some View {
        let points = state.size.pointSize
        return HStack(alignment: .firstTextBaseline, spacing: points * 0.3) {
            switch item.content {
            case .text(let run):
                Text(run)
            case .keys(let keycaps, let count):
                Text(keycaps.joined(separator: keycaps.last?.count ?? 0 > 1 ? " " : ""))
                if count > 1 {
                    Text("×\(count)")
                        .font(.system(size: points * 0.7, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
        .font(.system(size: points, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.Colors.textPrimary)
        .lineLimit(1)
        .padding(.horizontal, points * 0.7)
        .padding(.vertical, points * 0.4)
        .background(Theme.Colors.panelScrim)
        .background(GlassEffectView())
        .clipShape(RoundedRectangle(cornerRadius: points * 0.6, style: .continuous))
        .fixedSize()
    }
}
