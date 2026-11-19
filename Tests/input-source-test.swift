// `AppInputSourcePolicy`: which source an activated app gets, and what is remembered on the way.

import Foundation

@main
struct InputSourceTests {
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

    static let english = "com.apple.keylayout.ABC"
    static let polish = "com.apple.keylayout.PolishPro"

    static func main() {
        rules()
        remembering()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func rules() {
        var policy = AppInputSourcePolicy(rules: [.init(bundleID: "ghostty", sourceID: english)])
        check(
            "a pinned app gets its source",
            policy.activate("ghostty", leaving: "messages", current: polish) == english)
        check(
            "an app without a rule keeps whatever is current",
            policy.activate("messages", leaving: "ghostty", current: english) == nil)
        check(
            "a pinned app already on its source switches nothing",
            policy.activate("ghostty", leaving: "messages", current: english) == nil)
        check("keep mode remembers nothing", policy.remembered.isEmpty)
        check("rules alone make the policy active", policy.isActive)
        check("no rules and keep is off", !AppInputSourcePolicy().isActive)
    }

    static func remembering() {
        var policy = AppInputSourcePolicy(
            rules: [.init(bundleID: "zed", sourceID: english)], fallback: .remember)
        check(
            "an app seen for the first time keeps the current source",
            policy.activate("discord", leaving: nil, current: polish) == nil)
        check(
            "leaving Discord in Polish for pinned Zed switches to English",
            policy.activate("zed", leaving: "discord", current: polish) == english)
        check("Discord's Polish is remembered", policy.remembered["discord"] == polish)
        check(
            "coming back to Discord from English restores Polish",
            policy.activate("discord", leaving: "zed", current: english) == polish)
        check("a pinned app is never remembered", policy.remembered["zed"] == nil)

        _ = policy.activate("zed", leaving: "discord", current: polish)
        check(
            "the rule beats a manual switch made inside the pinned app",
            policy.activate("zed", leaving: "safari", current: polish) == english)

        _ = policy.activate("safari", leaving: "zed", current: english)
        let toDiscord = policy.activate("discord", leaving: "safari", current: polish)
        check("a source picked by hand inside Safari is what Safari remembers", policy.remembered["safari"] == polish)
        check("Discord, remembered in Polish, needs no switch from Polish", toDiscord == nil)
        check(
            "back in Safari from English, its hand-picked Polish returns",
            policy.activate("safari", leaving: "discord", current: english) == polish)
    }
}
