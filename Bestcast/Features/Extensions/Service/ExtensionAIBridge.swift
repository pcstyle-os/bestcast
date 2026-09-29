import Foundation

@MainActor
final class ExtensionAIBridge {
    var makeProvider: ((String?) throws -> any AIProvider)?
    var canAccess: () -> Bool = { false }
    private var sessions: [String: Session] = [:]

    private final class Session {
        var iterator: AsyncThrowingStream<String, Error>.Iterator
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        let task: Task<Void, Never>
        var receiving = false

        init(provider: any AIProvider, request: AIRequest) {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            self.continuation = continuation
            iterator = stream.makeAsyncIterator()
            task = Task {
                do {
                    for try await event in provider.stream(request) {
                        try Task.checkCancellation()
                        if case .text(let text) = event { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        func cancel() {
            task.cancel()
            continuation.finish(throwing: CancellationError())
        }
    }

    func perform(method: String, arguments: [RenderValue]) async throws -> String? {
        let id = arguments.first?.stringValue ?? ""
        switch method {
        case "start":
            guard let makeProvider else {
                throw AIProviderError.unavailable("Choose a default AI model in Settings.")
            }
            let options = arguments.count > 2 ? arguments[2].objectValue ?? [:] : [:]
            let provider = try makeProvider(options["model"]?.stringValue)
            let prompt = arguments.count > 1 ? arguments[1].stringValue ?? "" : ""
            let request = AIRequest(
                instructions: Self.instructions(creativity: options["creativity"]),
                messages: [AIMessage(role: .user, text: prompt)])
            sessions.removeValue(forKey: id)?.cancel()
            sessions[id] = Session(provider: provider, request: request)
            return nil
        case "receive":
            guard let session = sessions[id], !session.receiving else {
                throw AIProviderError.unavailable("The AI request is no longer available.")
            }
            session.receiving = true
            defer { session.receiving = false }
            var iterator = session.iterator
            do {
                let chunk = try await iterator.next(isolation: MainActor.shared)
                session.iterator = iterator
                if chunk == nil { sessions[id] = nil }
                return chunk
            } catch {
                sessions[id] = nil
                session.cancel()
                throw error
            }
        case "cancel":
            sessions.removeValue(forKey: id)?.cancel()
            return nil
        default: throw AIProviderError.unavailable("Unknown AI operation: \(method)")
        }
    }

    func closeAll() {
        for session in sessions.values { session.cancel() }
        sessions.removeAll()
    }

    private static func instructions(creativity: RenderValue?) -> String? {
        guard let creativity else { return nil }
        let levels = ["none": 0.0, "low": 0.5, "medium": 1.0, "high": 1.5, "maximum": 2.0]
        guard let value = creativity.doubleValue ?? creativity.stringValue.flatMap({ levels[$0] }),
            value.isFinite else { return nil }
        let level = min(2, max(0, value))
        return "Use creativity level \(level) on a scale from 0 (precise and literal) to 2 (highly creative)."
    }
}
