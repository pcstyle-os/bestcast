import AppKit
import Carbon.HIToolbox

/// Whether Secure Event Input is on, polled while a keystroke feature depends on it.
/// See docs/features/hotkeys.md#secure-input.
@MainActor
@Observable
final class SecureInputMonitor: HealthCheckable {
    struct Holder: Equatable {
        /// Best effort: macOS records the frontmost app when input went secure, not the caller.
        let app: NSRunningApplication?

        var name: String? { app?.localizedName }
    }

    /// Nil while Secure Input is off, or while nothing that it blocks is switched on.
    private(set) var holder: Holder?

    /// The features Secure Input currently pauses, by name; empty stops the polling.
    private(set) var pausedFeatures: [String] = []

    @ObservationIgnored weak var healthTicker: HealthTicker?

    func watch(for features: [String]) {
        guard features != pausedFeatures else { return }
        pausedFeatures = features
        if features.isEmpty {
            healthTicker?.unsubscribe(self)
            holder = nil
        } else {
            healthTicker?.subscribe(self)
            healthCheck()
        }
    }

    func healthCheck() {
        let current = IsSecureEventInputEnabled() ? Holder(app: Self.reportedHolder()) : nil
        if current != holder { holder = current }
    }

    private static func reportedHolder() -> NSRunningApplication? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let users =
            IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        guard let pid = users?.lazy.compactMap({ $0["kCGSSessionSecureInputPID"] as? Int }).first
        else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))
    }
}
