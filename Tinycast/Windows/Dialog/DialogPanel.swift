import AppKit
import Carbon.HIToolbox

/// One dialog's panel; keys go through `sendEvent`, so Esc/↵ need no focused subview.
final class DialogPanel: NSPanel {
    /// What the panel saw, not what it means: how far a step moves is the caller's business.
    enum Key {
        case cancel
        case confirm
        case increment
        case decrement
        case focusNext
        case focusPrevious
        case activateFocused
    }

    /// False when the dialog had no use for the key, which then goes on to AppKit.
    var onKey: ((Key) -> Bool)?
    /// Arrows are a control's keys, not the panel's; a text field needs them for its caret.
    var handlesArrowKeys = false
    /// Under Keyboard Navigation the key loop already reaches these controls, so ⇥ stays AppKit's.
    var hostsControls = false

    init(content: NSView, cornerRadius: CGFloat) {
        super.init(
            contentRect: NSRect(origin: .zero, size: content.frame.size),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .dialog
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Suppresses AppKit's own window animation; `fadeIn`/`fadeOut` replace it.
        animationBehavior = .none
        isReleasedWhenClosed = false
        content.wantsLayer = true
        content.layer?.cornerRadius = cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        contentView = content
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let onKey, let key = key(for: event), onKey(key) else {
            super.sendEvent(event)
            return
        }
        // One ring at a time: a button AppKit focused under Keyboard Navigation would draw another.
        if key == .focusNext || key == .focusPrevious { makeFirstResponder(nil) }
    }

    private func key(for event: NSEvent) -> Key? {
        // A field's own ⇥ and space belong to it: its key loop and its text.
        let isEditingText = firstResponder is NSText
        switch Int(event.keyCode) {
        case kVK_Escape: return .cancel
        case kVK_Return, kVK_ANSI_KeypadEnter: return .confirm
        case kVK_LeftArrow where handlesArrowKeys, kVK_DownArrow where handlesArrowKeys:
            return .decrement
        case kVK_RightArrow where handlesArrowKeys, kVK_UpArrow where handlesArrowKeys:
            return .increment
        case kVK_Tab where !isEditingText && !keyLoopOwnsTab:
            return event.modifierFlags.contains(.shift) ? .focusPrevious : .focusNext
        case kVK_Space where !isEditingText: return .activateFocused
        default: return nil
        }
    }

    private var keyLoopOwnsTab: Bool {
        hostsControls && NSApp.isFullKeyboardAccessEnabled
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
