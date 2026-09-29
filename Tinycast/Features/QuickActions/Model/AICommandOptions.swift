import Foundation

/// Where an AI Command's answer goes once the model has written it.
enum AICommandOutput: String, Codable, CaseIterable, Identifiable, Sendable {
    case replace
    case paste
    case copy
    case panel
    case quickAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace: return "Replace Selection"
        case .paste: return "Paste"
        case .copy: return "Copy"
        case .panel: return "Show in Panel"
        case .quickAI: return "Open in Quick AI"
        }
    }

    /// Short enough for a Settings row's trailing picker.
    var shortTitle: String {
        switch self {
        case .replace: return "Replace"
        case .paste: return "Paste"
        case .copy: return "Copy"
        case .panel: return "Panel"
        case .quickAI: return "Quick AI"
        }
    }

    /// Text landing in somebody's document or clipboard must be the result alone, never a chat.
    var landsInline: Bool { self == .replace || self == .paste || self == .copy }
}

/// Raycast's creativity, kept to three steps; a route that has no temperature ignores it.
enum AICommandCreativity: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Inside 0...1, the range every route that takes a temperature accepts.
    var temperature: Double {
        switch self {
        case .low: return 0.2
        case .medium: return 0.6
        case .high: return 1.0
        }
    }

    /// Raycast writes five steps; its outer two fold into the nearest of these three.
    init?(raycast value: String) {
        switch value.lowercased() {
        case "none", "low": self = .low
        case "medium": self = .medium
        case "high", "maximum": self = .high
        default: return nil
        }
    }
}
