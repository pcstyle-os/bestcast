import Foundation

@main
struct LauncherActionsTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    static func main() {
        testDeepLinkRoundTrip()
        testDeepLinkRejects()
        testPins()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) failed")
        if failures > 0 { exit(1) }
    }

    private static func roundTrips(_ key: String) -> Bool {
        guard let url = LauncherDeepLink.url(forKey: key) else { return false }
        return LauncherDeepLink.key(from: url) == key
    }

    private static func testDeepLinkRoundTrip() {
        check("a bundle ID round-trips", roundTrips("com.apple.Safari"))
        check("a command ID keeps its colon", roundTrips("command:ai-chat"))
        check("an app path keeps its slashes", roundTrips("/Applications/My App.app"))
        check(
            "a UUID entry round-trips",
            roundTrips("quicklink:4F1C2E3A-8B9D-4C7E-9F10-112233445566"))
        check("reserved query characters round-trip", roundTrips("a&b=c?d#e+f%g"))
        check("non-Latin text round-trips", roundTrips("コマンド:ü"))
        check(
            "the link is bestcast://run/ plus one segment",
            LauncherDeepLink.url(forKey: "command:ai-chat")?.absoluteString
                == "bestcast://run/command%3Aai-chat")
        check("an empty key has no link", LauncherDeepLink.url(forKey: "") == nil)
        check(
            "a trailing slash is tolerated",
            LauncherDeepLink.key(from: URL(string: "bestcast://run/com.apple.Safari/")!)
                == "com.apple.Safari")
        check(
            "scheme and host compare case-insensitively",
            LauncherDeepLink.key(from: URL(string: "BestCast://RUN/com.apple.Safari")!)
                == "com.apple.Safari")
    }

    private static func testDeepLinkRejects() {
        let rejected = [
            "bestcast://extensions/raycast/clipboard/history",
            "raycast://run/com.apple.Safari",
            "bestcast://run",
            "bestcast://run/",
            "bestcast://run/a/b",
            "https://run/com.apple.Safari",
        ]
        for link in rejected {
            check("\(link) is not a launcher link", LauncherDeepLink.key(from: URL(string: link)!) == nil)
        }
    }

    private static func testPins() {
        let ranked = ["a", "b", "c", "d", "e"]
        check(
            "no pins leaves the order alone",
            LauncherPins.leading(ranked, pinned: [], key: { $0 }) == ranked)
        check(
            "pinned rows lead, each half keeping relevance order",
            LauncherPins.leading(ranked, pinned: ["d", "b"], key: { $0 }) == ["b", "d", "a", "c", "e"])
        check(
            "a pin that did not match adds nothing",
            LauncherPins.leading(ranked, pinned: ["z"], key: { $0 }) == ranked)
        check(
            "normalizing drops blanks and repeats, first spelling wins",
            LauncherPins.normalized(["b", "", "a", "b", "c", "a"]) == ["b", "a", "c"])
    }
}
