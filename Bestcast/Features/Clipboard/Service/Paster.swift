import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

enum Paster {
    /// Stamped on Bestcast's own synthetic keystrokes so the snippet keyword tap can skip them.
    static let bestcastEventTag: Int64 = 0x54494E59

    /// Covers the gap between `activate()` returning and the target app accepting a keystroke.
    private static let activationDelay: TimeInterval = 0.08

    /// Shorter: no activation to wait on, only the pasteboard write reaching the target's process.
    private static let directPostDelay: TimeInterval = 0.05

    /// The target reads the pasteboard when it handles ⌘V, which trails the post.
    private static let readAllowance: TimeInterval = 0.15

    /// Write the item and paste it into `previousApp`, activating it so ⌘V lands there.
    @MainActor @discardableResult
    static func paste(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?
    ) -> Bool {
        guard write(item, store: store) else { return false }
        store.promote(item)
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
        return true
    }

    /// A queued run's paste, unpromoted; returns only once the target has had time to read it.
    @MainActor
    static func pasteQueued(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?
    ) async -> Bool {
        guard write(item, store: store) else { return false }
        previousApp?.activate()
        try? await Task.sleep(for: .seconds(activationDelay))
        postCommandV()
        try? await Task.sleep(for: .seconds(readAllowance))
        return true
    }

    /// Paste only the item's text, so a file arrives as its path and the receiver's style applies.
    @MainActor @discardableResult
    static func pastePlainText(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?
    ) -> Bool {
        guard let text = item.plainText else { return false }
        pasteString(text, previousApp: previousApp)
        store.promote(item)
        return true
    }

    /// Put the item on the pasteboard without pasting; the marker stops re-capture.
    @MainActor @discardableResult
    static func copy(_ item: ClipboardItem, store: ClipboardStore) -> Bool {
        guard write(item, store: store) else { return false }
        store.promote(item)
        return true
    }

    /// Put a string on the pasteboard unmarked, so it enters history like any other copy.
    @MainActor
    static func copyPlainText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    /// String counterpart of `paste`, marker-stamped so the text doesn't re-enter history.
    @MainActor
    static func pasteString(_ text: String, previousApp: NSRunningApplication?) {
        writeString(text)
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
    }

    /// A file, pasted into `previousApp`; the receiver takes the file or its path, as it reads.
    @MainActor
    static func pasteFile(_ url: URL, previousApp: NSRunningApplication?) {
        PasteboardFiles.write(url, to: .general)
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
    }

    /// String counterpart of `copy(_:store:)`.
    @MainActor
    static func copyString(_ text: String) {
        writeString(text)
    }

    /// String counterpart of `pasteInPlace`; the palette stays frontmost.
    @MainActor
    static func pasteStringInPlace(_ text: String, into app: NSRunningApplication?) {
        writeString(text)
        guard let pid = app?.processIdentifier else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + directPostDelay) {
            postCommandV(toPid: pid)
        }
    }

    @MainActor
    private static func writeString(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, ClipboardManager.internalType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardManager.internalType)
    }

    /// Paste into `app` without activating or promoting, so the palette and its rows hold still.
    @MainActor @discardableResult
    static func pasteInPlace(
        _ item: ClipboardItem, store: ClipboardStore, into app: NSRunningApplication?
    ) -> Bool {
        guard write(item, store: store) else { return false }
        if let pid = app?.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + directPostDelay) {
                postCommandV(toPid: pid)
            }
        }
        return true
    }

    /// Whether anything was written; a vanished item leaves the pasteboard untouched.
    @MainActor @discardableResult
    static func write(
        _ item: ClipboardItem, store: ClipboardStore, to pb: NSPasteboard = .general
    ) -> Bool {
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pb.clearContents()
            pb.declareTypes([.string, ClipboardManager.internalType], owner: nil)
            pb.setString(text, forType: .string)
        case .image:
            guard let url = store.imageURL(for: item),
                let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else {
                return false
            }
            pb.clearContents()
            return pb.writeObjects([imageItem(data, type: imageType(of: url))])
        case .file:
            guard let url = store.fileURL(for: item),
                FileManager.default.fileExists(atPath: url.path)
            else { return false }
            pb.clearContents()
            pb.declareTypes([.fileURL, .string, ClipboardManager.internalType], owner: nil)
            pb.setData(url.dataRepresentation, forType: .fileURL)
            // Both types: a file-taking app receives the file, a text field receives the path.
            pb.setString(url.path, forType: .string)
        }
        pb.setData(Data(), forType: ClipboardManager.internalType)
        return true
    }

    /// The blob's own type; AppKit derives TIFF from any image type for readers that ask.
    private static func imageType(of url: URL) -> NSPasteboard.PasteboardType {
        let type = UTType(filenameExtension: url.pathExtension).flatMap {
            $0.conforms(to: .image) ? $0 : nil
        }
        return NSPasteboard.PasteboardType((type ?? .png).identifier)
    }

    /// The blob first, so a reader taking it gets it as kept; anything else is promised a PNG.
    @MainActor
    private static func imageItem(
        _ data: Data, type: NSPasteboard.PasteboardType
    ) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        item.setData(Data(), forType: ClipboardManager.internalType)
        if type != .png { promisePNG(on: item, from: data) }
        return item
    }

    /// An item `imageItem` wrote: its PNG and TIFF are derived, so a copy of the item skips them.
    @MainActor
    static func promisesPNG(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(ClipboardManager.internalType)
            && types.contains {
                $0 != .png && $0 != .tiff && UTType($0.rawValue)?.conforms(to: .image) == true
            }
    }

    @MainActor
    static func promisePNG(on item: NSPasteboardItem, from data: Data) {
        item.setDataProvider(PNGPromise(data), forTypes: [.png])
    }

    /// Encodes only when a reader asks; the pasteboard retains it until done with the promise.
    private final class PNGPromise: NSObject, NSPasteboardItemDataProvider, Sendable {
        private let data: Data

        init(_ data: Data) { self.data = data }

        nonisolated func pasteboard(
            _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            let png = NSMutableData()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let destination = CGImageDestinationCreateWithData(
                    png, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            item.setData(png as Data, forType: type)
        }
    }

    /// Synthesize ⌘V, to `pid` alone when given, else through the system tap.
    @MainActor
    static func postCommandV(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_V), toPid: pid)
    }

    /// Synthesize ⌘C, for reading a selection an app will not surface over Accessibility.
    @MainActor
    static func postCommandC(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_C), toPid: pid)
    }

    @MainActor
    private static func postCommand(key: CGKeyCode, toPid pid: pid_t?) {
        guard Permissions.ensureAccessibility() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: bestcastEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: bestcastEventTag)

        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
