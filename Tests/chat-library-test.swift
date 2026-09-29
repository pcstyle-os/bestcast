import Foundation

/// A chat's library: how a file is cut, how passages rank, and how a reply is given and cites them.
@main
@MainActor
struct ChatLibraryTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual == expected {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message) — got \(actual), want \(expected)")
        }
    }

    static func main() {
        chunking()
        normalizing()
        terms()
        rankingByMeaning()
        rankingByWords()
        packedVectors()
        admission()
        followUps()
        prompting()
        citing()
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func chunking() {
        let short = ChatLibraryChunkEngine.chunks(of: "  One short note.  ", path: "/a.txt")
        expect(short.map(\.text), ["One short note."], "a short file is one trimmed passage")
        expect(short.first?.page, nil, "a text file's passage has no page")
        expect(ChatLibraryChunkEngine.chunks(of: " \n\n ", path: "/a.txt").isEmpty, "blank text is nothing")

        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank today. "
        let prose = String(repeating: sentence, count: 60)
        let chunks = ChatLibraryChunkEngine.chunks(of: prose, path: "/b.txt", page: 3)
        expect(chunks.count > 1, "long prose is cut into several passages")
        expect(chunks.allSatisfy { $0.text.count <= ChatLibraryChunkEngine.length }, "no passage passes the window")
        expect(chunks.allSatisfy { $0.page == 3 }, "every passage keeps its page")
        expect(chunks.dropLast().allSatisfy { $0.text.hasSuffix(".") }, "a cut lands on a sentence end")
        let joined = chunks.map(\.text).joined(separator: " ")
        expect(joined.count > prose.trimmingCharacters(in: .whitespaces).count, "passages overlap")
        expect(chunks.dropFirst().allSatisfy { prose.contains(" " + $0.text.prefix(12)) },
               "a resumed passage starts on a word")

        let paragraphs = String(repeating: "a", count: 600) + "\n\n" + String(repeating: "b", count: 600)
        let split = ChatLibraryChunkEngine.chunks(of: paragraphs, path: "/c.md")
        expect(split.first?.text, String(repeating: "a", count: 600), "a paragraph break wins as the cut")

        let unbroken = String(repeating: "x", count: 5_000)
        let hard = ChatLibraryChunkEngine.chunks(of: unbroken, path: "/d.txt")
        expect(hard.first?.text.count, ChatLibraryChunkEngine.length, "text with no pause is cut at the limit")
        expect(hard.count >= 5 && hard.count < 20, "a pauseless file still moves forward and ends")
        expect(hard.last.map { unbroken.hasSuffix($0.text) }, true, "the file's end is in the last passage")
    }

    static func normalizing() {
        let normalize = ChatLibraryChunkEngine.normalized
        expect(normalize("a   b\t\tc"), "a b c", "a run of spaces becomes one")
        expect(normalize("a\n\n\n\n\nb"), "a\n\nb", "blank lines collapse to one")
        expect(normalize("a \n b"), "a\nb", "spaces around a line break go")
        expect(normalize("  \n lead"), "lead", "leading whitespace goes")
        expect(normalize("a\u{0C}b\u{00}c\u{A0}d"), "a\nbc d", "a form feed breaks, control bytes go")
    }

    static func terms() {
        let terms = ChatLibraryIndex.terms(in: "What does the Café invoice say about Q3 2024?")
        expect(terms, ["cafe", "invoice", "say", "2024"], "folded, stop words and short words dropped")
        expect(ChatLibraryIndex.terms(in: "summarise this file").isEmpty, "a bare request names nothing")
        expect(ChatLibraryIndex.overlap(["cafe", "invoice"], "The CAFÉ sent it."), 0.5, "overlap is a share")
        expect(ChatLibraryIndex.overlap([], "anything"), 0, "no terms, no overlap")
    }

    static func index(
        _ chunks: [ChatLibraryChunk], vectors: [[Float]?]? = nil, dimension: Int = 2
    ) -> ChatLibraryIndex {
        ChatLibraryIndex(
            roots: ["/lib"], language: vectors == nil ? nil : "en", dimension: vectors == nil ? 0 : dimension,
            chunks: chunks, vectors: vectors.map { ChatLibraryIndex.packed($0, dimension: dimension) } ?? Data(),
            fileCount: Set(chunks.map(\.path)).count, skippedCount: 0, isTruncated: false)
    }

    static func rankingByMeaning() {
        let chunks = [
            ChatLibraryChunk(path: "/lib/a.txt", page: nil, text: "alpha one"),
            ChatLibraryChunk(path: "/lib/a.txt", page: nil, text: "alpha two"),
            ChatLibraryChunk(path: "/lib/b.pdf", page: 2, text: "beta"),
            ChatLibraryChunk(path: "/lib/c.txt", page: nil, text: "gamma")
        ]
        let library = index(chunks, vectors: [[1, 0], [0.9, 0.1], [0.8, 0.6], [-1, 0]])
        expect(library.hasVectors, "a packed index has its vectors")
        let ranked = library.passages(for: "", vector: [2, 0], budget: 10_000)
        expect(ranked.map(\.text), ["alpha one", "alpha two", "beta"], "closest first, the opposite dropped")
        let capped = library.passages(for: "", vector: [1, 0], budget: 10_000, perFile: 1)
        expect(capped.map(\.text), ["alpha one", "beta"], "one file cannot crowd out the rest")
        let tight = library.passages(for: "", vector: [1, 0], budget: 12)
        expect(tight.map(\.text), ["alpha one"], "a passage past the budget is skipped")
        let limited = library.passages(for: "", vector: [1, 0], budget: 10_000, limit: 2)
        expect(limited.count, 2, "the limit bounds the count")
        let wrong = library.passages(for: "", vector: [1, 0, 0], budget: 10_000)
        expect(wrong.map(\.text), ["alpha one", "beta", "gamma"], "a mismatched vector falls to openings")
        let floored = index(
            [chunks[0], chunks[3]], vectors: [[1, 0], [0.3, 0.95]]
        ).passages(for: "", vector: [1, 0], budget: 10_000)
        expect(floored.map(\.text), ["alpha one"], "a weak match under half the best is noise")
        let lifted = index(
            [chunks[0], ChatLibraryChunk(path: "/lib/d.txt", page: nil, text: "the zebra ledger")],
            vectors: [[1, 0], [0.9, 0.44]]
        ).passages(for: "zebra ledger", vector: [1, 0], budget: 10_000)
        expect(lifted.first?.text, "the zebra ledger", "naming the exact words lifts a passage")
    }

    static func rankingByWords() {
        let library = index([
            ChatLibraryChunk(path: "/lib/a.txt", page: nil, text: "Invoice for the harbour office"),
            ChatLibraryChunk(path: "/lib/b.txt", page: nil, text: "Harbour opening hours"),
            ChatLibraryChunk(path: "/lib/c.txt", page: nil, text: "Nothing related")
        ])
        expect(!library.hasVectors, "an index without a language has no vectors")
        let ranked = library.passages(for: "harbour invoice", vector: [1, 0], budget: 10_000)
        expect(ranked.map(\.path), ["/lib/a.txt", "/lib/b.txt"], "words alone rank, non-matches drop")
        let none = library.passages(for: "volcano", vector: nil, budget: 10_000)
        expect(none.count, 3, "no match at all opens each file instead")
        let openings = library.passages(for: "summarise this", vector: nil, budget: 10_000)
        expect(openings.map(\.path), ["/lib/a.txt", "/lib/b.txt", "/lib/c.txt"], "a bare request opens each file")
        expect(index([]).passages(for: "harbour", vector: nil, budget: 10_000).isEmpty, "an empty index is empty")
    }

    static func packedVectors() {
        let data = ChatLibraryIndex.packed([[3, 4], nil, [0, 0], [1, 2, 3]], dimension: 2)
        expect(data.count, 4 * 2 * 4, "every chunk gets a slot, usable or not")
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        expect(floats, [0.6, 0.8, 0, 0, 0, 0, 0, 0], "unit length, and an unusable vector stays zero")
        expect(ChatLibraryIndex.normalized([0, 0]), nil, "a zero vector has no direction")
        let library = index([ChatLibraryChunk(path: "/lib/a.txt", page: nil, text: "a")], vectors: [[3, 4]])
        let decoded = try? PropertyListDecoder().decode(
            ChatLibraryIndex.self, from: PropertyListEncoder().encode(library))
        expect(decoded, library, "an index survives the round trip to disk")
    }

    static func admission() {
        let big = AIAttachmentBudget.maxInlinedTextBytes + 1
        let admits = ChatLibraryPolicy.belongsInLibrary
        expect(admits("docs", true, 0, true), true, "a folder is always searched")
        expect(admits("notes.md", false, big, true), true, "a text file past the inline cap is searched")
        expect(admits("notes.md", false, 100, true), false, "a small text file is sent whole")
        expect(admits("paper.pdf", false, 100, true), false, "a small PDF goes to a route that reads it")
        expect(admits("paper.pdf", false, 100, false), true, "a PDF the route cannot read is searched")
        expect(admits("paper.pdf", false, AIAttachmentBudget.maxBytes + 1, true), true, "a huge PDF is searched")
        expect(admits("photo.png", false, 50_000_000, true), false, "an image is never searched")
        expect(ChatLibraryPolicy.indexes(fileName: "a.swift"), true, "source is text the library reads")
        expect(ChatLibraryPolicy.indexes(fileName: "a.jpg"), false, "an image has no text")
        expect(ChatLibraryPolicy.indexes(fileName: "a.zip"), false, "a binary is not read")
        expect(ChatLibraryPolicy.retrievalBudget(contextBudget: 30_000), 10_000, "a third of a small window")
        expect(ChatLibraryPolicy.retrievalBudget(contextBudget: 900_000), 24_000, "capped on a large one")
    }

    static func followUps() {
        func message(_ role: ChatMessage.Role, _ text: String) -> ChatMessage { ChatMessage(role: role, text: text) }
        let first = message(.user, "What does the lease say about pets in the flat?")
        let reply = message(.assistant, "It allows cats.")
        expect(ChatLibraryPolicy.query(for: []), "", "no question, no query")
        expect(ChatLibraryPolicy.query(for: [first]), first.text, "the only question stands alone")
        expect(
            ChatLibraryPolicy.query(for: [first, reply, message(.user, "And dogs?")]),
            first.text + "\nAnd dogs?", "a short follow-up borrows the last question")
        let full = message(.user, "What is the notice period for ending the lease early?")
        expect(ChatLibraryPolicy.query(for: [first, reply, full]), full.text, "a full question stands alone")
    }

    static func prompting() {
        let passages = [
            ChatLibraryChunk(path: "/lib/docs/a.md", page: nil, text: "First"),
            ChatLibraryChunk(path: "/other/b.pdf", page: 4, text: "Has ``` inside"),
            ChatLibraryChunk(path: "/lib/docs/a.md", page: nil, text: "Second"),
            ChatLibraryChunk(path: "/other/b.pdf", page: 5, text: "Next page")
        ]
        let sources = ChatLibraryPolicy.sources(for: passages)
        expect(sources.map(\.number), [1, 2, 3], "one number per file and page")
        expect(sources.map(\.label), ["a.md", "b.pdf, p. 4", "b.pdf, p. 5"], "a PDF's label names the page")
        let prompt = ChatLibraryPolicy.prompt(for: passages, roots: ["/lib/docs"])
        expect(prompt.contains("[1] docs/a.md\n```\nFirst\n```"), "a passage is fenced under its number")
        expect(prompt.contains("[1] docs/a.md\n```\nSecond"), "a second passage reuses its page's number")
        expect(prompt.contains("[2] b.pdf, page 4\n````\nHas ``` inside\n````"), "a fence outruns the text's")
        expect(prompt.hasPrefix("Excerpts from the user's files"), "the excerpts say what they are")
        expect(ChatLibraryPolicy.displayPath("/lib/docs/x/y.txt", roots: ["/lib/docs/"]), "docs/x/y.txt",
               "a path shows relative to its folder")
        expect(ChatLibraryPolicy.displayPath("/lib/docs2/y.txt", roots: ["/lib/docs"]), "y.txt",
               "a sibling folder with a shared prefix is not inside")

        let image = AIImage(data: Data([1]), mimeType: "image/png")
        let document = AIDocument(data: Data([2]), mimeType: "application/pdf", name: "c.pdf")
        let messages = [
            AIMessage(role: .system, text: "sys"),
            AIMessage(role: .user, text: "old"),
            AIMessage(role: .assistant, text: "reply"),
            AIMessage(role: .user, text: "new", images: [image], documents: [document])
        ]
        let injected = ChatLibraryPolicy.injecting("BLOCK", into: messages)
        expect(injected[3].text, "BLOCK\n\nnew", "the excerpts precede the newest question")
        expect(injected[3].images, [image], "an image stays with its question")
        expect(injected[3].documents, [document], "a document stays with its question")
        expect(Array(injected.prefix(3)), Array(messages.prefix(3)), "earlier turns are untouched")
        let bare = ChatLibraryPolicy.injecting("BLOCK", into: [AIMessage(role: .user, text: "")])
        expect(bare.first?.text, "BLOCK", "an empty question is only the excerpts")
        expect(ChatLibraryPolicy.injecting("BLOCK", into: [messages[0]]), [messages[0]], "no question, no change")
    }

    static func citing() {
        let sources = (1...4).map { ChatSource(number: $0, path: "/f\($0).txt", page: nil) }
        let cited = ChatLibraryPolicy.cited(sources, in: "Per [2] and [1, 4], also [9].")
        expect(cited.map(\.number), [1, 2, 4], "only the cited ones, in their order")
        expect(ChatLibraryPolicy.cited(sources, in: "No citations.").count, 4, "uncited means all were used")
        expect(ChatLibraryPolicy.cited(sources, in: "See [link](x) and [a]").count, 4, "a link is not a citation")
        expect(ChatLibraryPolicy.cited([], in: "[1]").isEmpty, "no sources, nothing cited")
    }
}
