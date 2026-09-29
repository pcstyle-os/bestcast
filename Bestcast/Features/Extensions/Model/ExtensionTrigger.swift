import Foundation

/// What a trigger listens for; the raw value is the manifest's `on`.
enum ExtensionTriggerEvent: String, Sendable, CaseIterable {
    case clipboardChanged = "clipboard.changed"
    case appActivated = "app.activated"
    case appDeactivated = "app.deactivated"
    case schedule
    case systemWake = "system.wake"
    case systemSleep = "system.sleep"
    case networkChanged = "network.changed"
    case selectionHotkey = "selection.hotkey"
    case deeplink

    var title: String {
        switch self {
        case .clipboardChanged: return "When something is copied"
        case .appActivated: return "When an app comes forward"
        case .appDeactivated: return "When an app goes to the background"
        case .schedule: return "On a schedule"
        case .systemWake: return "When the Mac wakes"
        case .systemSleep: return "When the Mac sleeps"
        case .networkChanged: return "When the network changes"
        case .selectionHotkey: return "With a shortcut on the selected text"
        case .deeplink: return "From a link"
        }
    }
}

/// Where a fired trigger sends its event: a file's default export, or a no-view command.
enum ExtensionTriggerTarget: Sendable, Hashable {
    case export(String)
    case command(String)
}

/// `filter`: `kind` is the clipboard item's kind, `match` a regular expression over its text.
struct ExtensionTriggerFilter: Sendable, Hashable {
    let kind: String?
    let match: String?
}

/// One entry of a manifest's `bestcast.triggers`.
struct ExtensionTrigger: Sendable, Hashable, Identifiable {
    let name: String
    let title: String
    let event: ExtensionTriggerEvent
    let filter: ExtensionTriggerFilter?
    let target: ExtensionTriggerTarget
    /// `then`: export paths, each handed the previous step's value.
    let then: [String]
    let throttle: TimeInterval?
    let schedule: ExtensionTriggerSchedule?
    let bundleIds: [String]
    let replacesSelection: Bool

    var id: String { name }

    init?(json: Any) {
        guard let dict = json as? [String: Any], let name = dict["name"] as? String, !name.isEmpty,
            !name.contains("/"), let event = (dict["on"] as? String).flatMap(ExtensionTriggerEvent.init)
        else { return nil }
        switch (dict["export"] as? String, dict["command"] as? String) {
        case (let path?, nil) where ExtensionExportPath.isSafe(path): target = .export(path)
        case (nil, let command?) where !command.isEmpty: target = .command(command)
        default: return nil
        }
        let steps = (dict["then"] as? [[String: Any]] ?? []).map { $0["export"] as? String ?? "" }
        guard steps.allSatisfy(ExtensionExportPath.isSafe) else { return nil }
        schedule = dict["schedule"].flatMap(ExtensionTriggerSchedule.init(json:))
        guard event != .schedule || schedule != nil else { return nil }
        self.name = name
        self.event = event
        title = dict["title"] as? String ?? name
        then = steps
        filter = (dict["filter"] as? [String: Any]).map {
            ExtensionTriggerFilter(kind: $0["kind"] as? String, match: $0["match"] as? String)
        }
        throttle = ExtensionRefreshPolicy.parse(dict["throttle"] as? String, floor: 0)
        bundleIds = dict["bundleIds"] as? [String] ?? []
        // Only the hotkey knows whose selection it read; any other event would type blind.
        replacesSelection = event == .selectionHotkey && dict["replacesSelection"] as? Bool == true
    }
}

/// One entry of `bestcast.exports`: a function other code may call by name.
struct ExtensionExport: Sendable, Hashable, Identifiable {
    let name: String
    let path: String
    /// Only a public export is reachable from another extension, and then only once approved.
    let isPublic: Bool
    let description: String

    var id: String { name }

    init?(json: Any) {
        guard let dict = json as? [String: Any], let name = dict["name"] as? String, !name.isEmpty,
            !name.contains("/"), let path = dict["export"] as? String, ExtensionExportPath.isSafe(path)
        else { return nil }
        self.name = name
        self.path = path
        isPublic = dict["public"] as? Bool ?? false
        description = dict["description"] as? String ?? ""
    }
}

/// What the opt-in dialog tells a person a trigger will learn, and when its code will run.
enum ExtensionTriggerConsent {
    static func explanation(for trigger: ExtensionTrigger) -> String {
        let apps = trigger.bundleIds.isEmpty ? "any app" : trigger.bundleIds.joined(separator: ", ")
        let when: String
        switch trigger.event {
        case .clipboardChanged:
            when = "It runs each time you copy something and learns only its kind. "
                + "Turn on Share copied text to send the text too."
        case .appActivated: when = "It runs and learns the app's name whenever \(apps) comes forward."
        case .appDeactivated: when = "It runs and learns the app's name whenever \(apps) goes back."
        case .schedule: when = "It runs on its schedule while Bestcast is open."
        case .systemWake: when = "It runs each time the Mac wakes."
        case .systemSleep: when = "It runs each time the Mac goes to sleep."
        case .networkChanged:
            when = "It runs when the Mac goes online or offline, never learning which network."
        case .selectionHotkey: when = "It runs with the selected text when you press its shortcut."
        case .deeplink: when = "It runs whenever any app, script or web page opens its link."
        }
        return when + " It runs in the background with no window, until you turn it off here."
    }
}

/// An export is a file inside its extension; anything that could climb out of it is refused.
enum ExtensionExportPath {
    static func isSafe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasSuffix(".js") && !path.hasPrefix("/") && !path.hasPrefix("~")
            && parts.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }
}

extension ExtensionManifest {
    private var bestcastObject: [String: Any] {
        bestcastJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// A malformed entry is dropped, as is a second trigger reusing a name.
    var triggers: [ExtensionTrigger] {
        var seen: Set<String> = []
        return (bestcastObject["triggers"] as? [Any] ?? []).compactMap(ExtensionTrigger.init(json:))
            .filter { seen.insert($0.name).inserted }
    }

    var exports: [ExtensionExport] {
        var seen: Set<String> = []
        return (bestcastObject["exports"] as? [Any] ?? []).compactMap(ExtensionExport.init(json:))
            .filter { seen.insert($0.name).inserted }
    }

    /// Every file a trigger or export names, which install copies beside the built commands.
    var bestcastFiles: [String] {
        let triggerFiles = triggers.flatMap { trigger -> [String] in
            guard case .export(let path) = trigger.target else { return trigger.then }
            return [path] + trigger.then
        }
        return Array(Set(triggerFiles + exports.map(\.path))).sorted()
    }
}
