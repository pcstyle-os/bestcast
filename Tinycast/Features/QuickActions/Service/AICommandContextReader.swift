import AppKit

/// Reads only the facts an AI Command's prompt names, at the moment the reader runs it.
@MainActor
enum AICommandContextReader {
    static func gather(
        _ facts: Set<AICommandTemplate.Fact>, target: NSRunningApplication?,
        injector: TextInjector, clipboard copied: String? = nil
    ) async throws -> SnippetTemplateEngine.ExpansionContext {
        // Read before the selection, whose borrowed ⌘C briefly owns the pasteboard.
        var clipboard: [String] = []
        if facts.contains(.clipboard) {
            let text = copied ?? NSPasteboard.general.string(forType: .string) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QuickActionFailure.clipboardEmpty
            }
            guard text.utf8.count <= QuickActionRunner.maxSelectionBytes else {
                throw QuickActionFailure.clipboardTooLong
            }
            clipboard = [text]
        }
        let selection =
            facts.contains(.selection)
            ? try await QuickActionRunner.selection(in: target, using: injector) : ""
        var context = SnippetTemplateEngine.ExpansionContext(
            clipboardHistory: clipboard, selection: selection, now: Date(),
            calendar: Calendar.current, locale: Locale.current, timeZone: .current)
        if facts.contains(.frontmostApp) {
            context.frontmostApp = target?.localizedName ?? ""
        }
        if facts.contains(.browserTab) {
            let tab = try await BrowserTabReader.read(
                bundleID: target?.bundleIdentifier, name: target?.localizedName ?? "The browser")
            context.browserTab = tab.placeholderValue
        }
        return context
    }
}
