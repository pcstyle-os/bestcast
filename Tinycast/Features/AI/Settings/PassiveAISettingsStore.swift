import Foundation
import Observation

/// Settings → AI → Passive AI: AI that helps unasked, on this Mac unless a route is picked here.
@MainActor
@Observable
final class PassiveAISettingsStore {
    private let defaults: UserDefaults

    /// Nil is the on-device model; a network route is only ever the reader's explicit pick.
    var model: AIModelSelection? {
        didSet { persistModel() }
    }
    var inlineAnswers: Bool {
        didSet { defaults.set(inlineAnswers, forKey: AppSettingsKey.aiPassiveInlineAnswers.rawValue) }
    }
    /// Takes effect only while Quick Actions is on, whose consent covers reading a selection.
    var selectionSuggestions: Bool {
        didSet {
            defaults.set(
                selectionSuggestions, forKey: AppSettingsKey.aiPassiveSelectionSuggestions.rawValue)
        }
    }
    /// Kinds and on-device summaries for copied text; never sent to a network route.
    var clipboardIntelligence: Bool {
        didSet {
            defaults.set(clipboardIntelligence, forKey: AppSettingsKey.aiPassiveClipboard.rawValue)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = defaults.data(forKey: AppSettingsKey.aiPassiveModel.rawValue).flatMap {
            try? JSONDecoder().decode(AIModelSelection.self, from: $0)
        }
        inlineAnswers =
            defaults.object(forKey: AppSettingsKey.aiPassiveInlineAnswers.rawValue) as? Bool ?? true
        selectionSuggestions =
            defaults.object(forKey: AppSettingsKey.aiPassiveSelectionSuggestions.rawValue) as? Bool
            ?? true
        clipboardIntelligence =
            defaults.object(forKey: AppSettingsKey.aiPassiveClipboard.rawValue) as? Bool ?? true
    }

    /// Whether anything this store routes can leave the Mac.
    var isOnDevice: Bool { model == nil || model?.isOnDevice == true }

    private func persistModel() {
        guard let model, let data = try? JSONEncoder().encode(model) else {
            defaults.removeObject(forKey: AppSettingsKey.aiPassiveModel.rawValue)
            return
        }
        defaults.set(data, forKey: AppSettingsKey.aiPassiveModel.rawValue)
    }
}
