import Foundation

/// What goes into a chat's library, how much of it a turn may carry, and how a reply cites it.
enum ChatLibraryPolicy {
    static let maxFiles = 400
    /// About a minute of embedding on one core, and a few megabytes of vectors held per chat.
    static let maxChunks = 2_000
    /// Read whole before it is cut, so the ceiling is what one file may cost in memory.
    static let maxTextFileBytes = 4 * 1_048_576
    static let maxPDFBytes = 200 * 1_048_576
    /// Generated or vendored trees: thousands of files nobody attached a folder to ask about.
    static let skippedFolders: Set<String> = [
        "node_modules", "DerivedData", "Pods", "__pycache__", "venv", "Carthage"
    ]
    /// A turn's share of the route's budget; the history keeps the rest.
    static let maxRetrievalBytes = 24_000

    /// Only what the library reads, never an image: there is no text in one to find.
    static func indexes(fileName name: String) -> Bool {
        switch AIAttachmentPolicy.kind(forFileName: name) {
        case .pdf?, .text?: true
        case .image?, nil: false
        }
    }

    /// A folder, or a file too big to send whole, is searched instead of refused.
    static func belongsInLibrary(
        fileName name: String, isDirectory: Bool, byteCount: Int, readsDocuments: Bool
    ) -> Bool {
        if isDirectory { return true }
        switch AIAttachmentPolicy.kind(forFileName: name) {
        case .text?: return byteCount > AIAttachmentBudget.maxInlinedTextBytes
        case .pdf?: return byteCount > AIAttachmentBudget.maxBytes || !readsDocuments
        case .image?, nil: return false
        }
    }

    static func retrievalBudget(contextBudget: Int) -> Int {
        min(maxRetrievalBytes, contextBudget / 3)
    }

    /// "And the second one?" says nothing alone, so a short follow-up borrows the last question.
    static func query(for messages: [ChatMessage]) -> String {
        let questions = messages.filter { $0.role == .user && !$0.text.isEmpty }.map(\.text)
        guard let latest = questions.last else { return "" }
        let words = latest.split(whereSeparator: \.isWhitespace).count
        guard words < 6, questions.count > 1 else { return latest }
        return questions[questions.count - 2] + "\n" + latest
    }

    /// One number per file and page, so two passages from one page cite as one source.
    static func sources(for passages: [ChatLibraryChunk]) -> [ChatSource] {
        var sources: [ChatSource] = []
        for passage in passages
        where !sources.contains(where: { $0.path == passage.path && $0.page == passage.page }) {
            sources.append(ChatSource(number: sources.count + 1, path: passage.path, page: passage.page))
        }
        return sources
    }

    /// Quoted and fenced like an attached file, each under the number the reply cites it by.
    static func prompt(for passages: [ChatLibraryChunk], roots: [String]) -> String {
        let sources = sources(for: passages)
        var parts = [
            "Excerpts from the user's files, found by searching them for this question. "
                + "Use them when they help, and cite each one you use by its number, like [1]."
        ]
        for passage in passages {
            guard
                let source = sources.first(where: { $0.path == passage.path && $0.page == passage.page })
            else { continue }
            let name = AIAttachmentPolicy.sanitized(name: displayPath(source.path, roots: roots))
            let page = source.page.map { ", page \($0)" } ?? ""
            let fence = AIAttachmentPolicy.fence(for: passage.text)
            parts.append("[\(source.number)] \(name)\(page)\n\(fence)\n\(passage.text)\n\(fence)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The newest question goes out after its excerpts, the way an attached file precedes it.
    static func injecting(_ block: String, into messages: [AIMessage]) -> [AIMessage] {
        guard let newest = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        let prompt = messages[newest]
        var injected = messages
        injected[newest] = AIMessage(
            role: prompt.role, text: prompt.text.isEmpty ? block : block + "\n\n" + prompt.text,
            images: prompt.images, documents: prompt.documents)
        return injected
    }

    /// The ones the reply cited; a reply that cites none still drew on every one it was given.
    static func cited(_ sources: [ChatSource], in reply: String) -> [ChatSource] {
        var numbers = Set<Int>()
        for match in reply.matches(of: #/\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\]/#) {
            for part in match.output.1.split(separator: ",") {
                if let number = Int(part.trimmingCharacters(in: .whitespaces)) { numbers.insert(number) }
            }
        }
        let cited = sources.filter { numbers.contains($0.number) }
        return cited.isEmpty ? sources : cited
    }

    /// Relative to the attached folder that holds it, so `docs/a.md` and `src/a.md` stay apart.
    static func displayPath(_ path: String, roots: [String]) -> String {
        for root in roots {
            let folder = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(folder) else { continue }
            return (root as NSString).lastPathComponent + "/" + path.dropFirst(folder.count)
        }
        return (path as NSString).lastPathComponent
    }
}
