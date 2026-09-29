import AppKit
import SwiftUI

/// The AI menu hangs off the note like the switcher, so it moves with it and closes like a popover.
@MainActor
final class NoteAIWindowController: NSObject, NSWindowDelegate {
    private unowned let coordinator: NotesCoordinator
    private var panel: NotesPanel?

    init(coordinator: NotesCoordinator) {
        self.coordinator = coordinator
    }

    func show(under host: NSWindow) {
        let panel = ensurePanel()
        let size = Theme.Size.noteAIMenu
        let frame = host.frame
        let origin = CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - Theme.Size.noteTitlebar - Theme.Size.noteSwitcherDrop - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        if panel.parent !== host {
            panel.parent?.removeChildWindow(panel)
            host.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    /// A click back in the note is a return to writing, so an unaccepted reply is dropped.
    func windowDidResignKey(_ notification: Notification) {
        guard coordinator.aiSession != nil else { return }
        coordinator.closeAIMenu(focusEditor: false)
    }

    // MARK: - Private

    private func ensurePanel() -> NotesPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: NoteAIView().environment(coordinator))
        hosting.sizingOptions = []
        let panel = NotesPanel(
            content: hosting,
            size: Theme.Size.noteAIMenu,
            styleMask: .borderless,
            acceptsMain: false)
        panel.delegate = self
        panel.onEscape = { [weak coordinator] in coordinator?.handleAIEscape() }
        let close: () -> Void = { [weak coordinator] in coordinator?.closeAIMenu() }
        // The note window is not key while this is up, so its toggle and close chords work here.
        panel.commandChords = [
            "j": close,
            "k": close,
            "w": close,
            "c": { [weak coordinator] in coordinator?.copyAIReply() }
        ]
        self.panel = panel
        return panel
    }
}
