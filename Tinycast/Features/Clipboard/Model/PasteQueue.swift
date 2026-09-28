import Foundation

/// The entries marked for Paste Sequentially, pasted one per press in the order they were marked.
struct PasteQueue: Equatable, Sendable {
    /// One press of a run: the entry pasted, its place in the run, and whether the run ended.
    struct Step: Equatable, Sendable {
        let item: ClipboardItem
        let position: Int
        let total: Int

        var isLast: Bool { position == total }

        var message: String {
            let count = "Pasted \(position) of \(total)"
            return isLast ? count + " · Queue finished" : count
        }
    }

    /// Paste Next's presses, one paste at a time in press order, so no write lands before a ⌘V.
    struct Pacer: Equatable, Sendable {
        enum Admission: Equatable, Sendable {
            case paste
            /// Runs once the paste in flight has posted its ⌘V and the target has read it.
            case wait
            /// A press already waits, so this is the key repeating; queuing it would run ahead.
            case ignore
        }

        private(set) var isPasting = false
        private(set) var isWaiting = false

        mutating func press() -> Admission {
            guard isPasting else {
                isPasting = true
                return .paste
            }
            guard !isWaiting else { return .ignore }
            isWaiting = true
            return .wait
        }

        /// The paste in flight has landed; true when the waiting press takes its turn now.
        mutating func finish() -> Bool {
            guard isWaiting else {
                isPasting = false
                return false
            }
            isWaiting = false
            return true
        }
    }

    private(set) var ids: [ClipboardItem.ID] = []
    /// How far the run has got: `ids[pasted...]` is what the next presses paste.
    private(set) var pasted = 0

    var pending: ArraySlice<ClipboardItem.ID> { ids[pasted...] }

    var hasPending: Bool { pasted < ids.count }

    /// The run position a pending entry will paste at, so its badge and its HUD agree.
    func position(of id: ClipboardItem.ID) -> Int? {
        pending.firstIndex(of: id).map { $0 + 1 }
    }

    /// Unmarks a pending entry; marks anything else, an already-pasted one included, at the end.
    mutating func toggle(_ id: ClipboardItem.ID) {
        if let index = pending.firstIndex(of: id) {
            ids.remove(at: index)
            return
        }
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            pasted -= 1
        }
        ids.append(id)
    }

    /// Drops what `resolve` no longer finds first, so the last press knows it is last.
    mutating func advance(resolve: (ClipboardItem.ID) -> ClipboardItem?) -> Step? {
        guard let item = dropDeleted(resolve: resolve).first else {
            self = PasteQueue()
            return nil
        }
        pasted += 1
        let step = Step(item: item, position: pasted, total: ids.count)
        if step.isLast { self = PasteQueue() }
        return step
    }

    /// Closes the numbering over deleted entries; what the run already pasted keeps its count.
    @discardableResult
    mutating func dropDeleted(resolve: (ClipboardItem.ID) -> ClipboardItem?) -> [ClipboardItem] {
        let live = pending.compactMap(resolve)
        ids = Array(ids[..<pasted]) + live.map(\.id)
        return live
    }

    /// Paste All's text: each pending entry's plain text on a line of its own; an image has none.
    func joinedText(resolve: (ClipboardItem.ID) -> ClipboardItem?) -> String? {
        let texts = pending.compactMap { resolve($0)?.plainText }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}
