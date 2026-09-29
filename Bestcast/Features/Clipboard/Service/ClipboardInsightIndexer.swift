import Foundation

/// Tags each new text clip with its kind, and asks for a one-line summary of a long one.
@MainActor
final class ClipboardInsightIndexer {
    /// A burst of copies keeps only its newest clips: an old one is not worth a model call.
    private static let backlog = 20

    private let store: ClipboardStore
    private let summarize: @MainActor (String) async -> String?
    private var continuation: AsyncStream<ClipboardItem>.Continuation?
    private var task: Task<Void, Never>?

    init(store: ClipboardStore, summarize: @escaping @MainActor (String) async -> String?) {
        self.store = store
        self.summarize = summarize
    }

    isolated deinit {
        task?.cancel()
    }

    func start() {
        guard task == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(
            of: ClipboardItem.self, bufferingPolicy: .bufferingNewest(Self.backlog))
        self.continuation = continuation
        task = Task(priority: .utility) { [weak self] in
            for await item in stream {
                guard !Task.isCancelled, let self else { return }
                await self.derive(item)
            }
        }
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        task?.cancel()
        task = nil
    }

    func enqueue(_ item: ClipboardItem) {
        guard item.kind == .text else { return }
        continuation?.yield(item)
    }

    private func derive(_ item: ClipboardItem) async {
        guard let text = item.text else { return }
        let generation = store.extractionGeneration
        let (kind, eligible) = await Task.detached(priority: .utility) {
            (PassiveAIHeuristics.kind(of: text), PassiveAIHeuristics.isSummaryEligible(text))
        }.value
        guard !Task.isCancelled, store.setInsight(kind: kind.rawValue, for: item, generation: generation),
            eligible, let summary = await summarize(text), !Task.isCancelled
        else { return }
        store.setSummary(summary, for: item, generation: generation)
    }
}
