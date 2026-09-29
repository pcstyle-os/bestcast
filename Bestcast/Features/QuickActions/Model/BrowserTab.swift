import Foundation

/// The frontmost browser tab, as `{browser-tab}` puts it into a prompt.
struct BrowserTab: Equatable, Sendable {
    let url: String
    let title: String

    var placeholderValue: String { title.isEmpty ? url : title + "\n" + url }

    /// AppleScript per browser family; nil for an app that has no tab to ask about.
    static func script(forBundleID bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return """
                tell application id "\(bundleID)"
                    set t to current tab of front window
                    return (URL of t) & linefeed & (name of t)
                end tell
                """
        case "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser",
            "company.thebrowser.Browser":
            return """
                tell application id "\(bundleID)"
                    set t to active tab of front window
                    return (URL of t) & linefeed & (title of t)
                end tell
                """
        default:
            return nil
        }
    }

    /// The script's `URL⏎title`; a title may itself hold newlines, a URL never does.
    static func parse(_ output: String) -> BrowserTab? {
        let parts = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let url = first.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, url.contains(":") else { return nil }
        let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return BrowserTab(url: url, title: title)
    }
}
