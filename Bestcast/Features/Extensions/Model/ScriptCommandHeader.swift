import Foundation

/// A Raycast script command's `@raycast.` header, as the live launcher rows read it.
struct ScriptCommandHeader: Sendable, Hashable {
    enum Mode: String, Sendable {
        case fullOutput, compact, silent, inline
    }

    enum Icon: Sendable, Hashable {
        case emoji(String)
        case file(URL)
    }

    static let minimumRefresh: Duration = .seconds(10)

    let url: URL
    let title: String
    /// The shared import's reading of the same header: interpreter, arguments, confirmation.
    let command: CustomCommand
    let mode: Mode
    let icon: Icon?
    let packageName: String?
    /// Only an inline command refreshes; Raycast's floor is ten seconds, and so is ours.
    let refreshTime: Duration?

    var arguments: [CustomCommandArgument] { command.arguments }
    var needsConfirmation: Bool { command.requiresConfirmation }

    init?(url: URL, source: String) {
        let directives = RaycastScriptImport.directives(in: source)
        guard directives["schemaVersion"] == "1",
            let parsed = RaycastScriptImport.command(at: url, source: source)
        else { return nil }
        self.url = url
        command = CustomCommand(
            id: Self.stableID(for: url), name: parsed.name, command: parsed.command,
            requiresConfirmation: parsed.requiresConfirmation, arguments: parsed.arguments,
            showsOutput: parsed.showsOutput, workingDirectory: parsed.workingDirectory)
        title = command.name
        mode = directives["mode"].flatMap(Mode.init(rawValue:)) ?? .fullOutput
        icon = Self.icon(directives["icon"], script: url)
        packageName = directives["packageName"]
        refreshTime = mode == .inline ? Self.refreshTime(directives["refreshTime"]) : nil
    }

    /// Derived from the path, so a rescan of an unchanged file reads as unchanged.
    static func stableID(for url: URL) -> UUID {
        let hex = [UInt64(0xcbf2_9ce4_8422_2325), 0x8422_2325_cbf2_9ce4].map { seed in
            let hash = url.path.utf8.reduce(seed) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
            let digits = String(hash, radix: 16)
            return String(repeating: "0", count: 16 - digits.count) + digits
        }.joined()
        let cuts = [8, 4, 4, 4, 12]
        var groups: [Substring] = []
        var rest = Substring(hex)
        for length in cuts {
            groups.append(rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        return UUID(uuidString: groups.joined(separator: "-"))!
    }

    /// `10s`, `5m`, `1h` or `1d`; anything else means the command never refreshes on its own.
    static func refreshTime(_ text: String?) -> Duration? {
        guard let text, let unit = text.last, let value = Double(text.dropLast()), value > 0
        else { return nil }
        let multiplier: Double
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        case "d": multiplier = 86400
        default: return nil
        }
        return max(.seconds(value * multiplier), minimumRefresh)
    }

    /// A remote icon would mean a fetch per row, so a URL is skipped rather than downloaded.
    static func icon(_ value: String?, script: URL) -> Icon? {
        guard let value, !value.isEmpty, !value.hasPrefix("http://"), !value.hasPrefix("https://")
        else { return nil }
        guard value.contains("/") || value.contains(".") else { return .emoji(value) }
        if value.hasPrefix("/") { return .file(URL(fileURLWithPath: value)) }
        guard !value.hasPrefix("~") else { return nil }
        return .file(script.deletingLastPathComponent().appendingPathComponent(value))
    }
}
