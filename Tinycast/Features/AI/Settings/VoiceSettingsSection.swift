import SwiftUI

/// What dictation into Quick AI and the chat window does once the words are in.
struct VoiceSettingsSection: View {
    @Environment(AISettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.voiceAutoSend) {
                SettingsRowTitle(.aiVoice, "Send when dictation ends")
                Text("Releasing ⌥Space or stopping the mic sends what was heard, unread.")
            }
            Toggle(isOn: $settings.voiceSpeaksReplies) {
                SettingsRowTitle(.aiVoice, "Read replies aloud")
                Text("A reply to a dictated question is spoken, for a hands-free back and forth.")
            }
        } header: {
            SettingsSectionHeader(.aiVoice)
        } footer: {
            Text(
                "Hold ⌥Space in the composer to talk, or tap it to talk hands-free. Speech is "
                    + "recognised on this Mac and never sent anywhere."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
