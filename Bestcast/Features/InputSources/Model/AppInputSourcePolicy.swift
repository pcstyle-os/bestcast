import Foundation

/// One app pinned to one keyboard input source. See docs/features/input-sources.md.
struct AppInputSourceRule: Hashable, Codable, Sendable {
    let bundleID: String
    var sourceID: String
}

/// What an app without a rule gets when it comes to the front.
enum AppInputSourceFallback: String, CaseIterable, Sendable {
    case keep
    case remember
}

/// Which source an activated app should get, and what to remember of the app it replaced.
struct AppInputSourcePolicy: Sendable {
    var rules: [AppInputSourceRule] = []
    var fallback: AppInputSourceFallback = .keep
    /// The source each rule-less app was last left in; only grows while `fallback` is `.remember`.
    var remembered: [String: String] = [:]

    var isActive: Bool { !rules.isEmpty || fallback == .remember }

    func rule(for bundleID: String) -> String? {
        rules.first { $0.bundleID == bundleID }?.sourceID
    }

    /// `current` is the source selected while `previous` was in front; nil means leave it alone.
    mutating func activate(_ bundleID: String, leaving previous: String?, current: String?) -> String? {
        if fallback == .remember, let previous, let current, rule(for: previous) == nil {
            remembered[previous] = current
        }
        let target = rule(for: bundleID) ?? (fallback == .remember ? remembered[bundleID] : nil)
        return target == current ? nil : target
    }
}
