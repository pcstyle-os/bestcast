import Foundation

/// One question put to several models at once, each answer in its own column.
struct ModelComparison: Equatable, Sendable {
    static let modelLimit = 2...4
    static let cancelled = "Cancelled"
    static let endedUnexpectedly = "The response ended unexpectedly."

    struct Column: Identifiable, Equatable, Sendable {
        let id: UUID
        let model: AIModelSelection
        fileprivate(set) var reply: ChatMessage
        fileprivate(set) var startedAt: Date
        fileprivate(set) var firstTokenAt: Date?
        fileprivate(set) var finishedAt: Date?
        fileprivate var reasoningStartedAt: Date?

        fileprivate init(id: UUID, model: AIModelSelection, at now: Date) {
            self.id = id
            self.model = model
            reply = ChatMessage(role: .assistant, text: "", state: .streaming, sentAt: now)
            startedAt = now
        }

        var isStreaming: Bool { reply.state == .streaming }

        /// Nil until the first word of the answer; thinking and searching are not an answer yet.
        var timeToFirstToken: TimeInterval? {
            firstTokenAt.map { $0.timeIntervalSince(startedAt) }
        }

        var totalTime: TimeInterval? {
            finishedAt.map { $0.timeIntervalSince(startedAt) }
        }
    }

    let id: UUID
    /// The turns every column answers: one question, or an inline comparison's chat so far.
    let context: ChatSession
    private(set) var columns: [Column]
    private(set) var focusedIndex = 0

    init(
        context: ChatSession, models: [AIModelSelection], id: UUID = UUID(),
        columnIDs: [UUID]? = nil, now: Date
    ) {
        self.id = id
        self.context = context
        let ids = columnIDs ?? models.map { _ in UUID() }
        columns = zip(ids, models).map { Column(id: $0, model: $1, at: now) }
    }

    /// A single user turn: what the side-by-side composer sends.
    static func question(
        _ text: String, images: [AIImage] = [], documents: [AIDocument] = [], now: Date
    ) -> ChatSession {
        ChatSession(
            createdAt: now,
            messages: [
                ChatMessage(role: .user, text: text, sentAt: now, images: images, documents: documents)
            ])
    }

    var question: ChatMessage? {
        context.messages.last { $0.role == .user }
    }

    var isStreaming: Bool { columns.contains(where: \.isStreaming) }

    var focusedColumn: Column? {
        columns.indices.contains(focusedIndex) ? columns[focusedIndex] : nil
    }

    func column(_ id: UUID) -> Column? {
        columns.first { $0.id == id }
    }

    func requestMessages(textBudget: Int = ChatSession.defaultTextBudget) -> [AIMessage] {
        context.requestMessages(textBudget: textBudget)
    }

    // MARK: - Picks

    /// On or off in the pick list; past the limit a new pick is refused rather than bumping one.
    static func toggling(_ model: AIModelSelection, in picks: [AIModelSelection]) -> [AIModelSelection] {
        if let index = picks.firstIndex(where: { same($0, model) }) {
            var picks = picks
            picks.remove(at: index)
            return picks
        }
        guard picks.count < modelLimit.upperBound else { return picks }
        return picks + [model]
    }

    static func isPicked(_ model: AIModelSelection, in picks: [AIModelSelection]) -> Bool {
        picks.contains { same($0, model) }
    }

    static func canCompare(_ picks: [AIModelSelection]) -> Bool {
        modelLimit.contains(picks.count)
    }

    /// Only what every picked model can read may be attached, since each is sent the same turn.
    static func common(_ capabilities: [AIModelCapabilities]) -> AIModelCapabilities {
        AIModelCapabilities(
            images: !capabilities.isEmpty && capabilities.allSatisfy(\.images),
            documents: !capabilities.isEmpty && capabilities.allSatisfy(\.documents),
            webSearch: !capabilities.isEmpty && capabilities.allSatisfy(\.webSearch),
            tools: false)
    }

    /// The effort is a setting of the route, not a second model: one pick per route.
    private static func same(_ lhs: AIModelSelection, _ rhs: AIModelSelection) -> Bool {
        lhs.source == rhs.source && lhs.model == rhs.model
    }

    // MARK: - Keyboard

