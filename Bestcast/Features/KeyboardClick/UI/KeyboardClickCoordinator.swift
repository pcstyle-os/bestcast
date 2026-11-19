import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click by keyboard, click by name and scroll by keyboard. See docs/features/keyboard-click.md.
@MainActor
final class KeyboardClickCoordinator {
    private unowned let core: AppCore
    private let state = KeyboardClickState()
    private var panel: KeyboardClickPanel?
    private var sweep: Task<Void, Never>?

    init(core: AppCore) {
        self.core = core
    }

    /// A second press of the same hotkey closes the overlay instead of reading the window again.
    func start(_ mode: KeyboardClickState.Mode) {
        guard sweep == nil else { return }
        if panel != nil {
            close()
            return
        }
        guard Permissions.isAccessibilityTrusted() else {
            Task { await reportAccessibilityRefusal() }
            return
        }
        guard let app = FrontmostApplication.current(),
            app.processIdentifier != NSRunningApplication.current.processIdentifier
        else {
            core.showMessage("No window to click", tone: .neutral)
            return
        }
        let pid = app.processIdentifier
        sweep = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { AXClickTargetSweep.read(pid: pid) }.value
            guard let self else { return }
            sweep = nil
            guard let result else {
                core.showMessage("No window to click", tone: .neutral)
                return
            }
            let targets = ClickTargetLayout.prepare(result.targets, visibleIn: result.window)
            if mode != .scroll, targets.isEmpty {
                core.showMessage("Nothing to click here", tone: .neutral)
                return
            }
            present(mode, window: result.window, targets: targets)
        }
    }

    private func present(_ mode: KeyboardClickState.Mode, window: CGRect, targets: [ClickTarget]) {
        state.mode = mode
        state.window = window
        state.targets = targets
        state.labels = ClickHints.labels(count: targets.count)
        state.typed = ""
        let host = NSHostingView(rootView: KeyboardClickOverlay(state: state))
        host.sizingOptions = []
        let panel = KeyboardClickPanel(content: host)
        panel.setFrame(AXGeometry(screens: NSScreen.screens).flip(window), display: false)
        panel.onKey = { [weak self] event in self?.handle(event) }
        panel.onResignKey = { [weak self] in self?.close() }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func close() {
        guard let panel else { return }
        panel.onResignKey = nil
        panel.orderOut(nil)
        self.panel = nil
        state.typed = ""
    }

    private func handle(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape { return close() }
        if keyCode == kVK_Delete {
            if !state.typed.isEmpty { state.typed.removeLast() }
            return
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return }
        let key = event.charactersIgnoringModifiers?.lowercased().first
        switch state.mode {
        case .scroll:
            guard let key, let offset = KeyboardScroll.offset(for: key, viewportHeight: state.window.height)
            else { return }
            scroll(by: offset)
        case .hints:
            guard let key, ClickHints.alphabet.contains(key) else { return }
            let typed = state.typed + String(key)
            switch ClickHints.outcome(typed: typed, labels: state.labels) {
            case .hit(let index): click(state.targets[index])
            case .narrowed: state.typed = typed
            case .miss: break
            }
        case .name:
            if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
                if let first = state.matches.first { click(state.targets[first]) }
                return
            }
            guard let text = event.characters, !text.isEmpty,
                !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { return }
            state.typed += text
        }
    }

    /// A real click at the target's centre, then the pointer goes back where the reader left it.
    private func click(_ target: ClickTarget) {
        close()
        let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
        let home = CGEvent(source: nil)?.location
        Task {
            post(.leftMouseDown, at: point)
            try? await Task.sleep(for: .milliseconds(30))
            post(.leftMouseUp, at: point)
            try? await Task.sleep(for: .milliseconds(60))
            guard let home else { return }
            CGWarpMouseCursorPosition(home)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Wheel deltas are the content's motion reversed: a negative wheel reveals what lies below.
    private func scroll(by offset: CGVector) {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(-offset.dy), wheel2: Int32(-offset.dx), wheel3: 0)
        else { return }
        event.location = CGPoint(x: state.window.midX, y: state.window.midY)
        event.post(tap: .cghidEventTap)
    }

    private func reportAccessibilityRefusal() async {
        NSApp.activate(ignoringOtherApps: true)
        guard
            await core.reportFailure(
                title: "Bestcast can't see the window",
                message:
                    "Clicking by keyboard reads buttons through Accessibility. Turn it on for Bestcast "
                    + "in System Settings, then try again.",
                symbol: "cursorarrow.click.2", recovery: "Open System Settings")
        else { return }
        Permissions.openAccessibilitySettings()
    }
}
