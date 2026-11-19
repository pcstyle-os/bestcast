// `ClickHints`, `ClickTargetLayout` and `KeyboardScroll`: which targets get which labels, and what a
// keystroke does to them.

import Foundation

@main
struct KeyboardClickTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func check(_ name: String, _ condition: Bool) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func main() {
        labels()
        typing()
        search()
        layout()
        scroll()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func labels() {
        check("no targets, no labels", ClickHints.labels(count: 0).isEmpty)
        check("few targets take single home-row letters", ClickHints.labels(count: 3) == ["a", "s", "d"])
        check("a full alphabet stays single letters", ClickHints.labels(count: 16).allSatisfy { $0.count == 1 })
        let seventeen = ClickHints.labels(count: 17)
        check(
            "one past the alphabet gives up one letter as a prefix",
            seventeen.filter { $0.count == 1 }.count == 15 && seventeen.suffix(2) == ["aa", "as"])
        for count in [1, 16, 17, 40, 256, 257, 400] {
            let labels = ClickHints.labels(count: count)
            let prefixFree = !labels.contains { a in labels.contains { b in a != b && b.hasPrefix(a) } }
            check("\(count) labels: exact count, unique and prefix-free",
                labels.count == count && Set(labels).count == count && prefixFree)
        }
        check("256 fit in two letters", ClickHints.labels(count: 256).allSatisfy { $0.count == 2 })
        check("257 needs a third letter somewhere", ClickHints.labels(count: 257).contains { $0.count == 3 })
    }

    static func typing() {
        let labels = ["s", "d", "aa", "as"]
        check("a full label clicks its target", ClickHints.outcome(typed: "aa", labels: labels) == .hit(2))
        check("a single letter can be final", ClickHints.outcome(typed: "s", labels: labels) == .hit(0))
        check("a shared prefix narrows", ClickHints.outcome(typed: "a", labels: labels) == .narrowed)
        check("a letter no label has misses", ClickHints.outcome(typed: "ax", labels: labels) == .miss)
    }

    static func search() {
        let names = ["Reply All", "Reply", "Forward", "Mark Unread", "Unread count", "Café", ""]
        let targets = names.map { ClickTarget(frame: .zero, name: $0) }
        check("the name's start ranks first, in reading order", ClickHints.search("rep", in: targets) == [0, 1])
        check("a whole-name prefix beats a word prefix", ClickHints.search("unread", in: targets) == [4, 3])
        check("anywhere in the name still matches", ClickHints.search("ead", in: targets) == [3, 4])
        check("case and accents fold", ClickHints.search("CAFE", in: targets) == [5])
        check("blank matches nothing", ClickHints.search("  ", in: targets).isEmpty)
    }

    static func layout() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
        let targets = [
            ClickTarget(frame: CGRect(x: 10, y: 101, width: 50, height: 20), name: ""),
            ClickTarget(frame: CGRect(x: 10, y: 101, width: 50, height: 20), name: "Inbox"),
            ClickTarget(frame: CGRect(x: 300, y: 95, width: 40, height: 20), name: "Reply"),
            ClickTarget(frame: CGRect(x: 20, y: 50, width: 40, height: 20), name: "Search"),
            ClickTarget(frame: CGRect(x: 480, y: 10, width: 100, height: 20), name: "Share"),
            ClickTarget(frame: CGRect(x: 0, y: 395, width: 100, height: 20), name: "Sliver"),
            ClickTarget(frame: CGRect(x: 600, y: 10, width: 40, height: 20), name: "Offscreen"),
        ]
        let laid = ClickTargetLayout.prepare(targets, visibleIn: bounds)
        check(
            "slivers and off-window targets drop, duplicates merge",
            laid.map(\.name) == ["Share", "Search", "Inbox", "Reply"])
        check("an edge target is clipped to the window", laid.first?.frame.width == 20)
        check("tops a few points apart read as one line, left to right", laid.last?.name == "Reply")
        let many = (0..<500).map {
            ClickTarget(frame: CGRect(x: 0, y: CGFloat($0) * 30, width: 20, height: 20), name: "")
        }
        check(
            "the count is capped",
            ClickTargetLayout.prepare(many, visibleIn: CGRect(x: 0, y: 0, width: 50, height: 20_000)).count
                == ClickTargetLayout.maximumCount)
    }

    static func scroll() {
        check("j moves the content down", KeyboardScroll.offset(for: "j", viewportHeight: 600) == CGVector(dx: 0, dy: 80))
        check("h moves it left", KeyboardScroll.offset(for: "h", viewportHeight: 600) == CGVector(dx: -80, dy: 0))
        check("u is half the viewport up", KeyboardScroll.offset(for: "u", viewportHeight: 601) == CGVector(dx: 0, dy: -301))
        check("other keys do nothing", KeyboardScroll.offset(for: "x", viewportHeight: 600) == nil)
    }
}
