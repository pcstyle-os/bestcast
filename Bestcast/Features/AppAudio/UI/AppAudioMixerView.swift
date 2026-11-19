import SwiftUI

/// The menu bar mixer: the default output, then one row per app. See docs/features/app-audio.md.
struct AppAudioMixerView: View {
    let router: AppAudioRouter
    let settings: AppSettings
    let appIndex: AppIndex

    private static let width: CGFloat = 340
    private static let iconSize: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Picker("Default output", selection: defaultOutput) {
                ForEach(router.outputs) { Text($0.name).tag($0.uid) }
            }
            Divider()
            if router.groups.isEmpty {
                Text("Nothing is playing").foregroundStyle(.secondary)
            }
            ForEach(router.groups, id: \.appID) { row($0) }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: Self.width)
        .onAppear { router.setVisible(true) }
        .onDisappear { router.setVisible(false) }
    }

    private var defaultOutput: Binding<String> {
        Binding(get: { router.defaultOutputUID ?? "" }, set: { router.setDefaultOutput(uid: $0) })
    }

    /// An untouched row is stored as nothing, so it costs no tap.
    private func setting(_ appID: String) -> Binding<AppAudioSetting> {
        Binding(
            get: { settings.appAudioSettings[appID] ?? AppAudioSetting() },
            set: { settings.appAudioSettings[appID] = $0.needsTap ? $0 : nil })
    }

    private func row(_ group: AppAudioGroup) -> some View {
        let (name, icon) = AppPresentation.resolve(bundleID: group.appID, in: appIndex)
        let setting = setting(group.appID)
        let muted = setting.wrappedValue.muted
        return HStack(spacing: Theme.Spacing.lg) {
            Image(nsImage: icon).resizable().frame(width: Self.iconSize, height: Self.iconSize)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack {
                    Text(name).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: Theme.Spacing.md)
                    Picker("Output", selection: setting.outputUID) {
                        Text("Default").tag(String?.none)
                        ForEach(router.outputs) { Text($0.name).tag(Optional($0.uid)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        setting.wrappedValue.muted.toggle()
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: Theme.Spacing.xxl)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(muted ? "Unmute \(name)" : "Mute \(name)")
                    Slider(value: setting.volume, in: 0...1)
                        .accessibilityLabel("\(name) volume")
                    Text(muted ? "Muted" : "\(Int((setting.wrappedValue.volume * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: Self.iconSize * 1.7, alignment: .trailing)
                }
                .opacity(muted ? 0.6 : 1)
            }
        }
    }
}
