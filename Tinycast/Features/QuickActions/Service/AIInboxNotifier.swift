import Foundation
import UserNotifications

/// Banners for unattended AI Command runs; clicking one opens the AI Inbox.
@MainActor
final class AIInboxNotifier: NSObject {
    private let onOpen: @MainActor () -> Void

    init(onOpen: @escaping @MainActor () -> Void) {
        self.onOpen = onOpen
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asked only from the switch the reader just turned on, never at launch.
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ entry: AIInboxEntry) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = entry.commandName
        content.subtitle = entry.failure == nil ? entry.cause.title : "Failed"
        content.body = String(entry.summary.prefix(240))
        try? await center.add(
            UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil))
    }

    fileprivate func open() {
        onOpen()
    }
}

extension AIInboxNotifier: UNUserNotificationCenterDelegate {
    /// Tinycast is always the active app while its palette is up, so a banner must still show.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await open()
    }
}
