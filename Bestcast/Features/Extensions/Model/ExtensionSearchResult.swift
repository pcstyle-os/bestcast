import Foundation

/// What a contributed row may do; the host performs it, so the extension never touches the UI.
enum ExtensionContributionAction: Sendable, Hashable {
    case copy(String, title: String?)
    case paste(String, title: String?)
    /// A web address or an absolute file path; any other scheme is refused at decode.
    case open(String, title: String?)
    /// One of the extension's own commands, handed the arguments.
    case launch(command: String, arguments: [String: String], title: String?)

    static let maxContentLength = 20_000
    static let maxArguments = 8

    var title: String {
        switch self {
        case .copy(_, let title): return title ?? "Copy to Clipboard"
        case .paste(_, let title): return title ?? "Paste to Active App"
        case .open(_, let title): return title ?? "Open"
        case .launch(_, _, let title): return title ?? "Open Command"
        }
    }

    var systemImage: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .open: return "arrow.up.forward.app"
        case .launch: return "puzzlepiece.extension"
        }
    }

    init?(json: JSONValue) {
        guard let object = json.objectValue, let type = object["type"]?.stringValue else {
            return nil
        }
        let title = object["title"]?.stringValue
            .map { ExtensionContributions.line($0, limit: ExtensionContributions.maxTitleLength) }
            .flatMap { $0.isEmpty ? nil : $0 }
        switch type {
        case "copy", "paste":
            guard let content = object["content"]?.stringValue, !content.isEmpty,
                content.count <= Self.maxContentLength
            else { return nil }
            self = type == "copy" ? .copy(content, title: title) : .paste(content, title: title)
        case "open":
            guard let target = object["target"]?.stringValue, Self.isOpenable(target) else {
                return nil
            }
            self = .open(target, title: title)
        case "launch":
            guard let command = object["command"]?.stringValue,
                ExtensionContributions.isIdentifier(command)
            else { return nil }
            let pairs = (object["arguments"]?.objectValue ?? [:])
                .compactMap { key, value in value.stringValue.map { (key, $0) } }
                .filter { ExtensionContributions.isIdentifier($0.0) && $0.1.count <= 1_000 }
                .sorted { $0.0 < $1.0 }
                .prefix(Self.maxArguments)
            self = .launch(
                command: command, arguments: Dictionary(uniqueKeysWithValues: Array(pairs)),
                title: title)
        default:
            return nil
        }
    }

    /// No custom schemes: one could launch any app that registered it, unasked.
    static func isOpenable(_ target: String) -> Bool {
        guard target.count <= 2_048 else { return false }
        if target.hasPrefix("/") { return !target.contains("\0") }
        guard let url = URL(string: target), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}

/// One host-drawn row; everything in it has been trimmed to a size a list row can carry.
struct ExtensionSearchItem: Sendable, Hashable, Identifiable {
    enum Style: Sendable, Hashable { case row, answer }

    let id: String
    let title: String
    let subtitle: String?
    /// An SF Symbol name only: an extension never hands the host an image to load.
    let icon: String?
    let accessory: String?
    let style: Style
    /// The first is ↵; the rest are ⌘K.
    let actions: [ExtensionContributionAction]
}

/// A provider's return value, decoded against its manifest's caps.
enum ExtensionSearchOutput {
    static let maxTitleLength = 120
    static let maxSubtitleLength = 160
    static let maxAccessoryLength = 32
    static let maxAnswerLength = 600
    static let maxActions = 5
    static let maxIDLength = 64

    /// Anything unusable decodes to no rows, so a provider's bug costs its own section only.
    static func items(from value: JSONValue, mode: ExtensionSearchProvider.Mode, limit: Int)
        -> [ExtensionSearchItem]
    {
        switch mode {
        case .answer:
            return answer(from: value).map { [$0] } ?? []
        case .rows:
            let list = value.arrayValue ?? value.objectValue?["items"]?.arrayValue ?? []
            var seen = Set<String>()
            var items: [ExtensionSearchItem] = []
            for (index, element) in list.enumerated() {
                guard items.count < limit else { break }
                guard let item = row(from: element, index: index), seen.insert(item.id).inserted
                else { continue }
                items.append(item)
            }
            return items
        }
    }

    private static func row(from value: JSONValue, index: Int) -> ExtensionSearchItem? {
        guard let object = value.objectValue,
            case let title = clip(object["title"]?.stringValue ?? "", maxTitleLength),
            !title.isEmpty
        else { return nil }
        let rawID = object["id"]?.stringValue.map { clip($0, maxIDLength) }
        let id = rawID.flatMap { $0.isEmpty ? nil : $0 } ?? "item-\(index)"
        let actions = (object["actions"]?.arrayValue ?? [])
            .compactMap(ExtensionContributionAction.init(json:))
        return ExtensionSearchItem(
            id: id, title: title,
            subtitle: optionalLine(object["subtitle"], limit: maxSubtitleLength),
            icon: object["icon"]?.stringValue.flatMap {
                ExtensionContributions.isSymbolName($0) ? $0 : nil
            },
            accessory: optionalLine(object["accessory"], limit: maxAccessoryLength),
            style: .row,
            actions: Array((actions.isEmpty ? [.copy(title, title: nil)] : actions).prefix(maxActions)))
    }

    /// A bare string, or `{ title, actions? }`; the answer copies itself when it names no action.
    private static func answer(from value: JSONValue) -> ExtensionSearchItem? {
        let object = value.objectValue
        let text = clip(value.stringValue ?? object?["title"]?.stringValue ?? "", maxAnswerLength)
        guard !text.isEmpty else { return nil }
        let actions = (object?["actions"]?.arrayValue ?? [])
            .compactMap(ExtensionContributionAction.init(json:))
        return ExtensionSearchItem(
            id: "answer", title: text,
            subtitle: optionalLine(object?["subtitle"], limit: maxSubtitleLength),
            icon: nil, accessory: nil, style: .answer,
            actions: Array((actions.isEmpty ? [.copy(text, title: "Copy Answer")] : actions)
                .prefix(maxActions)))
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        ExtensionContributions.line(text, limit: limit)
    }

    private static func optionalLine(_ value: JSONValue?, limit: Int) -> String? {
        value?.stringValue.map { clip($0, limit) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
