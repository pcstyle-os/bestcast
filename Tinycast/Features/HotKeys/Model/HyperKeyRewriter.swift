import Carbon.HIToolbox
import CoreGraphics

/// The Hyper Key's event decisions and hold state. See docs/features/hotkeys.md#the-hyper-key.
struct HyperKeyRewriter: Sendable {
    /// The three Hyper settings, pushed in whole whenever one of them moves.
    struct Configuration: Equatable, Sendable {
        var key: HyperKeyPhysicalKey = .none
        var includesShift = true
        var quickPress: HyperKeyQuickPress = .none
    }

    /// What the tap does with the event; `asFlagsChanged` converts it in place.
    enum Decision: Equatable, Sendable {
        case pass
        case suppress
        case rewrite(flags: UInt64, keyCode: Int64? = nil, asFlagsChanged: Bool = false)
    }

    struct QuickPress: Equatable, Sendable {
        let action: HyperKeyQuickPress
        let key: HyperKeyPhysicalKey
    }

    struct Outcome: Equatable, Sendable {
        var decision: Decision
        /// Set by the release that ends a quick lone press; the caller fires it off the tap.
        var quickPress: QuickPress?

        init(_ decision: Decision, quickPress: QuickPress? = nil) {
            self.decision = decision
            self.quickPress = quickPress
        }
    }

    /// Device-level modifier bits from IOLLEvent.h. See docs/features/hotkeys.md#the-hyper-key.
    enum DeviceFlag {
        static let leftControl: UInt64 = 0x0000_0001
        static let leftShift: UInt64 = 0x0000_0002
        static let rightShift: UInt64 = 0x0000_0004
        static let leftCommand: UInt64 = 0x0000_0008
        static let rightCommand: UInt64 = 0x0000_0010
        static let leftOption: UInt64 = 0x0000_0020
        static let rightOption: UInt64 = 0x0000_0040
        static let rightControl: UInt64 = 0x0000_2000
    }

    static let quickPressWindow: Duration = .milliseconds(250)

    private(set) var configuration: Configuration
    private(set) var isHolding = false
    private var holdStartedAt: ContinuousClock.Instant?
    private var otherKeyPressed = false
    /// After a cancel, toggling can't tell which way the key moves next, but its own flags can.
    private var resyncsOnNextTransition = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func configure(_ configuration: Configuration) {
        if configuration.key != self.configuration.key { cancelHold() }
        self.configuration = configuration
    }

    /// Drops a hold whose release may never arrive: the tap was disabled, torn down or suspended.
    mutating func cancelHold() {
        isHolding = false
        holdStartedAt = nil
        otherKeyPressed = false
        resyncsOnNextTransition = true
    }

    // MARK: - Event decisions

    mutating func decide(
        type: CGEventType, keyCode: Int, flagsRaw: UInt64, isAutorepeat: Bool, isSynthetic: Bool,
        at now: ContinuousClock.Instant
    ) -> Outcome {
        let key = configuration.key
        guard !isSynthetic, let tapCode = key.tapKeyCode else { return Outcome(.pass) }

        if keyCode == tapCode {
            return decideHyperKeyEvent(
                type: type, flagsRaw: flagsRaw, isAutorepeat: isAutorepeat, at: now)
        }
        // Before the remap takes hold the key is still Caps Lock, so ride the modifier path.
        if key == .capsLock, keyCode == kVK_CapsLock, type == .flagsChanged {
            return decideModifierTransition(flagsRaw: flagsRaw, swapKeyCode: true, at: now)
        }
        guard isHolding else { return Outcome(.pass) }
        // Any other key or modifier going down while Hyper is held makes this a combo, not a tap.
        if type == .keyDown || type == .flagsChanged { otherKeyPressed = true }
        return Outcome(.rewrite(flags: hyperized(flagsRaw)))
    }

    private mutating func decideHyperKeyEvent(
        type: CGEventType, flagsRaw: UInt64, isAutorepeat: Bool, at now: ContinuousClock.Instant
    ) -> Outcome {
        if configuration.key.tapUsesKeyEvents {
            // F18 arrives as keyDown/keyUp; convert both ends into flagsChanged transitions.
            let flagsRaw = flagsRaw & ~Self.functionKeyFlagRaw
            switch type {
            case .keyDown:
                if isAutorepeat { return Outcome(.suppress) }
                if !isHolding { beginHold(at: now) }
                return Outcome(
                    .rewrite(
                        flags: hyperized(flagsRaw), keyCode: Int64(kVK_Control),
                        asFlagsChanged: true))
            case .keyUp:
                let quickPress = isHolding ? endHold(at: now) : nil
                return Outcome(
                    .rewrite(
                        flags: flagsRaw & ~strippedFlagsRaw, keyCode: Int64(kVK_Control),
                        asFlagsChanged: true),
                    quickPress: quickPress)
            default:
                return Outcome(.pass)
            }
        }
        guard type == .flagsChanged else { return Outcome(.pass) }
        return decideModifierTransition(flagsRaw: flagsRaw, swapKeyCode: false, at: now)
    }

