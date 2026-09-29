import Foundation

private struct StubProvider: AIProvider {
    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            guard !request.webSearch, request.tools.isEmpty,
                request.messages.first?.text == "hello",
                request.instructions?.contains("2.0") == true else {
                continuation.finish(throwing: AIProviderError.malformedResponse)
                return
            }
            continuation.yield(.thinking)
            continuation.yield(.text("one "))
            continuation.yield(.text("two"))
            continuation.finish()
        }
    }
}

private struct FailingProvider: AIProvider {
    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { $0.finish(throwing: AIProviderError.responseFailed("fixture failure")) }
    }
}

private struct WaitingProvider: AIProvider {
    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { _ in }
    }
}

@main
@MainActor
struct ExtensionAITests {
    static func main() async throws {
        let bridge = ExtensionAIBridge()
        do {
            _ = try await bridge.perform(method: "start", arguments: [.string("1")])
            fatalError("Missing route must fail")
        } catch AIProviderError.unavailable { }
        bridge.makeProvider = { _ in StubProvider() }
        _ = try await bridge.perform(method: "start", arguments: [
            .string("1"), .string("hello"), .object(["creativity": .number(8)])
        ])
        var chunks: [String] = []
        while let chunk = try await bridge.perform(method: "receive", arguments: [.string("1")]) {
            chunks.append(chunk)
        }
        precondition(chunks == ["one ", "two"])
        precondition(chunks.joined() == "one two")
        let fallback = AIModelSelection.appleIntelligence
        for (requested, model) in [
            ("openai-gpt-4o", "gpt-4o"),
            ("anthropic-claude-4-5-haiku", "claude-haiku-4.5"),
            ("mistral-mistral-large-latest", "mistral-large-latest"),
            ("google-gemini-2.5-pro", "google/gemini-2.5-pro")
        ] {
            let exact = AIModelSelection.api(connection: UUID(), model: model, effort: nil)
            let result = try ExtensionAIModelRouting.selection(
                requested: requested, defaultModel: fallback, available: [exact])
            precondition(result == exact)
        }
        let result = try ExtensionAIModelRouting.selection(
            requested: "unknown", defaultModel: fallback, available: [])
        precondition(result == fallback)
        bridge.makeProvider = { _ in FailingProvider() }
        _ = try await bridge.perform(method: "start", arguments: [.string("2")])
        do {
            _ = try await bridge.perform(method: "receive", arguments: [.string("2")])
            fatalError("Provider errors must propagate")
        } catch AIProviderError.responseFailed(let message) {
            precondition(message == "fixture failure")
        }
        bridge.makeProvider = { _ in WaitingProvider() }
        for closesSession in [false, true] {
            _ = try await bridge.perform(method: "start", arguments: [.string("3")])
            let receive = Task { try await bridge.perform(method: "receive", arguments: [.string("3")]) }
            try await Task.sleep(for: .milliseconds(10))
            if closesSession {
                bridge.closeAll()
            } else {
                _ = try await bridge.perform(method: "cancel", arguments: [.string("3")])
            }
            do {
                _ = try await receive.value
                fatalError("Cancellation must release a pending receive")
            } catch is CancellationError { }
        }
        print("Extension AI streaming, request policy, missing route and model mapping passed")
    }
}

enum ExtensionRuntime {
    static func jsonArray(from json: String) -> [Any] { [] }
}
