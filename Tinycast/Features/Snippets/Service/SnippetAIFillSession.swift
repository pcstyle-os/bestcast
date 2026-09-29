import Foundation

/// One expansion's `{ai}` replies, asked for together and settled at most once.
@MainActor
final class SnippetAIFillSession {
    typealias Ask = @MainActor (String) async throws -> String

    private let prompts: [String]
    private let timeout: Duration
    private let ask: Ask
    private var answers: [String: String] = [:]
    private var requests: [Task<Void, Never>] = []
    private var deadline: Task<Void, Never>?
    private var onFinish: (@MainActor ([String: String]) -> Void)?

    init(prompts: [String], timeout: Duration = SnippetAIPrompt.fillTimeout, ask: @escaping Ask) {
        self.prompts = prompts
        self.timeout = timeout
        self.ask = ask
    }

    /// A deadline rather than awaiting cancellation, so a route that ignores it cannot hold the fill.
    func start(onFinish: @escaping @MainActor ([String: String]) -> Void) {
        self.onFinish = onFinish
        guard !prompts.isEmpty else { return finish() }
        requests = prompts.map { prompt in
            Task { [ask] in
                let reply = try? await ask(prompt)
                self.record(reply ?? "", for: prompt)
            }
        }
        deadline = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.finish()
        }
    }

    /// Drops the fill without delivering anything.
    func cancel() {
        onFinish = nil
        stop()
    }

    /// Delivers now: a reply still missing expands empty, and its request is cancelled.
    func settle() {
        finish()
    }

    private func record(_ reply: String, for prompt: String) {
        guard onFinish != nil else { return }
        answers[prompt] = reply
        if answers.count == prompts.count { finish() }
    }

    private func finish() {
        guard let onFinish else { return }
        self.onFinish = nil
        stop()
        onFinish(answers)
    }

    private func stop() {
        requests.forEach { $0.cancel() }
        deadline?.cancel()
    }
}
