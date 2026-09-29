import SwiftUI

/// Quick AI's reply and context actions, and the keys that reach them without the menu.
extension AIScreen {
    var quickAIItems: [PopoverMenuItem] {
        var items: [PopoverMenuItem] = []
        if coordinator.hasFinishedReply {
            items.append(
                PopoverMenuItem(
                    title: "Paste Last Response", systemImage: "doc.on.clipboard",
                    startsSection: true, shortcut: "⌘↵"
                ) {
                    _ = coordinator.pasteLastResponse()
                })
        }
        if coordinator.hasFinishedReply, coordinator.lastCodeBlock != nil {
            items.append(
                PopoverMenuItem(
                    title: "Copy Code Block", systemImage: "curlybraces", shortcut: "⌥⌘C"
                ) {
                    coordinator.copyCodeBlock()
                })
        }
        if let app = coordinator.targetAppName {
            items.append(
                PopoverMenuItem(
                    title: "Attach Selected Text", systemImage: "text.cursor",
                    startsSection: true, shortcut: "⇧⌘S"
                ) {
                    coordinator.attachSelection()
                })
            items.append(
                PopoverMenuItem(
                    title: "Attach Screenshot of \(app) Window", systemImage: "camera.viewfinder"
                ) {
                    coordinator.attachScreenshot()
                })
        }
        let active = coordinator.activePresetID
        for (index, preset) in coordinator.presets.enumerated() {
            items.append(
                PopoverMenuItem(
                    title: preset.name, icon: .symbol("sparkles"),
                    sectionTitle: index == 0 ? "Presets" : nil, startsSection: index == 0,
                    detail: preset.id == active ? "✓" : nil
                ) {
                    coordinator.applyPreset(id: preset.id)
                })
        }
        return items
    }

    /// ↑ on an empty composer takes the last question back; otherwise the list keeps the arrow.
    func move(_ delta: Int, axis: PaletteAxis, from selection: Int) -> Int? {
        guard axis == .vertical, delta < 0, vm.query.isEmpty, coordinator.editLastMessage() else {
            return nil
        }
        return selection
    }

    /// ⇥ walks the follow-ups into the composer, so Return asks the one landed on.
    func tab(at selection: Int, backwards: Bool) -> Bool {
        let choices = coordinator.followUps
        guard vm.query.isEmpty || choices.contains(vm.query),
            let next = QuickAIInstructions.nextChoice(
                choices, current: vm.query, backwards: backwards)
        else { return false }
        vm.query = next
        return true
    }
}
