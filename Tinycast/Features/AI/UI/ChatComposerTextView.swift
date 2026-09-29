import AppKit
import SwiftUI

/// The window's composer field: Return sends, ⇧↩ and ⌥↩ break the line, and it grows to a cap.
struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// A new value pulls focus into the field: a switched chat is one you are about to type into.
    let focusKey: UUID
    let onSubmit: () -> Void
    /// Offered the keys an open `@` picker takes; false leaves the key to the text view.
    var onPickerKey: (PickerKey) -> Bool = { _ in false }

    enum PickerKey {
        case up
        case down
        case accept
        case dismiss

        init?(_ selector: Selector) {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): self = .up
            case #selector(NSResponder.moveDown(_:)): self = .down
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                self = .accept
            case #selector(NSResponder.cancelOperation(_:)): self = .dismiss
            default: return nil
            }
        }
    }

    /// How the window's key monitor tells its composer from the find and rename fields.
    static let identifier = NSUserInterfaceItemIdentifier("AIChatComposer")

    private static var font: NSFont { .preferredFont(forTextStyle: .body) }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onPickerKey: onPickerKey)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.setAccessibilityLabel("Message")
        textView.identifier = Self.identifier
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onPickerKey = onPickerKey
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Only an outside write lands here; echoing the view's own text back would reset the caret.
        if textView.string != text { textView.string = text }
        guard context.coordinator.focusedKey != focusKey else { return }
        context.coordinator.focusedKey = focusKey
        // Next turn: on first mount the view has no window to become first responder of yet.
        Task { @MainActor [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// Measured from the text rather than the text view, whose width lags the proposal by a pass.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let font = Self.font
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        // A trailing newline starts a line `boundingRect` would not count until it held a glyph.
        let measured = (text.hasSuffix("\n") ? text + " " : text) as NSString
        let height = measured.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        ).height.rounded(.up)
        return CGSize(
            width: width,
            height: min(max(lineHeight, height), Theme.Size.aiChatComposerMaxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onPickerKey: (PickerKey) -> Bool
        var focusedKey: UUID?

        init(
            text: Binding<String>, onSubmit: @escaping () -> Void,
            onPickerKey: @escaping (PickerKey) -> Bool
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onPickerKey = onPickerKey
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        /// Never called mid-composition, so Return confirming an input method's text stays its own.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if let key = PickerKey(selector), onPickerKey(key) { return true }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit()
            }
            return true
        }
    }
}
