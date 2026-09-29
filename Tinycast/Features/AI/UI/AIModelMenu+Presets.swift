import Foundation

extension AIModelMenu {
    /// Presets follow the models, so the highlight's index into the model rows still holds.
    static func withPresets(
        _ content: PopoverMenuContent, quickAI: QuickAICoordinator
    ) -> PopoverMenuContent {
        let active = quickAI.activePresetID
        let presets = quickAI.presets.enumerated().map { index, preset in
            PopoverMenuItem(
                title: preset.name, icon: .symbol("sparkles"),
                sectionTitle: index == 0 ? "Presets" : nil, startsSection: index == 0,
                detail: preset.id == active ? "✓" : nil
            ) {
                quickAI.applyPreset(id: preset.id)
            }
        }
        return PopoverMenuContent(header: content.header, items: content.items + presets)
    }
}