    /// docs/features/hotkeys.md#press-tracking-uses-toggle-semantics
    private mutating func decideModifierTransition(
        flagsRaw: UInt64, swapKeyCode: Bool, at now: ContinuousClock.Instant
    ) -> Outcome {
        let keyCode: Int64? = swapKeyCode ? Int64(kVK_Control) : nil
        let isPress = !isHolding && !isReleaseAfterCancel(flagsRaw)
        resyncsOnNextTransition = false
        if isPress {
            beginHold(at: now)
            return Outcome(.rewrite(flags: hyperized(flagsRaw), keyCode: keyCode))
        }
        let quickPress = isHolding ? endHold(at: now) : nil
        return Outcome(
            .rewrite(flags: flagsRaw & ~strippedFlagsRaw, keyCode: keyCode), quickPress: quickPress)
    }

    private func isReleaseAfterCancel(_ flagsRaw: UInt64) -> Bool {
        guard resyncsOnNextTransition, let ownFlag = configuration.key.ownFlag,
            let deviceBit = Self.ownDeviceBit(of: configuration.key)
        else { return false }
        return flagsRaw & (ownFlag.rawValue | deviceBit) == 0
    }

    // MARK: - Hold state machine

    private mutating func beginHold(at now: ContinuousClock.Instant) {
        isHolding = true
        holdStartedAt = now
        otherKeyPressed = false
        resyncsOnNextTransition = false
    }

    private mutating func endHold(at now: ContinuousClock.Instant) -> QuickPress? {
        let isQuick =
            !otherKeyPressed && holdStartedAt.map { now - $0 < Self.quickPressWindow } ?? false
        isHolding = false
        holdStartedAt = nil
        guard isQuick, configuration.quickPress != .none else { return nil }
        return QuickPress(action: configuration.quickPress, key: configuration.key)
    }

    // MARK: - Hyper chord flags

    /// The flags OR'd in while Hyper is held: the generic masks plus left-side device bits.
    private var hyperFlagsRaw: UInt64 {
        var raw =
            CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
            | DeviceFlag.leftControl | DeviceFlag.leftOption | DeviceFlag.leftCommand
        if configuration.includesShift {
            raw |= CGEventFlags.maskShift.rawValue | DeviceFlag.leftShift
        }
        return raw
    }

    /// The Hyper key's own flag residue, scrubbed from every rewritten event.
    private var strippedFlagsRaw: UInt64 {
        let key = configuration.key
        if key == .capsLock { return CGEventFlags.maskAlphaShift.rawValue }
        guard let own = key.ownFlag, hyperFlagsRaw & own.rawValue == 0 else { return 0 }
        return own.rawValue | Self.deviceBits(for: own)
    }

    private static func deviceBits(for flag: CGEventFlags) -> UInt64 {
        switch flag {
        case .maskControl: return DeviceFlag.leftControl | DeviceFlag.rightControl
        case .maskShift: return DeviceFlag.leftShift | DeviceFlag.rightShift
        case .maskAlternate: return DeviceFlag.leftOption | DeviceFlag.rightOption
        case .maskCommand: return DeviceFlag.leftCommand | DeviceFlag.rightCommand
        default: return 0
        }
    }

    private static func ownDeviceBit(of key: HyperKeyPhysicalKey) -> UInt64? {
        switch key {
        case .none, .capsLock: return nil
        case .rightControl: return DeviceFlag.rightControl
        case .rightShift: return DeviceFlag.rightShift
        case .rightOption: return DeviceFlag.rightOption
        case .rightCommand: return DeviceFlag.rightCommand
        }
    }

    /// F18 carries fn like any F-key, and a `flagsChanged` saying so reads as a real fn press.
    private static let functionKeyFlagRaw = CGEventFlags.maskSecondaryFn.rawValue

    private func hyperized(_ flagsRaw: UInt64) -> UInt64 {
        (flagsRaw & ~strippedFlagsRaw) | hyperFlagsRaw
    }
}