    mutating func focus(_ index: Int) {
        guard columns.indices.contains(index) else { return }
        focusedIndex = index
    }

    // MARK: - Streaming

    /// Events for a column that has already ended are late arrivals from a cancelled stream.
    mutating func apply(_ event: AIStreamEvent, to columnID: UUID, at now: Date) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }),
            columns[index].isStreaming
        else { return }
        var column = columns[index]
        switch event {
        case .text(let text):
            guard !text.isEmpty else { return }
            if column.firstTokenAt == nil { column.firstTokenAt = now }
            column.reply.searches = column.reply.searches.map(Self.completed)
            Self.closeReasoning(in: &column, at: now)
            column.reply.text += text
        case .reasoning(let text):
            Self.appendReasoning(text, to: &column, at: now)
        case .searching(let query, let kind, let id):
            column.reply.searches.append(
                ChatSearch(
                    query: query, isComplete: false, textOffset: column.reply.text.count,
                    sequence: column.reply.nextSequence, kind: kind, callID: id))
        case .searched(let query, let id, let failed):
            column.reply.searches.settle(id: id, query: query, failed: failed)
        case .usage(let usage):
            column.reply.usage = usage
        case .finished:
            Self.finish(&column, state: .complete, fallback: "No response", at: now)
        case .thinking, .toolCallRequested, .toolCall, .toolResult:
            return
        }
        columns[index] = column
    }

    mutating func fail(_ columnID: UUID, message: String, at now: Date) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }),
            columns[index].isStreaming
        else { return }
        Self.finish(&columns[index], state: .failed, fallback: message, at: now)
    }

    /// Stop means every column: a comparison half-cancelled would still be spending on the rest.
    mutating func cancelAll(at now: Date) {
        for index in columns.indices where columns[index].isStreaming {
            Self.finish(&columns[index], state: .failed, fallback: Self.cancelled, at: now)
        }
    }

    /// The same turn asked again of that column's model; the others keep what they said.
    @discardableResult
    mutating func retry(_ columnID: UUID, at now: Date) -> Bool {
        guard let index = columns.firstIndex(where: { $0.id == columnID }),
            !columns[index].isStreaming
        else { return false }
        columns[index] = Column(id: columnID, model: columns[index].model, at: now)
        return true
    }

    /// Continue as Chat: the turns and this answer, as a chat of their own with this model.
    func session(continuing columnID: UUID, id: UUID = UUID(), now: Date) -> ChatSession? {
        guard let column = column(columnID), column.reply.state == .complete else { return nil }
        let whole = ChatSession(
            createdAt: now, messages: context.messages + [column.reply], model: column.model,
            instructions: context.instructions)
        return whole.branch(through: column.reply.id, id: id, now: now)
    }

    // MARK: - Private

    private static func finish(
        _ column: inout Column, state: ChatMessage.State, fallback: String, at now: Date
    ) {
        if state == .failed, !column.reply.text.isEmpty {
            column.reply.text += "\n\n\(fallback)"
        } else if column.reply.text.isEmpty {
            column.reply.text = fallback
        }
        column.reply.state = state
        closeReasoning(in: &column, at: now)
        column.reply.searches = column.reply.searches.map(completed)
        column.finishedAt = now
    }

    private static func appendReasoning(_ text: String, to column: inout Column, at now: Date) {
        let offset = column.reply.text.count
        if let last = column.reply.reasoning.last, last.textOffset == offset, last.duration == nil {
            column.reply.reasoning[column.reply.reasoning.count - 1].text += text
            return
        }
        let opening = String(text.drop(while: \.isWhitespace))
        guard !opening.isEmpty else { return }
        column.reasoningStartedAt = now
        column.reply.reasoning.append(ChatReasoning(text: opening, textOffset: offset, duration: nil))
    }

    private static func closeReasoning(in column: inout Column, at now: Date) {
        guard let last = column.reply.reasoning.last, last.duration == nil,
            let started = column.reasoningStartedAt
        else { return }
        column.reply.reasoning[column.reply.reasoning.count - 1].duration =
            now.timeIntervalSince(started)
        column.reasoningStartedAt = nil
    }

    private static func completed(_ search: ChatSearch) -> ChatSearch {
        var search = search
        search.isComplete = true
        return search
    }
}
