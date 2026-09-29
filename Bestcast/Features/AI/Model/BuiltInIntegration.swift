import Foundation

/// Bestcast's own features a model may use; the raw value is the `@` handle, so it never holds `_`.
enum BuiltInIntegration: String, CaseIterable, Identifiable, Sendable {
    case clipboard
    case snippets
    case notes
    case calendar
    case apps
    case files
    case quicklinks
    case calculator
    case system

    var id: String { rawValue }
    var handle: String { rawValue }

    /// An MCP server may not take one of these; one saved before they existed keeps its slug.
    static let handles = Set(allCases.map(\.handle))

    init?(handle: String) {
        self.init(rawValue: handle)
    }

    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .snippets: return "Snippets"
        case .notes: return "Notes"
        case .calendar: return "Calendar"
        case .apps: return "Apps & Windows"
        case .files: return "Files"
        case .quicklinks: return "Quicklinks"
        case .calculator: return "Calculator"
        case .system: return "System"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .snippets: return "text.quote"
        case .notes: return "note.text"
        case .calendar: return "calendar"
        case .apps: return "macwindow"
        case .files: return "folder"
        case .quicklinks: return "link"
        case .calculator: return "plus.forwardslash.minus"
        case .system: return "desktopcomputer"
        }
    }

    /// Settings' one-line account of what switching it on lets a model read or do.
    var summary: String {
        switch self {
        case .clipboard: return "Search and read copied text; copying asks first."
        case .snippets: return "List and search snippets; creating one asks first."
        case .notes: return "Read the open note; adding to it asks first."
        case .calendar: return "Read events once Calendar access is granted."
        case .apps: return "List running apps; opening an app or moving a window asks first."
        case .files: return "Find files by name and read small text files in your home folder."
        case .quicklinks: return "List quicklinks; opening one asks first."
        case .calculator: return "Evaluate maths, units and currencies."
        case .system: return "Read the frontmost app's name and its selected text."
        }
    }
}
