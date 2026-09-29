import Foundation

/// What the user allowed one extension to reach, kept in `extension-grants.json` and nowhere else.
struct ExtensionGrant: Codable, Equatable, Sendable {
    let capability: ExtensionCapability
    let grantedAt: Date
    var lastUsedAt: Date?
    /// Only meaningful for a write: true skips the per-call question.
    var always: Bool
}

enum ExtensionGrantDecision: Equatable, Sendable {
    case allow
    /// Ask the user; `subject` is what the dialog names.
    case ask(subject: String)
    case deny(String)
}

/// Every consent decision, pure, so the harness pins the table rather than a dialog.
enum ExtensionGrantPolicy {
    static let denied = "denied"

    static func undeclared(_ capability: ExtensionCapability) -> String {
        "undeclared capability \(capability.rawValue)"
    }

    static func decide(
        capability: ExtensionCapability, declared: Set<ExtensionCapability>, grant: ExtensionGrant?,
        isImplicit: Bool, featureEnabled: Bool, subject: String? = nil
    ) -> ExtensionGrantDecision {
        let isDeclared =
            declared.contains(capability) || (isImplicit && capability.isImplicitForRaycastAPI)
        guard isDeclared else { return .deny(undeclared(capability)) }
        guard featureEnabled else { return .deny(denied) }
        guard capability.needsPrompt else { return .allow }
        if let grant, !capability.isWrite || grant.always { return .allow }
        return .ask(subject: subject ?? capability.title)
    }

    /// A read is remembered once allowed; a write only when the user chose Always Allow.
    static func grant(
        _ capability: ExtensionCapability, always: Bool, now: Date
    ) -> ExtensionGrant? {
        guard !capability.isWrite || always else { return nil }
        return ExtensionGrant(capability: capability, grantedAt: now, lastUsedAt: now, always: always)
    }
}
