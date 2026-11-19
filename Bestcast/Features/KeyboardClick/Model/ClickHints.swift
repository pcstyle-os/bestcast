import CoreGraphics
import Foundation

/// Hint labels, and what typing into them or into a name means. See docs/features/keyboard-click.md.
enum ClickHints {
    /// The home row first, so a window with few targets never leaves it.
    static let alphabet = Array("asdfghjklqweruio")

    enum Outcome: Equatable {
        case hit(Int)
        case narrowed
        /// No label starts this way: the keystroke is dropped rather than ending the session.
        case miss
    }

    /// The shortest labels that stay prefix-free, so a full label is always final.
    static func labels(count: Int, alphabet: [Character] = alphabet) -> [String] {
        guard count > 0, alphabet.count > 1 else { return [] }
        var labels = [""]
        var next = 0
        while next == 0 || labels.count - next < count {
            let stem = labels[next]
            next += 1
            labels += alphabet.map { stem + String($0) }
        }
        return Array(labels[next..<(next + count)])
    }

    static func outcome(typed: String, labels: [String]) -> Outcome {
        if let index = labels.firstIndex(of: typed) { return .hit(index) }
        return labels.contains { $0.hasPrefix(typed) } ? .narrowed : .miss
    }

    /// Targets matching a typed name: the name's start, then a word's, then anywhere.
    static func search(_ query: String, in targets: [ClickTarget]) -> [Int] {
        let query = fold(query.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return [] }
        let ranked = targets.indices.compactMap { index -> (rank: Int, index: Int)? in
            let name = fold(targets[index].name)
            guard name.contains(query) else { return nil }
            if name.hasPrefix(query) { return (0, index) }
            let words = name.split { !$0.isLetter && !$0.isNumber }
            return (words.contains { $0.hasPrefix(query) } ? 1 : 2, index)
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.index)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// How far a scroll key scrolls the view, positive down and right.
enum KeyboardScroll {
    static let step: CGFloat = 80

    static func offset(for key: Character, viewportHeight: CGFloat) -> CGVector? {
        switch key {
        case "j": CGVector(dx: 0, dy: step)
        case "k": CGVector(dx: 0, dy: -step)
        case "l": CGVector(dx: step, dy: 0)
        case "h": CGVector(dx: -step, dy: 0)
        case "d": CGVector(dx: 0, dy: (viewportHeight / 2).rounded())
        case "u": CGVector(dx: 0, dy: -(viewportHeight / 2).rounded())
        default: nil
        }
    }
}
