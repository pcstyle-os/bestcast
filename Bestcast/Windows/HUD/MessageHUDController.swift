import AppKit
import SwiftUI

/// The message pill, shared by every feature that reports a transient confirmation.
@MainActor
final class MessageHUDController {
    private let presenter: HUDPresenter
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        presenter = HUDPresenter(
            anchor: .edgeInset(Theme.Size.hudEdgeOffset),
            dwell: Theme.Duration.messageHUD,
            screen: { settings.openOnCursorScreen ? .underCursor : .primary })
    }

    func show(message: String, tone: DialogTone = .success) {
        presenter.show(
            MessageHUDView(message: message, accessory: .tone(tone)).environment(\.metrics, metrics))
        announce(message)
    }

    /// Stays up until the work it reports ends and something replaces it, or `dismiss()` runs.
    func showProgress(message: String, onCancel: (() -> Void)? = nil) {
        presenter.show(
            MessageHUDView(message: message, accessory: .progress, onCancel: onCancel)
                .environment(\.metrics, metrics),
            dwells: false,
            interactive: onCancel != nil)
        announce(message)
    }

    func dismiss() {
        presenter.dismiss()
    }

    /// The pill never takes focus, so VoiceOver hears the report only if it is announced.
    private func announce(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    private var metrics: InterfaceMetrics { settings.interfaceSize.metrics }
}
