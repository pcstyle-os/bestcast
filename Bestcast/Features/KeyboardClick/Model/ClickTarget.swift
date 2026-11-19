import CoreGraphics
import Foundation

/// One thing a hint can click, in AX space: top-left origin, the space `CGEvent` posts in too.
struct ClickTarget: Equatable, Sendable {
    var frame: CGRect
    var name: String
}

/// Which targets get a hint, and in what order. See docs/features/keyboard-click.md.
enum ClickTargetLayout {
    /// Smaller than this is a sliver of something scrolled away, not a thing to aim at.
    static let minimumSide: CGFloat = 6
    static let maximumCount = 400
    /// Tops this close read as one line, so a row's controls label left to right.
    private static let lineHeight: CGFloat = 8

    /// Clipped to what shows, one per frame, in reading order.
    static func prepare(_ targets: [ClickTarget], visibleIn bounds: CGRect) -> [ClickTarget] {
        var index: [[Int]: Int] = [:]
        var kept: [ClickTarget] = []
        for target in targets {
            let clipped = target.frame.intersection(bounds)
            guard !clipped.isNull, clipped.width >= minimumSide, clipped.height >= minimumSide else {
                continue
            }
            let key = [clipped.minX, clipped.minY, clipped.width, clipped.height].map { Int($0.rounded()) }
            // A row and its only cell share a frame; the first keeps it, the named one names it.
            if let existing = index[key] {
                if kept[existing].name.isEmpty { kept[existing].name = target.name }
                continue
            }
            index[key] = kept.count
            kept.append(ClickTarget(frame: clipped, name: target.name))
        }
        var ordered: [ClickTarget] = []
        var line: [ClickTarget] = []
        for target in kept.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            if let first = line.first, target.frame.minY - first.frame.minY > lineHeight {
                ordered += line.sorted { $0.frame.minX < $1.frame.minX }
                line = []
            }
            line.append(target)
        }
        ordered += line.sorted { $0.frame.minX < $1.frame.minX }
        return Array(ordered.prefix(maximumCount))
    }
}
