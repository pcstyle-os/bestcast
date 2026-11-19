import AppKit

/// Switches the keyboard input source as apps come to the front. See docs/features/input-sources.md.
@MainActor
final class AppInputSourceController {
    private var policy: AppInputSourcePolicy
    private var front: String?
    private var activation: NotificationToken?
    /// State, not a preference: what each app was last left in, so it survives a relaunch.
    private static let memoryKey = "appInputSourceMemory"

    init() {
        policy = AppInputSourcePolicy(
            remembered: UserDefaults.standard.dictionary(forKey: Self.memoryKey) as? [String: String] ?? [:])
    }

    func apply(rules: [AppInputSourceRule], fallback: AppInputSourceFallback) {
        policy.rules = rules
        policy.fallback = fallback
        guard policy.isActive else {
            activation = nil
            front = nil
            return
        }
        guard activation == nil else { return }
        front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let center = NSWorkspace.shared.notificationCenter
        activation = NotificationToken(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                MainActor.assumeIsolated { self?.didActivate(bundleID) }
            }, center: center)
    }

    /// Our own windows are skipped, so Settings never takes the place of the app behind it.
    private func didActivate(_ bundleID: String?) {
        guard let bundleID else {
            front = nil
            return
        }
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        let before = policy.remembered
        let target = policy.activate(
            bundleID, leaving: front, current: InputSourceSwitcher.currentSourceID())
        front = bundleID
        if policy.remembered != before {
            UserDefaults.standard.set(policy.remembered, forKey: Self.memoryKey)
        }
        if let target { InputSourceSwitcher.select(sourceID: target) }
    }
}
