import Foundation

/// A built-in call with its arguments checked, so a runner only ever acts on well-formed values.
enum BuiltInToolRequest: Equatable, Sendable {
    case clipboardSearch(query: String, limit: Int)
    case clipboardRead(id: String)
    case clipboardCopy(text: String)
    case snippetsSearch(query: String, limit: Int)
    case snippetsCreate(name: String, text: String, keyword: String?)
    case notesRead
    case notesAppend(text: String)
    case calendarEvents(DateInterval)
    case appsRunning
    case appsOpen(name: String)
    case appsArrangeWindow(WindowCommand.ID)
    case filesSearch(query: String, limit: Int)
    case filesRead(path: String)
    case quicklinksList
    case quicklinksOpen(name: String, argument: String?)
    case calculate(expression: String)
    case frontmostApp
    case selectedText

    static let defaultLimit = 10
    static let maxLimit = 25
    static let maxCalendarDays = 31
    /// What a write may carry in; a model that wants to copy a book should be told no, not obeyed.
    static let maxWriteBytes = 64 * 1024

    struct Failure: Error, Equatable, Sendable {
        let message: String
    }

    /// `now` and `calendar` decide what "today" is, so a harness can pin both.
    static func parse(
        _ tool: BuiltInTool, arguments raw: String, now: Date, calendar: Calendar
    ) -> Result<BuiltInToolRequest, Failure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let object: [String: JSONValue]
        if trimmed.isEmpty {
            object = [:]
        } else if let parsed = JSONValue(data: Data(trimmed.utf8))?.objectValue {
            object = parsed
        } else {
            return .failure(Failure(message: "The arguments were not a JSON object."))
        }
        let arguments = Arguments(values: object)
        do {
            return .success(try request(tool, arguments, now: now, calendar: calendar))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
    }

    private static func request(
        _ tool: BuiltInTool, _ arguments: Arguments, now: Date, calendar: Calendar
    ) throws -> BuiltInToolRequest {
        switch (tool.integration, tool.name) {
        case (.clipboard, "search"):
            return .clipboardSearch(query: arguments.optional("query"), limit: try arguments.limit())
        case (.clipboard, "read"):
            return .clipboardRead(id: try arguments.required("id"))
        case (.clipboard, "copy"):
            return .clipboardCopy(text: try arguments.writable("text", trims: false))
        case (.snippets, "search"):
            return .snippetsSearch(query: arguments.optional("query"), limit: try arguments.limit())
        case (.snippets, "create"):
            let keyword = arguments.optional("keyword")
            return .snippetsCreate(
                name: try arguments.writable("name", trims: true),
                text: try arguments.writable("text", trims: false),
                keyword: keyword.isEmpty ? nil : keyword)
        case (.notes, "read"):
            return .notesRead
        case (.notes, "append"):
            return .notesAppend(text: try arguments.writable("text", trims: false))
        case (.calendar, "events"):
            return .calendarEvents(
                try calendarSpan(
                    start: arguments.optional("start"), end: arguments.optional("end"), now: now,
                    calendar: calendar))
        case (.apps, "running"):
            return .appsRunning
        case (.apps, "open"):
            return .appsOpen(name: try arguments.required("name"))
        case (.apps, "arrange_window"):
            let action = try arguments.required("action")
            guard let id = WindowCommand.ID(rawValue: action),
                BuiltInToolCatalog.windowActions.contains(id)
            else { throw Failure(message: "“\(action)” is not a window action.") }
            return .appsArrangeWindow(id)
        case (.files, "search"):
            return .filesSearch(query: try arguments.required("query"), limit: try arguments.limit())
        case (.files, "read"):
            return .filesRead(path: try arguments.required("path"))
        case (.quicklinks, "list"):
            return .quicklinksList
        case (.quicklinks, "open"):
            let argument = arguments.optional("argument", trims: false)
            return .quicklinksOpen(
                name: try arguments.required("name"), argument: argument.isEmpty ? nil : argument)
        case (.calculator, "evaluate"):
            return .calculate(expression: try arguments.required("expression"))
        case (.system, "frontmost_app"):
            return .frontmostApp
        case (.system, "selected_text"):
            return .selectedText
        default:
            throw Failure(message: "Tinycast has no tool called \(tool.wireName).")
        }
    }

