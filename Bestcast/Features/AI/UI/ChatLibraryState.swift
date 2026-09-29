import Foundation
import Observation

/// A chat's attached folders and large files, indexed on this Mac and searched on every turn.
@MainActor
@Observable
final class ChatLibraryState {
    enum Phase: Equatable {
        case empty
        case indexing(ChatLibraryProgress)
        case ready
        case failed(String)
    }

    /// The bar's facts about the live index; the index itself only ranks, so it is not observed.
    struct Summary: Equatable {
        let files: Int
        let passages: Int
        let skipped: Int
        let isTruncated: Bool
        /// No sentence embedding fits the text's language, so only its words are matched.
        let isLexical: Bool
    }

    private(set) var phase: Phase = .empty
    /// What is attached, kept through a rebuild so the bar never goes blank while it reads.
    private(set) var roots: [URL] = []
    private(set) var summary: Summary?
    @ObservationIgnored private var index: ChatLibraryIndex?
    /// The index's own roots, which a cancelled rebuild falls back to.
    @ObservationIgnored private var committedRoots: [URL] = []
    @ObservationIgnored private var build: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<ChatLibraryIndex?, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let store: ChatLibraryStore?

    init(store: ChatLibraryStore?) {
        self.store = store
    }

    var isEmpty: Bool { phase == .empty }

    var isIndexing: Bool {
        if case .indexing = phase { return true }
        return false
    }

    /// New roots join the old ones and all are read again, so the index is always one whole.
    func add(_ urls: [URL], savingAs id: UUID?) {
        let added = urls.filter { url in
            !roots.contains { $0.standardizedFileURL == url.standardizedFileURL }
        }
        guard !added.isEmpty else { return }
        rebuild(roots: roots + added, savingAs: id)
    }

    /// Files change after they were read; this reads every root again.
    func reindex(savingAs id: UUID?) {
        guard !roots.isEmpty, !isIndexing else { return }
        rebuild(roots: roots, savingAs: id)
    }

    /// Stops a build and keeps whatever index was already there, or none.
    func cancel() {
        guard isIndexing else { return }
        stopWork()
        roots = committedRoots
        phase = index == nil ? .empty : .ready
    }

    /// The chat changed hands: nothing of the last one's library may answer the next one's turn.
    func reset() {
        stopWork()
        index = nil
        roots = []
        committedRoots = []
        summary = nil
        phase = .empty
    }

    /// After any build still writing has stopped, or it could put the file back.
    func remove(savedAs id: UUID?) {
        let worker = worker
        reset()
        guard let id, let store else { return }
        Task.detached(priority: .utility) {
            _ = await worker?.value
            store.remove(id)
        }
    }

    func load(_ id: UUID) {
        reset()
        guard let store else { return }
        let generation = generation
        build = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { store.load(id) }.value
            guard let self, self.generation == generation, let loaded else { return }
            self.commit(loaded)
        }
    }

    /// Waits out a build in progress: a question asked right after a drop is about that file.
    func passages(for query: String, budget: Int) async -> [ChatLibraryChunk] {
        if let build { await build.value }
        guard let index, budget > 0 else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let vector = index.language.flatMap { ChatEmbeddingService.vector(for: query, language: $0) }
            return index.passages(for: query, vector: vector, budget: budget)
        }.value
    }

    /// The paths a reply's excerpts are shown relative to.
    var rootPaths: [String] { index?.roots ?? [] }

    private func rebuild(roots next: [URL], savingAs id: UUID?) {
        stopWork()
        roots = next
        phase = .indexing(.reading(done: 0, total: 0))
        let generation = generation
        let (updates, continuation) = AsyncStream.makeStream(
            of: ChatLibraryProgress.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task.detached(priority: .utility) { [store] () -> ChatLibraryIndex? in
            defer { continuation.finish() }
            let built = await ChatLibraryRunner.build(roots: next) { continuation.yield($0) }
            if let built, let id, let store, !Task.isCancelled { store.save(built, for: id) }
            return built
        }
        self.worker = worker
        build = Task { [weak self] in
            await withTaskCancellationHandler {
                for await update in updates {
                    guard let self, self.generation == generation else { return }
                    self.phase = .indexing(update)
                }
                let built = await worker.value
                guard let self, self.generation == generation else { return }
                self.worker = nil
                self.finish(built)
            } onCancel: {
                worker.cancel()
            }
        }
    }

    private func finish(_ built: ChatLibraryIndex?) {
        guard let built else {
            cancel()
            return
        }
        guard !built.chunks.isEmpty else {
            index = nil
            summary = nil
            committedRoots = []
            phase = .failed(
                "Nothing readable was found. Bestcast reads PDFs with a text layer and UTF-8 text files.")
            return
        }
        commit(built)
    }

    private func commit(_ built: ChatLibraryIndex) {
        index = built
        roots = built.roots.map { URL(filePath: $0) }
        committedRoots = roots
        summary = Summary(
            files: built.fileCount, passages: built.chunks.count, skipped: built.skippedCount,
            isTruncated: built.isTruncated, isLexical: !built.hasVectors)
        phase = .ready
    }

    private func stopWork() {
        generation += 1
        build?.cancel()
        worker?.cancel()
        build = nil
        worker = nil
    }
}
