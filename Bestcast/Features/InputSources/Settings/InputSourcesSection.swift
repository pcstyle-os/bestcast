import SwiftUI

/// General's Input Sources section: a source per app, and what every other app gets.
struct InputSourcesSection: View {
    let sources: [InputSourceSwitcher.Option]

    @Environment(AppSettings.self) private var settings
    @State private var picking = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker(selection: $settings.appInputSourceFallback) {
                Text("Keep current").tag(AppInputSourceFallback.keep)
                Text("Remember last used").tag(AppInputSourceFallback.remember)
            } label: {
                SettingsRowTitle(.generalInputSources, "Other apps")
                Text("When an app without its own source comes to the front.")
            }
            ForEach($settings.appInputSourceRules, id: \.bundleID) { $rule in
                InputSourceRuleRow(rule: $rule, sources: sources) {
                    settings.appInputSourceRules.removeAll { $0.bundleID == rule.bundleID }
                }
            }
            Button("Add Application…") { picking = true }
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    let pinned = Set(settings.appInputSourceRules.map(\.bundleID))
                    AppPickerPopover(excluded: pinned) { bundleID in
                        picking = false
                        guard let bundleID,
                            let source = InputSourceSwitcher.currentSourceID() ?? sources.first?.id
                        else { return }
                        settings.appInputSourceRules.append(
                            AppInputSourceRule(bundleID: bundleID, sourceID: source))
                    }
                }
        } header: {
            SettingsSectionHeader(.generalInputSources)
        }
    }
}

/// One pinned app; a source since removed from System Settings stays listed under its ID.
private struct InputSourceRuleRow: View {
    @Binding var rule: AppInputSourceRule
    let sources: [InputSourceSwitcher.Option]
    let onRemove: () -> Void

    @Environment(AppIndex.self) private var appIndex

    var body: some View {
        let (name, icon) = AppPresentation.resolve(bundleID: rule.bundleID, in: appIndex)
        HStack {
            Picker(selection: $rule.sourceID) {
                ForEach(options) { Text($0.title).tag($0.id) }
            } label: {
                Label {
                    Text(name).lineLimit(1)
                } icon: {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
        }
    }

    private var options: [InputSourceSwitcher.Option] {
        guard !sources.contains(where: { $0.id == rule.sourceID }) else { return sources }
        return sources + [InputSourceSwitcher.Option(id: rule.sourceID, title: rule.sourceID)]
    }
}
