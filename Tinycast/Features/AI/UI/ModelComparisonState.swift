import Foundation
import Observation

/// A live comparison: its picks and composer, then one stream per column into `ModelComparison`.
@MainActor
@Observable
final class ModelComparisonState: ChatAttachmentStaging {
    let id = UUID()
    /// Nil until the first send; picking models and typing come before it.
    private(set) var comparison: ModelComparison?
    private(set) var picks: [AIModelSelection]
    var draft = ""
    private(set) var pendingAttachments: [ChatAttachment] = []
    @ObservationIgnored private(set) var stagingGeneration = 0
    /// Where an inline comparison sits: the reply it re-asks, in the chat that holds it.
    let anchor: (chat: UUID, reply: UUID)?

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [UUID: Int] = [:]
    /// Stamped on arrival, so a flush that lands late still measures when the token came.
    @ObservationIgnored private var queued: [(column: UUID, event: AIStreamEvent, at: Date)] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    private static let flushInterval: Duration = .milliseconds(40)

    init(picks: [AIModelSelection] = [], anchor: (chat: UUID, reply: UUID)? = nil) {
        self.picks = picks
        self.anchor = anchor
    }

    var isStreaming: Bool { comparison?.isStreaming ?? false }

    func togglePick(_ model: AIModelSelection) {
        picks = ModelComparison.toggling(model, in: picks)
    }

    /// A new question replaces the last comparison whole; its streams stop first.
    func begin(_ next: ModelComparison) {
        stopStreams()
        comparison = next
        pendingAttachments = []
        stagingGeneration += 1
    }

    func run(_ columnID: UUID, using provider: any AIProvider, request: AIRequest) {
        let generation = (generations[columnID] ?? 0) + 1
        generations[columnID] = generation
        tasks[columnID]?.cancel()
        tasks[columnID] = Task { [weak self, provider] in
            do {
                for try await event in provider.stream(request) {
                    guard let self, !Task.isCancelled, self.generations[columnID] == generation
                    else { return }
                    self.queue(event, for: columnID)
                }
                self?.end(columnID, generation: generation, reason: ModelComparison.endedUnexpectedly)
            } catch {
                self?.end(columnID, generation: generation, reason: error.localizedDescription)
            }
        }
    }

    /// A route that fails to start fails its own column; the others are already asking.
    func fail(_ columnID: UUID, message: String) {
        comparison?.fail(columnID, message: message, at: Date())
    }

    @discardableResult
    func retry(_ columnID: UUID) -> Bool {
        flush()
        return comparison?.retry(columnID, at: Date()) ?? false
    }

    func cancel() {
        stopStreams()
        comparison?.cancelAll(at: Date())
    }

    func focus(_ index: Int) {
        comparison?.focus(index)
    }

    // MARK: - Attachments

    func attach(_ attachment: ChatAttachment) -> ChatAttachmentRefusal? {
        if let refusal = pendingAttachments.refusal(adding: attachment) { return refusal }
        pendingAttachments.append(attachment)
        return nil
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    // MARK: - Private

    private func end(_ columnID: UUID, generation: Int, reason: String) {
        guard !Task.isCancelled, generations[columnID] == generation else { return }
        flush()
        tasks[columnID] = nil
        comparison?.fail(columnID, message: reason, at: Date())
    }

    private func stopStreams() {
        flush()
        for id in tasks.keys { generations[id, default: 0] += 1 }
        for task in tasks.values { task.cancel() }
        tasks = [:]
    }

    /// Four streams at once re-render the columns once per cadence, never once per token.
    private func queue(_ event: AIStreamEvent, for columnID: UUID) {
        queued.append((columnID, event, Date()))
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !queued.isEmpty, var next = comparison else {
            queued = []
            return
        }
        for item in queued { next.apply(item.event, to: item.column, at: item.at) }
        queued = []
        comparison = next
    }
}
