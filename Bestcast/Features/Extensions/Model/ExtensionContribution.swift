import Foundation

/// The four ways an extension reaches past its own commands; each item is opted into on its own.
enum ExtensionContributionKind: String, CaseIterable, Sendable, Codable {
    case search
    case fallback
    case action
    case placeholder

    var title: String {
        switch self {
        case .search: return "Root Search"
        case .fallback: return "Fallbacks"
        case .action: return "Actions"
        case .placeholder: return "Snippet Placeholders"
        }
    }
}

/// `path` or `path.js`, then `#member`, relative to the extension; `default` when none is named.
struct ExtensionExportRef: Sendable, Hashable {
    let path: String
    let member: String

    static let maxLength = 200

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxLength else { return nil }
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let written = String(parts[0])
        let fileName = written.split(separator: "/").last ?? ""
        let path = fileName.contains(".") ? written : written + ".js"
        let member = parts.count > 1 ? String(parts[1]) : "default"
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasSuffix(".js"), !path.hasPrefix("/"), !path.hasPrefix("~"),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
            ExtensionContributions.isIdentifier(member)
        else { return nil }
        self.path = path
        self.member = member
    }

    func fileURL(in directory: URL) -> URL {
        path.split(separator: "/").reduce(directory) { $0.appendingPathComponent(String($1)) }
    }
}

/// Which launcher rows an action is offered on; `file` and the clipboard kinds are parsed ahead.
enum ExtensionActionTarget: String, CaseIterable, Sendable {
    case file
    case clipboardText = "clipboard.text"
    case clipboardImage = "clipboard.image"
    case app
    case snippet
    case quicklink
}

struct ExtensionSearchProvider: Sendable, Hashable {
    enum Mode: String, Sendable { case rows, answer }

    static let defaultResults = 3
    static let maxResults = 5

    let name: String
    let title: String
    let export: ExtensionExportRef
    /// Typed ahead of the query to address this provider alone; nil answers every query.
    let prefix: String?
    let minLength: Int
    let mode: Mode
    let maxResults: Int
}

struct ExtensionFallbackContribution: Sendable, Hashable {
    let command: String
    let title: String
}

struct ExtensionActionContribution: Sendable, Hashable {
    enum Run: Sendable, Hashable {
        case export(ExtensionExportRef)
        case command(String)
    }

    let name: String
    let title: String
    let icon: String?
    let targets: [ExtensionActionTarget]
    let run: Run
}

struct ExtensionPlaceholderContribution: Sendable, Hashable {
    let name: String
    let title: String
    let export: ExtensionExportRef
    let arguments: [String]
}

/// `package.json`'s `bestcast.contributes`, validated: a malformed entry is dropped, not guessed at.
struct ExtensionContributions: Sendable, Hashable {
    var search: [ExtensionSearchProvider] = []
    var fallbacks: [ExtensionFallbackContribution] = []
    var actions: [ExtensionActionContribution] = []
    var placeholders: [ExtensionPlaceholderContribution] = []

    static let maxPerKind = 8
    static let maxArguments = 8
    static let maxTitleLength = 80
    static let maxPrefixLength = 16
    static let maxMinLength = 32

    var isEmpty: Bool { search.isEmpty && fallbacks.isEmpty && actions.isEmpty && placeholders.isEmpty }

    /// Every contribution as the `(kind, name)` pair consent is keyed by, in declaration order.
    var items: [(kind: ExtensionContributionKind, name: String, title: String)] {
        search.map { (.search, $0.name, $0.title) } + fallbacks.map { (.fallback, $0.command, $0.title) }
            + actions.map { (.action, $0.name, $0.title) }
            + placeholders.map { (.placeholder, $0.name, $0.title) }
    }

    /// The bundles install must copy beside the built commands.
    var exportPaths: Set<String> {
        var paths = Set(search.map(\.export.path) + placeholders.map(\.export.path))
        for action in actions {
            if case .export(let ref) = action.run { paths.insert(ref.path) }
        }
        return paths
    }

    init() {}

    init(manifest: ExtensionManifest) {
        self.init(json: manifest.bestcastJSON, commandNames: Set(manifest.commands.map(\.name)))
    }

    /// `commandNames` validates fallbacks and command-backed actions against what actually ships.
    init(json: Data?, commandNames: Set<String>) {
        guard let json,
            let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
            let contributes = root["contributes"] as? [String: Any]
        else { return }
        func entries(_ key: String) -> [[String: Any]] {
            (contributes[key] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        }
        search = Self.unique(entries("search").compactMap(Self.searchProvider), by: \.name)
        fallbacks = Self.unique(
            entries("fallbacks").compactMap { Self.fallback($0, commandNames: commandNames) },
            by: \.command)
        actions = Self.unique(
            entries("actions").compactMap { Self.action($0, commandNames: commandNames) }, by: \.name)
        placeholders = Self.unique(entries("placeholders").compactMap(Self.placeholder), by: \.name)
    }

    func searchProvider(named name: String) -> ExtensionSearchProvider? {
        search.first { $0.name == name }
    }

    func action(named name: String) -> ExtensionActionContribution? {
        actions.first { $0.name == name }
    }

    func placeholder(named name: String) -> ExtensionPlaceholderContribution? {
        placeholders.first { $0.name == name }
    }

    /// Letters, digits, `-` and `_`: a name ends up in stored keys and snippet tokens.
    static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64
            && text.unicodeScalars.allSatisfy {
                ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
            }
    }

