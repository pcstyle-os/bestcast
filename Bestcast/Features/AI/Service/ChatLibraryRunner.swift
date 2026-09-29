import Foundation
import Synchronization

/// How far a library build has got, as the composer's status line shows it.
enum ChatLibraryProgress: Equatable, Sendable {
    case reading(done: Int, total: Int)
    case embedding(done: Int, total: Int)

    var fraction: Double {
        switch self {
        case .reading(let done, let total): total == 0 ? 0 : 0.2 * Double(done) / Double(total)
        case .embedding(let done, let total):
            total == 0 ? 0.2 : 0.2 + 0.8 * Double(done) / Double(total)
        }
    }

    var summary: String {
        switch self {
        case .reading(let done, let total):
            "Reading \(done.formatted()) of \(total.formatted()) \(total == 1 ? "file" : "files")…"
        case .embedding(let done, let total):
            "Indexing \(done.formatted()) of \(total.formatted()) passages…"
        }
    }
}

/// Builds a chat's library index from what was attached: walk, read, cut, embed.
nonisolated enum ChatLibraryRunner {
    /// Nil once cancelled; a partial index would answer from a library the reader never finished.
    static func build(
        roots: [URL], progress: @escaping @Sendable (ChatLibraryProgress) -> Void
    ) async -> ChatLibraryIndex? {
        let walk = ChatLibraryScanner.files(in: roots)
        var chunks: [ChatLibraryChunk] = []
        var skipped = walk.skipped
        var truncated = walk.isTruncated
        var read = 0
        var indexed = 0
        progress(.reading(done: 0, total: walk.files.count))
        for file in walk.files {
            guard !Task.isCancelled else { return nil }
            defer {
                read += 1
                progress(.reading(done: read, total: walk.files.count))
            }
            guard let pages = ChatLibraryScanner.pages(of: file) else {
                skipped += 1
                continue
            }
            indexed += 1
            for page in pages {
                chunks += ChatLibraryChunkEngine.chunks(
                    of: page.text, path: file.path, page: page.number)
            }
            if chunks.count >= ChatLibraryPolicy.maxChunks {
                truncated = truncated || chunks.count > ChatLibraryPolicy.maxChunks
                    || read + 1 < walk.files.count
                chunks = Array(chunks.prefix(ChatLibraryPolicy.maxChunks))
                break
            }
        }
        guard !Task.isCancelled else { return nil }
        let sample = chunks.prefix(40).map(\.text).joined(separator: "\n")
        let language = ChatEmbeddingService.language(of: sample)
        var vectors: [[Float]?] = []
        var dimension = 0
        if let language {
            dimension = ChatEmbeddingService.dimension(for: language)
            let total = chunks.count
            let counter = ProgressCounter()
            progress(.embedding(done: 0, total: total))
            vectors = await ChatEmbeddingService.vectors(
                for: chunks.map(\.text), language: language
            ) { step in
                let done = counter.add(step)
                if done % 16 == 0 || done == total { progress(.embedding(done: done, total: total)) }
            }
        }
        guard !Task.isCancelled else { return nil }
        return ChatLibraryIndex(
            roots: roots.map(\.path), language: dimension > 0 ? language : nil,
            dimension: dimension, chunks: chunks,
            vectors: dimension > 0 ? ChatLibraryIndex.packed(vectors, dimension: dimension) : Data(),
            fileCount: indexed, skippedCount: skipped,
            isTruncated: truncated)
    }
}

/// The embedding lanes finish out of order, so their progress is summed under a lock.
private nonisolated final class ProgressCounter: Sendable {
    private let count = Mutex(0)

    func add(_ step: Int) -> Int {
        count.withLock { value in
            value += step
            return value
        }
    }
}
