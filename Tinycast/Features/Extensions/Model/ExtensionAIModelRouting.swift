import Foundation

enum ExtensionAIModelRouting {
    static func selection(
        requested: String?, defaultModel: AIModelSelection?, available: [AIModelSelection]
    ) throws -> AIModelSelection {
        guard let defaultModel else {
            throw AIProviderError.unavailable("Choose a default AI model in Settings.")
        }
        guard let requested else { return defaultModel }
        let model = canonical(requested, raycast: true)
        if canonical(defaultModel.model) == model { return defaultModel }
        return available.first { canonical($0.model) == model } ?? defaultModel
    }

    private static func canonical(_ value: String, raycast: Bool = false) -> String {
        var model = value.lowercased()
        let prefixes = [
            "openai_o1-", "openai-", "anthropic-", "google-", "xai-", "groq-",
            "mistral-", "perplexity-", "baseten-", "gateway-"
        ]
        if raycast, let prefix = prefixes.first(where: { model.hasPrefix($0) }) {
            model.removeFirst(prefix.count)
        }
        if let tail = model.split(separator: "/").last { model = String(tail) }
        if model == "claude-4-5-haiku" { model = "claude-haiku-4-5" }
        return model.replacingOccurrences(of: ".", with: "-")
    }
}
