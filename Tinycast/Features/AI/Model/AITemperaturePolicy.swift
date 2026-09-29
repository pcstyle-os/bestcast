import Foundation

/// A model that rejects `temperature` answers it with a 400, so the hint is dropped rather than sent.
enum AITemperaturePolicy {
    static func value(_ temperature: Double?, for configuration: AIHTTPConfiguration) -> Double? {
        guard let temperature, accepts(configuration) else { return nil }
        return min(max(temperature, 0), 1)
    }

    static func accepts(_ configuration: AIHTTPConfiguration) -> Bool {
        let name = configuration.model.lowercased()
        if refusesSampling(claude: name) { return false }
        switch configuration.provider {
        case .anthropic, .gemini, .openRouter: return true
        case .openAI, .openAICompatible: return !isReasoningModel(name)
        }
    }

    private static func isReasoningModel(_ model: String) -> Bool {
        let name = model.split(separator: "/").last.map(String.init) ?? ""
        if name.hasPrefix("gpt-5") { return true }
        guard name.first == "o", let second = name.dropFirst().first else { return false }
        return second.isNumber
    }

    /// Claude Opus 4.7 onward, Sonnet 5 onward, Fable and Mythos all 400 on a sampling parameter.
    private static func refusesSampling(claude model: String) -> Bool {
        guard let start = model.range(of: "claude") else { return false }
        let rest = model[start.upperBound...]
        if rest.contains("fable") || rest.contains("mythos") { return true }
        let numbers = rest.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            .filter { $0 < 100 }
        guard let major = numbers.first else { return false }
        if major >= 5 { return true }
        return major == 4 && (numbers.dropFirst().first ?? 0) >= 7
    }
}
