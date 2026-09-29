import Foundation

/// One trigger's consent and run history, as `extension-triggers.json` keeps it.
struct ExtensionTriggerState: Sendable, Codable, Equatable {
    var enabled = false
    /// A clipboard trigger sees copied text only with this second opt-in; otherwise just its kind.
    var sharesClipboardText = false
    /// `replacesSelection` types into another app only once this is on.
    var allowsTyping = false
    var lastFired: Date?
    var lastRun: Date?
    var lastError: String?
    var failureCount = 0
    /// Set when repeated failures switched it off, so Settings can say why it is off.
    var autoDisabled = false
}

/// Why a trigger run or a composed call ended without a value, in words Settings can show.
struct ExtensionTriggerFailure: LocalizedError, Equatable, Sendable {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

/// Trigger decisions with every moment passed in, so the harness drives them.
enum ExtensionTriggerPolicy {
    /// A trigger's toasts reach the screen as HUDs, at most one this often.
    static let hudInterval: TimeInterval = 10
    static let backoff: [TimeInterval] = [60, 300, 1800]
    static let failureLimit = 3
    /// How many exports may be on one call stack; deeper is almost certainly a loop.
    static let composeDepthLimit = 4
    /// Events waiting behind a running trigger; past this, the oldest are dropped.
    static let pendingLimit = 16

    enum Verdict: Equatable, Sendable {
        case fire
        case paused
        case off
        case throttled
        case backingOff
    }

    static func verdict(
        trigger: ExtensionTrigger, state: ExtensionTriggerState, isPaused: Bool, now: Date
    ) -> Verdict {
        if isPaused { return .paused }
        guard state.enabled else { return .off }
        if let throttle = trigger.throttle, let last = state.lastFired, now < last.addingTimeInterval(throttle) {
            return .throttled
        }
        if state.failureCount > 0, let lastRun = state.lastRun,
            now < lastRun.addingTimeInterval(backoffDelay(failures: state.failureCount))
        {
            return .backingOff
        }
        return .fire
    }

    static func backoffDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return backoff[min(failures, backoff.count) - 1]
    }

    /// Returns the new state and whether this failure is the one that switched it off.
    static func recording(
        error: String?, in state: ExtensionTriggerState, now: Date
    ) -> (state: ExtensionTriggerState, didAutoDisable: Bool) {
        var next = state
        next.lastRun = now
        guard let error else {
            next.failureCount = 0
            next.lastError = nil
            return (next, false)
        }
        next.lastError = error
        next.failureCount += 1
        guard next.failureCount >= failureLimit, next.enabled else { return (next, false) }
        next.enabled = false
        next.autoDisabled = true
        return (next, true)
    }

    /// Turning a trigger on again starts its history over.
    static func enabling(_ state: ExtensionTriggerState) -> ExtensionTriggerState {
        var next = state
        next.enabled = true
        next.autoDisabled = false
        next.failureCount = 0
        next.lastError = nil
        return next
    }

    static func allowsHUD(lastShown: Date?, now: Date) -> Bool {
        guard let lastShown else { return true }
        return now >= lastShown.addingTimeInterval(hudInterval)
    }

    /// An invalid `match` never fires: a typo must not widen what the trigger sees.
    static func matches(_ filter: ExtensionTriggerFilter?, kind: String, text: String?) -> Bool {
        guard let filter else { return true }
        if let want = filter.kind, want.caseInsensitiveCompare(kind) != .orderedSame { return false }
        guard let pattern = filter.match else { return true }
        guard let text, let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func matches(bundleIds: [String], bundleId: String?) -> Bool {
        guard !bundleIds.isEmpty else { return true }
        guard let bundleId else { return false }
        return bundleIds.contains { $0.caseInsensitiveCompare(bundleId) == .orderedSame }
    }

    static func clipboardPayload(kind: String, text: String?, sharesText: Bool) -> [String: JSONValue] {
        var payload: [String: JSONValue] = ["kind": .string(kind)]
        if sharesText, let text { payload["text"] = .string(text) }
        return payload
    }

    static func event(
        trigger: String, type: ExtensionTriggerEvent, payload: [String: JSONValue],
        previous: JSONValue? = nil
    ) -> JSONValue {
        var event: [String: JSONValue] = [
            "trigger": .string(trigger), "type": .string(type.rawValue), "payload": .object(payload)
        ]
        if let previous { event["previous"] = previous }
        return .object(event)
    }

    /// What a command target's default export receives: its launch props, carrying the event.
    static func commandLaunchProps(event: JSONValue) -> JSONValue {
        .object([
            "launchType": .string(ExtensionLaunchType.background.rawValue),
            "arguments": .object([:]),
            "launchContext": .object(["bestcastTrigger": event])
        ])
    }

    /// The `then` chain feeds each step's value into the next as `previous`.
    static func chained(_ event: JSONValue, previous: JSONValue) -> JSONValue {
        guard var fields = event.objectValue else { return event }
        fields["previous"] = previous
        return .object(fields)
    }

    enum ComposeVerdict: Equatable, Sendable {
        case allowed
        case tooDeep
        case cycle
    }

    /// `chain` holds `extension/export` for every call already on the stack.
    static func composeVerdict(chain: [String], next: String) -> ComposeVerdict {
        if chain.contains(next) { return .cycle }
        return chain.count >= composeDepthLimit ? .tooDeep : .allowed
    }

    static func callKey(extension name: String, export: String) -> String { "\(name)/\(export)" }

    /// The target gets the event, each `then` step the same event with the value before it.
    static func runChain(
        event: JSONValue, target: ExtensionTriggerTarget, then steps: [String],
        isolation: isolated (any Actor)? = #isolation,
        call: (ExtensionTriggerTarget, JSONValue) async -> Result<JSONValue, ExtensionTriggerFailure>
    ) async -> Result<JSONValue, ExtensionTriggerFailure> {
        let input: JSONValue
        switch target {
        case .export: input = event
        case .command: input = commandLaunchProps(event: event)
        }
        var result = await call(target, input)
        for step in steps {
            guard case .success(let previous) = result else { return result }
            result = await call(.export(step), chained(event, previous: previous))
        }
        return result
    }

    /// Keeps the newest events when a burst outruns the runner.
    static func enqueue<Element>(_ element: Element, into queue: [Element]) -> [Element] {
        Array((queue + [element]).suffix(pendingLimit))
    }

    static func json(_ value: JSONValue) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value.jsonObject, options: [.fragmentsAllowed, .sortedKeys])
        return data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "null"
    }
}
