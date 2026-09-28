import AppKit
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// The app in front right now, read where it cannot lag an activation still in flight.
enum FrontmostApplication {
    /// Short: a summon waits on it, and a wedged answer must fall back rather than stall.
    private static let timeout: Float = 0.25

    /// `NSWorkspace` learns of an activation only once our run loop delivers its notification.
    static func current() -> NSRunningApplication? {
        let workspace = NSWorkspace.shared.frontmostApplication
        let pid = resolve(
            focused: focusedPID(), workspace: workspace?.processIdentifier,
            own: NSRunningApplication.current.processIdentifier)
        guard let pid else { return nil }
        if pid == workspace?.processIdentifier { return workspace }
        return NSRunningApplication(processIdentifier: pid) ?? workspace
    }

    /// Focus is live; when it is ours, one of our non-activating panels holds key over the app.
    static func resolve(focused: pid_t?, workspace: pid_t?, own: pid_t) -> pid_t? {
        guard let focused, focused != own else { return workspace ?? focused }
        return focused
    }

    /// Nil without the Accessibility grant, which leaves the workspace's answer.
    private static func focusedPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let application = unsafeDowncast(value, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(application, &pid) == .success, pid > 0 else { return nil }
        return pid
    }
}
