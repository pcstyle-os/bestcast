// `KeystrokeFeed`: how presses group into the overlay's items, what Shortcuts Only keeps, and when
// items leave.

import Foundation

@main
struct KeystrokeOverlayTests {
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

    static let start = Date(timeIntervalSinceReferenceDate: 1000)

    static func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    static func letter(_ c: String) -> KeystrokePress {
        KeystrokePress(keycaps: [c.uppercased()], typed: c, isShortcut: false)
    }

    static let space = KeystrokePress(keycaps: ["Space"], typed: " ", isShortcut: false)
    static let commandK = KeystrokePress(keycaps: ["⌘", "K"], typed: nil, isShortcut: true)
    static let hyperW = KeystrokePress(keycaps: ["✦", "W"], typed: nil, isShortcut: true)
    static let returnKey = KeystrokePress(keycaps: ["↵"], typed: nil, isShortcut: false)

    static func contents(_ feed: KeystrokeFeed) -> [KeystrokeFeed.Item.Content] { feed.items.map(\.content) }

    static func main() {
        var feed = KeystrokeFeed()
        for (i, c) in ["h", "i"].enumerated() { feed.record(letter(c), at: at(Double(i) * 0.2), filter: .allKeys) }
        feed.record(space, at: at(0.5), filter: .allKeys)
        feed.record(letter("y"), at: at(0.6), filter: .allKeys)
        check("typing runs into one item, spaces included", contents(feed) == [.text("hi y")])

        feed.record(commandK, at: at(0.7), filter: .allKeys)
        feed.record(commandK, at: at(0.9), filter: .allKeys)
        feed.record(commandK, at: at(1.1), filter: .allKeys)
        check("a repeated combo counts up", contents(feed) == [.text("hi y"), .keys(["⌘", "K"], count: 3)])

        feed.record(commandK, at: at(2.5), filter: .allKeys)
        check(
            "after a pause the same combo starts over",
            contents(feed).last == .keys(["⌘", "K"], count: 1) && feed.items.count == 3)

        feed.record(letter("a"), at: at(2.6), filter: .allKeys)
        check("a letter after a combo is a new run", contents(feed).last == .text("a"))

        var pause = KeystrokeFeed()
        pause.record(letter("a"), at: at(0), filter: .allKeys)
        pause.record(letter("b"), at: at(1.5), filter: .allKeys)
        check("a pause splits a run", contents(pause) == [.text("a"), .text("b")])

        var blank = KeystrokeFeed()
        blank.record(space, at: at(0), filter: .allKeys)
        check("a space with no run shows as its key", contents(blank) == [.keys(["Space"], count: 1)])

        var shortcuts = KeystrokeFeed()
        for press in [letter("a"), hyperW, returnKey, letter("b"), commandK] {
            shortcuts.record(press, at: at(0), filter: .shortcuts)
        }
        check(
            "shortcuts only drops typing and plain keys, keeps ✦",
            contents(shortcuts) == [.keys(["✦", "W"], count: 1), .keys(["⌘", "K"], count: 1)])

        var long = KeystrokeFeed()
        for i in 0..<30 { long.record(letter(String(UnicodeScalar(97 + i % 26)!)), at: at(Double(i) * 0.1), filter: .allKeys) }
        if case .text(let run) = long.items.first?.content {
            check("a long run keeps its tail", run.count == KeystrokeFeed.maximumRun && run.hasSuffix("cd"))
        } else {
            check("a long run stays one item", false)
        }

        var crowd = KeystrokeFeed()
        for (i, key) in ["A", "B", "C", "D", "E"].enumerated() {
            crowd.record(KeystrokePress(keycaps: ["⌘", key], typed: nil, isShortcut: true), at: at(Double(i) * 0.1), filter: .allKeys)
        }
        check(
            "the oldest item leaves past the cap",
            crowd.items.count == KeystrokeFeed.maximumItems && contents(crowd).first == .keys(["⌘", "B"], count: 1))

        var aging = KeystrokeFeed()
        aging.record(commandK, at: at(0), filter: .allKeys)
        aging.record(letter("x"), at: at(1.5), filter: .allKeys)
        check("the next expiry is the oldest item's", aging.nextExpiry == at(2))
        aging.prune(at: at(2.1))
        check("an item leaves once it lingers out", contents(aging) == [.text("x")])
        aging.prune(at: at(3.6))
        check("and the feed empties", aging.items.isEmpty && aging.nextExpiry == nil)

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
