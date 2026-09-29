// Which Settings pane lists a built-in command: the table ⌘K's Configure Command opens from.

import Foundation

@main
@MainActor
struct CommandOwnerTests {
    static var failures = 0
    static var passes = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func main() {
        roundTrip()
        uniqueness()
        spotChecks()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func roundTrip() {
        for tab in SettingsTab.allCases {
            for command in tab.ownedCommands {
                check(
                    "\(command) names the pane that lists it", command.owner == tab,
                    "got \(String(describing: command.owner)), want \(tab)")
            }
        }
    }

    /// The owner table keeps the last pane it sees, so a second listing would move a command.
    static func uniqueness() {
        var seen: [CommandID: SettingsTab] = [:]
        for tab in SettingsTab.allCases {
            for command in tab.ownedCommands {
                if let earlier = seen[command] {
                    check("\(command) is listed by one pane", false, "\(earlier) and \(tab)")
                }
                seen[command] = tab
            }
        }
        check("some pane owns a command", !seen.isEmpty)
        check(
            "Settings › Commands owns nothing itself: its rows are the unowned commands",
            SettingsTab.commands.ownedCommands.isEmpty)
        for command in CommandID.allCases where seen[command] == nil {
            check("\(command) falls back to Settings › Commands", command.owner == nil)
        }
    }

    static func spotChecks() {
        check("Clipboard History opens Clipboard", CommandID.clipboardHistory.owner == .clipboard)
        check("Search Emoji opens Emoji & Symbols", CommandID.searchEmoji.owner == .emoji)
        check("Fix Grammar opens Quick Actions", CommandID.fixGrammar.owner == .quickActions)
        check(
            "Browse AI Commands opens Quick Actions",
            CommandID.browseAICommands.owner == .quickActions)
        check("Create Quicklink opens Quicklinks", CommandID.createQuicklink.owner == .quicklinks)
        check("Calculator History has no feature pane", CommandID.calculatorHistory.owner == nil)
        check("Open Camera has no feature pane", CommandID.openCamera.owner == nil)
    }
}
