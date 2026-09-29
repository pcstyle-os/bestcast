import Foundation

/// Asks the frontmost browser for its tab, which only Apple Events can do.
enum BrowserTabReader {
    /// -1743 is a refusal in Automation settings; -1744 is the prompt still waiting for an answer.
    private static let automationDenied: Set<Int> = [-1_743, -1_744]

    static func read(bundleID: String?, name: String) async throws -> BrowserTab {
        guard let bundleID, let source = BrowserTab.script(forBundleID: bundleID) else {
            throw QuickActionFailure.noBrowser
        }
        return try await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else {
                throw QuickActionFailure.browserUnreadable(name)
            }
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                throw automationDenied.contains(number)
                    ? QuickActionFailure.browserAutomationDenied(name)
                    : .browserUnreadable(name)
            }
            guard let tab = BrowserTab.parse(result.stringValue ?? "") else {
                throw QuickActionFailure.browserUnreadable(name)
            }
            return tab
        }.value
    }
}
