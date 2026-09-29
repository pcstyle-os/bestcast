import Foundation

/// One Bestcast feature an extension may reach through `@bestcast/api`, as `package.json` names it.
enum ExtensionCapability: String, CaseIterable, Codable, Sendable {
    case clipboardHistoryRead = "clipboardHistory.read"
    case snippetsRead = "snippets.read"
    case snippetsWrite = "snippets.write"
    case notesRead = "notes.read"
    case notesWrite = "notes.write"
    case quicklinksRead = "quicklinks.read"
    case quicklinksWrite = "quicklinks.write"
    case windowsRead = "windows.read"
    case windowsWrite = "windows.write"
    case calendarRead = "calendar.read"
    case calculator
    case aiHandoff = "ai.handoff"
    case aiTools = "ai.tools"

    /// A write asks on every call unless the user chose Always Allow.
    var isWrite: Bool {
        switch self {
        case .snippetsWrite, .notesWrite, .quicklinksWrite, .windowsWrite: true
        default: false
        }
    }

    /// Reads nothing private and changes nothing, so a declaration alone is enough.
    var needsPrompt: Bool { self != .calculator && self != .aiHandoff }

    /// Raycast's own APIs reach these without a declaration; the grant still applies.
    var isImplicitForRaycastAPI: Bool {
        switch self {
        case .windowsRead, .windowsWrite, .snippetsWrite, .quicklinksWrite: true
        default: false
        }
    }

    /// The end of "<Extension> wants to …", and the row title in Settings.
    var title: String {
        switch self {
        case .clipboardHistoryRead: "read your clipboard history"
        case .snippetsRead: "read your snippets"
        case .snippetsWrite: "create snippets"
        case .notesRead: "read your note"
        case .notesWrite: "add to your note"
        case .quicklinksRead: "read your quicklinks"
        case .quicklinksWrite: "create and open quicklinks"
        case .windowsRead: "see your open windows"
        case .windowsWrite: "move and resize your windows"
        case .calendarRead: "read your calendar events"
        case .calculator: "use the calculator"
        case .aiHandoff: "open Quick AI and AI Chat"
        case .aiTools: "run Bestcast's AI tools"
        }
    }
}

extension ExtensionManifest {
    /// `bestcast.capabilities`, keeping only names Bestcast knows; the rest are reported, not kept.
    var declaredCapabilities: Set<ExtensionCapability> { bestcastCapabilities.known }

    /// Declared names Bestcast does not recognise, for a debug log.
    var unknownCapabilities: [String] { bestcastCapabilities.unknown }

    private var bestcastCapabilities: (known: Set<ExtensionCapability>, unknown: [String]) {
        guard let bestcastJSON,
            let object = try? JSONSerialization.jsonObject(with: bestcastJSON) as? [String: Any],
            let names = object["capabilities"] as? [Any]
        else { return ([], []) }
        var known: Set<ExtensionCapability> = []
        var unknown: [String] = []
        for name in names {
            guard let name = name as? String else { continue }
            if let capability = ExtensionCapability(rawValue: name) {
                known.insert(capability)
            } else {
                unknown.append(name)
            }
        }
        return (known, unknown)
    }
}
