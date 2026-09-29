import Foundation

/// OpenAI's reasoning models reject `temperature` outright, so a hint is dropped rather than sent.
enum AITemperaturePolicy {
    static func value(_ temperature: Double?, for configuration: AIHTTPConfiguration) -> Double? {
        guard let temperature, accepts(configuration) else { return nil }
        return min(max(temperature, 0), 1)
    }

    static func accepts(_ configuration: AIHTTPConfiguration) -> Bool {
        switch configuration.provider {
        case .anthropic, .gemini, .openRouter: return true
        case .openAI, .openAICompatible: return !isReasoningModel(configuration.model)
        }
    }

    private static func isReasoningModel(_ model: String) -> Bool {
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
        if name.hasPrefix("gpt-5") { return true }
        guard name.first == "o", let second = name.dropFirst().first else { return false }
        return second.isNumber
    }
}
