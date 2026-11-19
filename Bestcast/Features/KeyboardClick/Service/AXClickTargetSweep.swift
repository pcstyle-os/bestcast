// `@preconcurrency` downgrades AX diagnostics: `kAX…` are mutable C globals, but constant.
@preconcurrency import ApplicationServices

/// The focused window's clickable elements, read off-main. See docs/features/keyboard-click.md.
nonisolated enum AXClickTargetSweep {
    struct Result: Sendable {
        var window: CGRect
        var targets: [ClickTarget]
    }

    /// Per element, matching the menu walk: one hung app must not hold the overlay back.
    private static let timeout: Float = 0.2
    private static let budget: Duration = .milliseconds(600)
    private static let maximumNodes = 6000
    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXComboBox", "AXTextField", "AXTextArea", "AXSlider", "AXDisclosureTriangle", "AXRow",
        "AXIncrementor", "AXColorWell",
    ]
    /// Containers that are clickable only when they say so, which costs one more round trip.
    private static let pressableRoles: Set<String> = ["AXGroup", "AXImage", "AXCell"]

    static func read(pid: pid_t) -> Result? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        guard
            let window = element(application, kAXFocusedWindowAttribute)
                ?? element(application, kAXMainWindowAttribute),
            let windowFrame = details(of: window).frame
        else { return nil }
        let deadline = ContinuousClock.now + budget
        var targets: [ClickTarget] = []
        // Each node carries the nearest clickable ancestor, so a nameless row takes its text's name.
        var stack: [(AXUIElement, Int?)] = children(of: window).reversed().map { ($0, nil) }
        var visited = 0
        while let (node, owner) = stack.popLast(), visited < maximumNodes, ContinuousClock.now < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(node, timeout)
            let info = details(of: node)
            if let frame = info.frame, !frame.intersects(windowFrame) { continue }
            if info.role == kAXStaticTextRole, let owner, targets[owner].name.isEmpty,
                let text = info.value
            {
                targets[owner].name = text
            }
            var nextOwner = owner
            if let frame = info.frame, isClickable(node, role: info.role) {
                nextOwner = targets.count
                targets.append(ClickTarget(frame: frame, name: info.name))
            }
            stack += info.children.reversed().map { ($0, nextOwner) }
        }
        return Result(window: windowFrame, targets: targets)
    }

    private struct Details {
        var role = ""
        var frame: CGRect?
        var name = ""
        var value: String?
        var children: [AXUIElement] = []
    }

    /// One round trip for everything a node is judged on; a missing attribute reads as nil.
    private static func details(of element: AXUIElement) -> Details {
        let names =
            [
                kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute,
                kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute,
            ] as CFArray
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &raw) == .success,
            let values = raw as? [AnyObject], values.count == 7
        else { return Details() }
        var details = Details()
        details.role = values[0] as? String ?? ""
        if let origin = point(values[1]), let size = size(values[2]) {
            details.frame = CGRect(origin: origin, size: size)
        }
        details.name = [values[3], values[4]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
        details.value = (values[5] as? String).flatMap { $0.isEmpty ? nil : $0 }
        details.children = (values[6] as? [AnyObject] ?? []).compactMap(axElement)
        return details
    }

    private static func isClickable(_ element: AXUIElement, role: String) -> Bool {
        if clickableRoles.contains(role) { return true }
        guard pressableRoles.contains(role) else { return false }
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success
            && (actions as? [String])?.contains(kAXPressAction) == true
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
            let value
        else { return nil }
        return axElement(value)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AnyObject] ?? []).compactMap(axElement)
    }

    private static func axElement(_ value: AnyObject) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? unsafeDowncast(value, to: AXUIElement.self) : nil
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) ? size : nil
    }
}