    /// An SF Symbol name; anything else would be a path the host has no business loading.
    static func isSymbolName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64
            && text.unicodeScalars.allSatisfy {
                ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "."
            }
    }

    /// Collapsed to one line and capped; a control character never reaches a label.
    static func line(_ text: String, limit: Int) -> String {
        let breaks = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        let collapsed = text.unicodeScalars.prefix(limit * 4 + 16)
            .split(whereSeparator: breaks.contains)
            .map { String(String.UnicodeScalarView($0)) }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(limit - 1, 0))) + "…"
    }

    /// Clamped as a Double first: `Int(1e300)` traps, and the manifest is not ours.
    static func clamped(_ value: Any?, default fallback: Int, to range: ClosedRange<Int>) -> Int {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return fallback }
        return Int(min(max(number, Double(range.lowerBound)), Double(range.upperBound)))
    }

    private static func title(_ value: Any?, fallback: String) -> String {
        let text = line(value as? String ?? "", limit: maxTitleLength)
        return text.isEmpty ? fallback : text
    }

    private static func unique<T>(_ values: [T], by key: KeyPath<T, String>) -> [T] {
        var seen = Set<String>()
        return Array(values.filter { seen.insert($0[keyPath: key]).inserted }.prefix(maxPerKind))
    }

    private static func identifier(_ value: Any?) -> String? {
        (value as? String).flatMap { isIdentifier($0) ? $0 : nil }
    }

    private static func export(_ value: Any?) -> ExtensionExportRef? {
        (value as? String).flatMap(ExtensionExportRef.init)
    }

    private static func searchProvider(_ json: [String: Any]) -> ExtensionSearchProvider? {
        guard let name = identifier(json["name"]), let export = export(json["export"]),
            let mode = ExtensionSearchProvider.Mode(rawValue: json["mode"] as? String ?? "rows")
        else { return nil }
        let prefix = (json["prefix"] as? String)?.trimmingCharacters(in: .whitespaces)
        if let prefix, prefix.isEmpty || prefix.count > maxPrefixLength { return nil }
        return ExtensionSearchProvider(
            name: name, title: title(json["title"], fallback: name), export: export, prefix: prefix,
            minLength: clamped(json["minLength"], default: 1, to: 1...maxMinLength), mode: mode,
            maxResults: mode == .answer
                ? 1
                : clamped(
                    json["maxResults"], default: ExtensionSearchProvider.defaultResults,
                    to: 1...ExtensionSearchProvider.maxResults))
    }

    private static func fallback(
        _ json: [String: Any], commandNames: Set<String>
    ) -> ExtensionFallbackContribution? {
        guard let command = json["command"] as? String, commandNames.contains(command) else {
            return nil
        }
        return ExtensionFallbackContribution(
            command: command, title: title(json["title"], fallback: command))
    }

    private static func action(
        _ json: [String: Any], commandNames: Set<String>
    ) -> ExtensionActionContribution? {
        guard let name = identifier(json["name"]) else { return nil }
        let targets = Set((json["on"] as? [Any] ?? []).compactMap {
            ($0 as? String).flatMap(ExtensionActionTarget.init)
        })
        guard !targets.isEmpty else { return nil }
        let run: ExtensionActionContribution.Run
        switch (json["export"] as? String, json["command"] as? String) {
        case (let export?, nil):
            guard let ref = ExtensionExportRef(export) else { return nil }
            run = .export(ref)
        case (nil, let command?):
            guard commandNames.contains(command) else { return nil }
            run = .command(command)
        default: return nil
        }
        let icon = (json["icon"] as? String).flatMap { isSymbolName($0) ? $0 : nil }
        return ExtensionActionContribution(
            name: name, title: title(json["title"], fallback: name), icon: icon,
            targets: ExtensionActionTarget.allCases.filter(targets.contains), run: run)
    }

    private static func placeholder(_ json: [String: Any]) -> ExtensionPlaceholderContribution? {
        guard let name = identifier(json["name"]), let export = export(json["export"]) else {
            return nil
        }
        let arguments = (json["arguments"] as? [Any] ?? []).compactMap {
            identifier(($0 as? [String: Any])?["name"])
        }
        return ExtensionPlaceholderContribution(
            name: name, title: title(json["title"], fallback: name), export: export,
            arguments: Array(arguments.prefix(maxArguments)))
    }
}
