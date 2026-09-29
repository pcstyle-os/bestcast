import Foundation
import Observation

/// One trip through the note's AI menu: pick an action, watch the reply arrive, keep or drop it.
@MainActor
@Observable
final class NoteAISession {
    enum Phase: Equatable {
        case menu
        case running
        case preview
        case failed(String)
    }

    /// The note as it was when the menu opened; a reply only ever lands on that exact text.
    let source: String
    let target: NoteAITarget
    let noteTitle: String
    private(set) var phase = Phase.menu
    private(set) var level = NoteAIMenu.Level.root
    private(set) var action: NoteAIAction?
    private(set) var reply = ""
    private(set) var selectedIndex = 0
    private(set) var focusRevision = 0
    var query = "" {
        didSet { selectedIndex = 0 }
    }

    @ObservationIgnored private let languages: [String]
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var cachedDiff: [TextDiffEngine.Chunk]?

    init(source: String, target: NoteAITarget, noteTitle: String, languages: [String]) {
        self.source = source
        self.target = target
        self.noteTitle = noteTitle
        self.languages = languages
    }

    var items: [NoteAIMenu.Item] {
        NoteAIMenu.items(level: level, query: query, languages: languages)
    }

    var selectedItem: NoteAIMenu.Item? {
        let items = items
        return items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// Only a replacement reads as a diff; an insertion is new text with nothing to compare.
    var diff: [TextDiffEngine.Chunk] {
        guard phase == .preview, action?.placement == .replace else { return [] }
        if let cachedDiff { return cachedDiff }
        let chunks = TextDiffEngine.diff(original: target.text, modified: reply)
        cachedDiff = chunks
        return chunks
    }

    func moveSelection(by offset: Int) {
        let count = items.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + offset + count) % count
    }

    func select(_ item: NoteAIMenu.Item) {
        selectedIndex = items.firstIndex(of: item) ?? selectedIndex
    }

    func open(_ level: NoteAIMenu.Level) {
        self.level = level
        query = ""
        focusRevision &+= 1
    }

    /// False once there is nowhere left to step back to, so Escape closes the menu instead.
    func back() -> Bool {
        switch phase {
        case .running, .preview, .failed:
            request?.cancel()
            request = nil
            phase = .menu
            reply = ""
            action = nil
            cachedDiff = nil
            focusRevision &+= 1
            return true
        case .menu where level != .root:
            open(.root)
            return true
        case .menu:
            return false
        }
    }

    func run(_ action: NoteAIAction, using provider: any AIProvider) {
        request?.cancel()
        self.action = action
        reply = ""
        cachedDiff = nil
        phase = .running
        let text = target.text
        let request = AIRequest(
            instructions: action.instructions,
            messages: [AIMessage(role: .user, text: action.message(for: text))],
            maxOutputTokens: action.maxOutputTokens(for: text))
        self.request = Task { [weak self] in
            do {
                let reply = try await QuickActionRunner.stream(request, using: provider) { delta in
                    guard let self, !Task.isCancelled else { return }
                    self.reply += delta
                }
                guard let self, !Task.isCancelled else { return }
                self.reply = reply
                self.phase = .preview
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }

    func cancel() {
        request?.cancel()
        request = nil
    }
}
