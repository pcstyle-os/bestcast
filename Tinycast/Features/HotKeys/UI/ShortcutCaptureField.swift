import SwiftUI

/// The Record Hotkey dialog's body; the session's monitors take every key while it records.
struct ShortcutCaptureField: View {
    let action: HotKeyAction
    /// Called once recording stops, whether it bound, cleared, was cancelled or clicked away.
    let onEnd: () -> Void

    @Environment(HotKeyManager.self) private var hotKeys
    @Environment(\.metrics) private var metrics

    var body: some View {
        ShortcutCaptureReadout()
            .frame(maxWidth: .infinity)
            .padding(.vertical, metrics.spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                    .fill(Theme.Colors.controlSurface))
            .background {
                if hotKeys.recordingAction == action {
                    ShortcutRecorderHitRegion(capture: hotKeys.capture)
                }
            }
            .onChange(of: hotKeys.recordingAction) { _, recording in
                if recording != action { onEnd() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(hotKeys.displayName(of: action)) Hotkey")
            .accessibilityHint("Press a shortcut. Delete clears it, Escape cancels.")
    }
}