    /// Whole days, inclusive at both ends, from midnight to midnight in `calendar`'s zone.
    static func calendarSpan(
        start: String, end: String, now: Date, calendar: Calendar
    ) throws -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let first = start.isEmpty ? today : try day(start, calendar: calendar)
        let last = end.isEmpty ? first : try day(end, calendar: calendar)
        guard last >= first else { throw Failure(message: "The end day is before the start day.") }
        let days = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        guard days <= maxCalendarDays else {
            throw Failure(message: "Ask for at most \(maxCalendarDays) days at a time.")
        }
        guard let stop = calendar.date(byAdding: .day, value: 1, to: last) else {
            throw Failure(message: "That span could not be read.")
        }
        return DateInterval(start: first, end: stop)
    }

    private static func day(_ text: String, calendar: Calendar) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let date = calendar.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
            calendar.component(.month, from: date) == parts[1]
        else { throw Failure(message: "“\(text)” is not a day in YYYY-MM-DD form.") }
        return calendar.startOfDay(for: date)
    }

    private struct Arguments {
        let values: [String: JSONValue]

        func optional(_ key: String, trims: Bool = true) -> String {
            guard let value = values[key]?.stringValue else { return "" }
            return trims ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value
        }

        func required(_ key: String) throws -> String {
            let value = optional(key)
            guard !value.isEmpty else { throw Failure(message: "`\(key)` is required.") }
            return value
        }

        func writable(_ key: String, trims: Bool) throws -> String {
            let value = optional(key, trims: trims)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(message: "`\(key)` is required.")
            }
            guard value.utf8.count <= BuiltInToolRequest.maxWriteBytes else {
                throw Failure(message: "`\(key)` is longer than Tinycast accepts.")
            }
            return value
        }

        func limit() throws -> Int {
            guard let value = values["limit"] else { return BuiltInToolRequest.defaultLimit }
            guard let number = value.intValue else { throw Failure(message: "`limit` is a number.") }
            return min(max(number, 1), BuiltInToolRequest.maxLimit)
        }
    }
}

/// What the consent dialog says about one write, so the user sees exactly what will happen.
struct BuiltInToolPrompt: Equatable, Sendable {
    let title: String
    let message: String
    let confirmTitle: String

    /// Long enough to judge, short enough that the dialog stays a dialog.
    static let previewLength = 400

    /// `subject` is what the runner resolved: the note's title, the app, the quicklink's link.
    static func make(for request: BuiltInToolRequest, subject: String?) -> BuiltInToolPrompt? {
        switch request {
        case .clipboardCopy(let text):
            return BuiltInToolPrompt(
                title: "Copy to the clipboard?", message: "The model wants to copy:\n\n" + quote(text),
                confirmTitle: "Copy")
        case .snippetsCreate(let name, let text, let keyword):
            let expands =
                keyword.map { "Typing “\($0)” will expand it to:\n\n" } ?? "It expands to:\n\n"
            return BuiltInToolPrompt(
                title: "Create the snippet “\(name)”?", message: expands + quote(text),
                confirmTitle: "Create")
        case .notesAppend(let text):
            return BuiltInToolPrompt(
                title: "Add to “\(subject ?? "Notes")”?",
                message: "The model wants to add to the end of the note:\n\n" + quote(text),
                confirmTitle: "Add")
        case .appsOpen(let name):
            return BuiltInToolPrompt(
                title: "Open \(subject ?? name)?",
                message: "The model wants to open this app, or bring it forward if it is running.",
                confirmTitle: "Open")
        case .appsArrangeWindow(let id):
            let action = WindowCommandCatalog.command(id: id)?.name ?? id.rawValue
            return BuiltInToolPrompt(
                title: "Arrange \(subject.map { "\($0)’s" } ?? "the front") window?",
                message: "The model wants to apply \(action) to it.", confirmTitle: "Arrange")
        case .quicklinksOpen(let name, _):
            return BuiltInToolPrompt(
                title: "Open “\(name)”?",
                message: "The model wants to open:\n\n" + quote(subject ?? name),
                confirmTitle: "Open")
        case .clipboardSearch, .clipboardRead, .snippetsSearch, .notesRead, .calendarEvents,
            .appsRunning, .filesSearch, .filesRead, .quicklinksList, .calculate, .frontmostApp,
            .selectedText:
            return nil
        }
    }

    /// A clipped quote says how long the whole is, so a write cannot hide its tail past the cut.
    static func quote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > previewLength else { return "\u{201C}\(trimmed)\u{201D}" }
        return "\u{201C}\(trimmed.prefix(previewLength))\u{2026}\u{201D}\n\n"
            + "Only the start is shown; the whole is \(trimmed.count) characters."
    }
}

/// Which files a model may read without asking: the user's own, never secrets kept out of sight.
enum BuiltInFileAccess {
    static let maxBytes = 64 * 1024

    /// `~/` expanded and `..` folded, but not symlinks: the runner resolves them and asks again.
    static func standardized(_ raw: String, home: URL) -> URL {
        let expanded =
            raw == "~" ? home.path : raw.hasPrefix("~/") ? home.path + raw.dropFirst(1) : raw
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    static func isReadable(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.pathComponents
        let root = home.standardizedFileURL.pathComponents
        guard path.count > root.count, Array(path.prefix(root.count)) == root else { return false }
        let inside = path.dropFirst(root.count)
        // APFS ignores case, so `~/library` is the same folder and must be refused alike.
        return inside.first?.lowercased() != "library" && !inside.contains { $0.hasPrefix(".") }
    }
}

/// Text the runner shapes before it reaches a note or a result.
enum BuiltInToolText {
    static let previewLength = 160

    /// A blank line between old and new, so appended Markdown never joins the last paragraph.
    static func appending(_ text: String, to source: String) -> String {
        let addition = text.trimmingCharacters(in: .newlines)
        var base = Substring(source)
        while base.last?.isWhitespace == true { base.removeLast() }
        return base.isEmpty ? addition + "\n" : String(base) + "\n\n" + addition + "\n"
    }

    /// One line, clipped, so a search result stays a list and the full text is a second call.
    static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > previewLength ? line.prefix(previewLength) + "\u{2026}" : line
    }
}
