import AppKit
import Carbon.HIToolbox
import Foundation

/// Drives `DoubleTapDetector` on a virtual clock, so every boundary is exact.
@MainActor
private struct Keyboard {
    var detector = DoubleTapDetector()
    private(set) var fired: [DoubleTapModifier] = []

    mutating func press(
        _ modifiers: Set<DoubleTapModifier>, other: Bool = false, at time: TimeInterval
    ) {
        if let modifier = detector.handle(
            .modifiers(modifiers, hasOtherModifiers: other), at: time)
        {
            fired.append(modifier)
        }
    }

    mutating func release(other: Bool = false, at time: TimeInterval) {
        press([], other: other, at: time)
    }

    mutating func otherInput(at time: TimeInterval) {
        if let modifier = detector.handle(.otherInput, at: time) { fired.append(modifier) }
    }

    mutating func tap(
        _ modifier: DoubleTapModifier, at time: TimeInterval, hold: TimeInterval = 0.05
    ) {
        press([modifier], at: time)
        release(at: time + hold)
    }
}

@main
@MainActor
struct DoubleTapDetectorTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func expect(_ fired: [DoubleTapModifier], _ expected: [DoubleTapModifier], _ m: String) {
        expect(fired == expected, "\(m) — fired \(fired.map(\.rawValue)), want \(expected.map(\.rawValue))")
    }

    static func main() {
        modifierGlyphs()
        commandActions()
        layoutCharacters()
        hyperChord()
        hyperRetargeting()
        spelling()
        globeTap()
        globeChord()
        firing()
        timing()
        chords()
        interruptions()
        optionTyping()
        repeats()
        resetting()
        registrationIssues()
        hyperRewriting()
        hyperQuickPress()
        hyperSynthetics()
        hyperCancelledHold()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Spelling

    /// Enough of a US layout to spell with; the app reads its own through `ASCIIKeyboardLayout`.
    private static let usKeys = [
        kVK_ANSI_K: "k", kVK_ANSI_1: "1", kVK_ANSI_Keypad1: "1", kVK_ANSI_Slash: "/",
        kVK_ANSI_Equal: "="
    ]
    private static let hyperModifiers = controlKey | optionKey | shiftKey | cmdKey

    static func spelling() {
        let plain = HotKeySpelling(characters: usKeys, hyperModifiers: nil)
        let hyper = HotKeySpelling(characters: usKeys, hyperModifiers: hyperModifiers)
        func combo(_ keyCode: Int, _ modifiers: Int) -> HotKeyBinding {
            .combo(KeyShortcut(carbonKeyCode: keyCode, carbonModifiers: modifiers))
        }
        func roundTrips(_ binding: HotKeyBinding, as text: String, _ spelling: HotKeySpelling) {
            expect(spelling.text(for: binding) == text, "\(text) is how the binding spells")
            expect(spelling.binding(from: text) == binding, "\(text) reads back as the same binding")
        }

        roundTrips(combo(kVK_LeftArrow, controlKey | optionKey), as: "ctrl+option+left", plain)
        roundTrips(combo(kVK_ANSI_K, shiftKey | cmdKey), as: "shift+cmd+k", plain)
        roundTrips(combo(kVK_Space, optionKey), as: "option+space", plain)
        roundTrips(combo(kVK_F5, 0), as: "f5", plain)
        roundTrips(combo(kVK_ANSI_Slash, cmdKey), as: "cmd+/", plain)
        roundTrips(combo(kVK_UpArrow, kEventKeyModifierFnMask | controlKey), as: "fn+ctrl+up", plain)
        roundTrips(combo(kVK_ANSI_Keypad1, cmdKey), as: "cmd+keypad-1", plain)
        roundTrips(combo(kVK_ANSI_1, cmdKey), as: "cmd+1", plain)
        roundTrips(combo(110, controlKey), as: "ctrl+key-110", plain)
        roundTrips(.doubleTap(.command), as: "double-tap cmd", plain)
        roundTrips(.doubleTap(.control), as: "double-tap ctrl", plain)
        roundTrips(.globe, as: "globe", plain)
        roundTrips(.doubleGlobe, as: "double-tap globe", plain)
        roundTrips(combo(kVK_ANSI_K, hyperModifiers), as: "hyper+k", hyper)
        roundTrips(combo(kVK_ANSI_K, controlKey | optionKey | cmdKey), as: "ctrl+option+cmd+k", hyper)

        expect(
            plain.binding(from: " Command+Shift+K ") == combo(kVK_ANSI_K, shiftKey | cmdKey),
            "modifiers read in any order, case and alias")
        expect(
            plain.binding(from: "alt+space") == combo(kVK_Space, optionKey), "alt reads as option")
        expect(
            plain.binding(from: "double-tap command") == .doubleTap(.command),
            "a double-tap reads its modifier's alias")
        expect(
            plain.text(for: combo(kVK_ANSI_K, hyperModifiers)) == "ctrl+option+shift+cmd+k",
            "without a Hyper key the chord is spelled out")
        expect(plain.binding(from: "hyper+k") == nil, "without a Hyper key, hyper means nothing")

        let plusKey = HotKeySpelling(characters: [kVK_ANSI_Equal: "+"], hyperModifiers: nil)
        expect(
            plusKey.binding(from: "cmd++") == combo(kVK_ANSI_Equal, cmdKey),
            "a layout's plus key is spelled after the separator")

        expect(plain.binding(from: "k") == nil, "a bare key is refused, as the recorder refuses it")
        expect(plain.binding(from: "shift+k") == nil, "Shift alone does not command")
        expect(plain.binding(from: "cmd+") == nil, "a chord needs a key")
        expect(plain.binding(from: "cmd+nope") == nil, "an unknown key is refused")
        expect(plain.binding(from: "cmd+key-999") == nil, "a raw key code must be a real one")
        expect(plain.binding(from: "double-tap fn") == nil, "fn has no double-tap")
    }

    // MARK: - Model

    static func globeTap() {
        var detector = GlobeTapDetector()
        func globe(
            _ down: Bool, at time: TimeInterval, physical: Bool = true, other: Bool = false
        ) -> GlobeTapDetector.Gesture? {
            detector.handle(
                isGlobeKey: physical, functionDown: down, hasOtherModifiers: other, at: time)
        }

        expect(globe(true, at: 0) == nil, "Globe press waits for release")
        expect(globe(false, at: 0.05) == .single, "lone Globe fires on release")
        expect(globe(false, at: 0.10) == nil, "a second release without a press does nothing")
        expect(globe(true, at: 0.25) == nil, "a second Globe press waits for release")
        expect(globe(false, at: 0.30) == .double, "two quick Globe presses form a double tap")

        _ = globe(true, at: 1)
        _ = globe(true, at: 1.02, physical: false, other: true)
        expect(globe(false, at: 1.05) == nil, "another modifier cancels Globe")

        _ = globe(true, at: 2)
        detector.cancel()
        expect(globe(false, at: 2.05) == nil, "a key press or click cancels Globe")
        expect(globe(true, at: 3, physical: false) == nil, "an F-key cannot start Globe")
        expect(globe(false, at: 3.05, physical: false) == nil, "an F-key cannot finish Globe")

        _ = globe(true, at: 4)
        expect(globe(false, at: 4.05) == .single, "first release remains a single candidate")
        _ = globe(true, at: 4.40)
        expect(globe(false, at: 4.45) == .single, "a late second press starts a new tap")
        _ = globe(true, at: 5)
        expect(globe(false, at: 5.30) == nil, "holding Globe is not a tap")

        for binding in [HotKeyBinding.globe, .doubleGlobe] {
            let encoded = try? JSONEncoder().encode(binding)
            expect(
                encoded.flatMap { try? JSONDecoder().decode(HotKeyBinding.self, from: $0) }
                    == binding,
                "\(binding) round-trips through the existing persistence format")
        }
        expect(HotKeyBinding.globe.keycaps == ["🌐︎"], "Globe uses one monochrome keycap")
        expect(
            HotKeyBinding.doubleGlobe.keycaps == ["🌐︎", "🌐︎"],
            "double Globe renders as two monochrome keycaps")
    }

    static func globeChord() {
        let shortcut = KeyShortcut(keyCode: kVK_ANSI_J, modifierFlags: [.function])
        expect(shortcut != nil, "Globe alone can modify a letter")
        expect(
            shortcut?.carbonModifiers == kEventKeyModifierFnMask,
            "Globe uses Carbon's fn modifier bit")
        expect(shortcut?.keycaps == ["🌐︎", "J"], "Globe and the key have separate caps")
        expect(
            KeyShortcut(keyCode: kVK_ANSI_J, modifierFlags: [.function, .command])?.modifierFlags
                == [.function, .command],
            "Globe combines with ordinary modifiers")
        expect(
            KeyShortcut(carbonKeyCode: kVK_ANSI_J, carbonModifiers: Int.max).carbonModifiers
                == KeyShortcut.carbonModifiers(from: [.function, .control, .option, .shift, .command]),
            "decoding keeps fn but still discards unrelated modifier bits")
    }

    static func modifierGlyphs() {
        expect(DoubleTapModifier.allCases.count == 4, "exactly four modifiers are eligible")
        expect(
            Set(DoubleTapModifier.allCases.map(\.glyph)) == ["⌃", "⌥", "⇧", "⌘"],
            "the glyphs are the four macOS modifier symbols")
        expect(
            DoubleTapModifier.allCases.allSatisfy { $0.keycaps == [$0.glyph, $0.glyph] },
            "a double-tap renders as its glyph twice")
        expect(
            DoubleTapModifier.allCases.map(\.rawValue)
                == ["control", "option", "shift", "command"],
            "raw values are the persisted spelling and stay in canonical ⌃⌥⇧⌘ order")
    }

    static func layoutCharacters() {
        let keyCodes = [kVK_ANSI_K, kVK_ANSI_X, kVK_ANSI_Q, kVK_ANSI_Comma, kVK_ANSI_Period]
        let characters = keyCodes.compactMap { ASCIIKeyboardLayout.character(for: $0) }
        expect(
            characters.count == keyCodes.count,
            "the ASCII-capable layout translates every ANSI key a palette chord uses")
        expect(
            characters.allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) },
            "the shortcut character stays ASCII while a non-ASCII input source is active")
        expect(
            keyCodes.allSatisfy {
                ASCIIKeyboardLayout.character(for: $0, modifiers: UInt32(cmdKey >> 8)) != nil
            },
            "a layout's Command table resolves the same keys, so ⌘ chords never lose their letter")
    }

    // MARK: - Built-in command mappings

    static func commandActions() {
        let unbindable = Set(CommandID.allCases.filter { $0.hotKeyAction == nil })
        expect(
            unbindable == [.openInBrowser, .runShellCommand, .quit],
            "only the query-driven pair and Quit are unbindable — got \(unbindable.map(\.name))")
        expect(
            CommandID.allCases.allSatisfy {
                unbindable.contains($0) || $0.hotKeyAction == .command($0)
            },
            "every other command binds to its own action, so every row gets a recorder")

        // Keyed on the raw value, not the position, so reordering the enum cannot move a binding.
        for id in CommandID.allCases where !unbindable.contains(id) {
            expect(
                id.hotKeyAction?.defaultsKey == "hotkey.\(id.rawValue)",
                "\(id.name) persists under hotkey.\(id.rawValue)")
            expect(
                HotKeyAction.builtInActions.contains(.command(id)),
                "\(id.name) is registered at launch like every other fixed action")
        }
        expect(
            HotKeyAction.builtInActions.contains(.togglePalette),
            "the launcher toggle is bindable without a command row of its own")

        // Every action reaches the launcher as well as a shortcut; `CommandID.init` is exhaustive.
        expect(
            BuiltInQuickAction.allCases.allSatisfy { CommandID($0).name == $0.title },
            "each Quick Action's command carries the action's own title")
        expect(
            Set(BuiltInQuickAction.allCases.map(CommandID.init)).count == BuiltInQuickAction.allCases.count,
            "no two Quick Actions share a launcher command")
        expect(
            Set(HotKeyAction.builtInActions.map(\.defaultsKey)).count
                == HotKeyAction.builtInActions.count,
            "no two built-in actions share a defaults key, which would bind them together")
    }

    // MARK: - The Hyper chord

    /// A combo on the G key, spelled in Carbon like the on-disk shape.
    private static func combo(_ flags: NSEvent.ModifierFlags) -> KeyShortcut {
        KeyShortcut(
            carbonKeyCode: kVK_ANSI_G, carbonModifiers: KeyShortcut.carbonModifiers(from: flags))
    }

    private static func caps(_ flags: NSEvent.ModifierFlags, includesShift: Bool?) -> [String] {
        KeyShortcut.collapsedModifierSymbols(
            from: flags,
            hyperChord: includesShift.map { KeyShortcut.hyperChord(includesShift: $0) })
    }

    static func hyperChord() {
        expect(
            KeyShortcut.hyperChord(includesShift: false) == [.control, .option, .command],
            "Hyper without Include Shift is exactly ⌃⌥⌘")
        expect(
            KeyShortcut.hyperChord(includesShift: true) == [.control, .option, .shift, .command],
            "Include Shift adds ⇧ and nothing else")

        for includesShift in [false, true] {
            let chord = KeyShortcut.hyperChord(includesShift: includesShift)
            expect(
                caps(chord, includesShift: includesShift) == ["✦"],
                "the chord itself collapses to a lone ✦ (shift \(includesShift))")
            expect(
                caps(chord.union(.capsLock), includesShift: includesShift) == ["✦"],
                "a stray non-shortcut flag doesn't defeat the collapse (shift \(includesShift))")
            expect(
                caps(chord, includesShift: nil) == KeyShortcut.modifierSymbols(from: chord),
                "with no Hyper key configured the chord renders literally (shift \(includesShift))")
        }

        // ⌃⌥⌘ is a subset of ⌃⌥⇧⌘, so only the shift-off chord can collapse under the wider set.
        expect(
            caps([.control, .option, .command], includesShift: true) == ["⌃", "⌥", "⌘"],
            "the narrower chord doesn't collapse while Include Shift is on")
        expect(
            caps([.control, .option, .shift, .command], includesShift: false) == ["✦", "⇧"],
            "an extra modifier trails ✦ in canonical order")
        expect(
            caps([.command, .shift], includesShift: false) == ["⇧", "⌘"],
            "an ordinary combo is untouched, and stays in ⌃⌥⇧⌘ order rather than press order")

        expect(
            KeyShortcut(
                keyCode: kVK_ANSI_G,
                modifierFlags: KeyShortcut.hyperChord(
                    includesShift: true))?.carbonModifiers
                == combo([.control, .option, .shift, .command]).carbonModifiers,
            "recording while Hyper is held captures exactly the chord")
    }

    static func hyperRetargeting() {
        let narrow = combo([.control, .option, .command])
        let wide = combo([.control, .option, .shift, .command])

        expect(narrow.retargetingHyper(includesShift: true) == wide, "⌃⌥⌘G follows ⇧ going on")
        expect(wide.retargetingHyper(includesShift: false) == narrow, "⌃⌥⇧⌘G follows ⇧ going off")
        expect(
            narrow.retargetingHyper(includesShift: true).retargetingHyper(includesShift: false)
                == narrow,
            "the chord round-trips across a flip and back")
        for includesShift in [false, true] {
            let target = includesShift ? wide : narrow
            expect(
                target.retargetingHyper(includesShift: includesShift) == target,
                "retargeting is idempotent, so an import can't corrupt a matching chord")
        }

        expect(
            narrow.retargetingHyper(includesShift: true).carbonKeyCode == kVK_ANSI_G,
            "only the modifiers move; the key is preserved")
        expect(
            combo([.control, .option, .command, .capsLock]).retargetingHyper(includesShift: true)
                == wide,
            "the masking initializer keeps a stray flag out of the retargeted chord")

        // Anything that isn't the other chord is left exactly as recorded.
        for flags in [[.command, .shift], [.option], [.control, .option], []]
            as [NSEvent
            .ModifierFlags]
        {
            let shortcut = combo(flags)
            for includesShift in [false, true] {
                expect(
                    shortcut.retargetingHyper(includesShift: includesShift) == shortcut,
                    "\(KeyShortcut.modifierSymbols(from: flags).joined()) is not a Hyper chord")
            }
        }
    }

    // MARK: - Firing

    static func firing() {
        for modifier in DoubleTapModifier.allCases {
            var keyboard = Keyboard()
            keyboard.tap(modifier, at: 0)
            expect(keyboard.fired, [], "\(modifier.rawValue): one tap alone doesn't fire")
            keyboard.tap(modifier, at: 0.15)
            expect(keyboard.fired, [modifier], "\(modifier.rawValue): a clean double-tap fires")
        }

        // Firing is on the second release, not the second press.
        var keyboard = Keyboard()
        keyboard.tap(.command, at: 0)
        keyboard.press([.command], at: 0.15)
        expect(keyboard.fired, [], "the second press alone doesn't fire")
        keyboard.release(at: 0.20)
        expect(keyboard.fired, [.command], "the second release fires")
    }

    // MARK: - Timing

    static func timing() {
        var slowFirst = Keyboard()
        slowFirst.tap(.command, at: 0, hold: DoubleTapDetector.maxHold + 0.01)
        slowFirst.tap(.command, at: 0.5)
        expect(slowFirst.fired, [], "a held first press isn't a tap")

        var slowSecond = Keyboard()
        slowSecond.tap(.command, at: 0)
        slowSecond.tap(.command, at: 0.10, hold: DoubleTapDetector.maxHold + 0.01)
        expect(slowSecond.fired, [], "a held second press isn't a tap")

        var lateGap = Keyboard()
        lateGap.tap(.command, at: 0, hold: 0.05)
        lateGap.tap(.command, at: 0.05 + DoubleTapDetector.maxGap + 0.01)
        expect(lateGap.fired, [], "a second tap after the gap doesn't fire")

        // Just inside both windows: the slowest double-tap that still counts.
        let epsilon = 0.001
        var atLimit = Keyboard()
        atLimit.tap(.command, at: 0, hold: DoubleTapDetector.maxHold - epsilon)
        atLimit.tap(
            .command, at: DoubleTapDetector.maxHold + DoubleTapDetector.maxGap - 2 * epsilon,
            hold: DoubleTapDetector.maxHold - epsilon)
        expect(atLimit.fired, [.command], "the slowest qualifying double-tap still fires")

        // A late second tap becomes the new first tap rather than being discarded.
        var rolling = Keyboard()
        rolling.tap(.command, at: 0)
        rolling.tap(.command, at: 1.0)
        expect(rolling.fired, [], "the late tap doesn't fire")
        rolling.tap(.command, at: 1.15)
        expect(rolling.fired, [.command], "but it seeds the next pair")
    }

    // MARK: - Chords

    static func chords() {
        var joined = Keyboard()
        joined.tap(.command, at: 0)
        joined.press([.command], at: 0.15)
        joined.press([.command, .shift], at: 0.17)
        joined.press([.command], at: 0.19)
        joined.release(at: 0.21)
        expect(joined.fired, [], "a chord unwinding back to one modifier isn't a tap")

        var chorded = Keyboard()
        chorded.press([.command, .shift], at: 0)
        chorded.release(at: 0.05)
        chorded.press([.command, .shift], at: 0.10)
        chorded.release(at: 0.15)
        expect(chorded.fired, [], "double-tapping a two-modifier chord doesn't fire")

        var mixed = Keyboard()
        mixed.tap(.command, at: 0)
        mixed.tap(.shift, at: 0.15)
        expect(mixed.fired, [], "two different modifiers aren't a double-tap")
        mixed.tap(.shift, at: 0.30)
        expect(mixed.fired, [.shift], "but the second one starts its own pair")

        var withFn = Keyboard()
        withFn.press([.command], other: true, at: 0)
        withFn.release(other: true, at: 0.05)
        withFn.press([.command], other: true, at: 0.10)
        withFn.release(other: true, at: 0.15)
        // A latched bit like Caps Lock would disqualify every press while it stays set.
        expect(withFn.fired, [], "fn held alongside disqualifies the press")

        // The poison clears once the extra modifier is gone.
        var recovered = Keyboard()
        recovered.press([.command], other: true, at: 0)
        recovered.release(at: 0.05)
        recovered.tap(.command, at: 0.10)
        recovered.tap(.command, at: 0.25)
        expect(recovered.fired, [.command], "a clean pair after the poisoned one still fires")
    }

    // MARK: - Interruptions

    static func interruptions() {
        var typed = Keyboard()
        typed.tap(.command, at: 0)
        typed.otherInput(at: 0.08)
        typed.tap(.command, at: 0.15)
        expect(typed.fired, [], "a key press between taps cancels the pair")

        var shortcut = Keyboard()
        shortcut.press([.command], at: 0)
        shortcut.otherInput(at: 0.02)
        shortcut.release(at: 0.05)
        shortcut.tap(.command, at: 0.10)
        expect(shortcut.fired, [], "⌘K then ⌘ isn't a double-tap")

        var clicked = Keyboard()
        clicked.tap(.option, at: 0)
        clicked.otherInput(at: 0.10)
        clicked.tap(.option, at: 0.14)
        expect(clicked.fired, [], "a click between taps cancels the pair")
    }

    /// Right Option held to type å or ∂ is typing, not a tap, however quick the hold.
    static func optionTyping() {
        var accented = Keyboard()
        accented.press([.option], at: 0)
        accented.otherInput(at: 0.03)
        accented.release(at: 0.06)
        accented.press([.option], at: 0.10)
        accented.otherInput(at: 0.12)
        accented.release(at: 0.14)
        expect(accented.fired, [], "two ⌥-held keystrokes never read as a double-tap")

        var typedThenTapped = Keyboard()
        typedThenTapped.press([.option], at: 0)
        typedThenTapped.otherInput(at: 0.02)
        typedThenTapped.release(at: 0.05)
        typedThenTapped.tap(.option, at: 0.10)
        typedThenTapped.tap(.option, at: 0.25)
        expect(
            typedThenTapped.fired, [.option],
            "a clean double-tap right after ⌥-typing still fires, exactly once")

        var dictated = Keyboard()
        dictated.tap(.option, at: 0)
        dictated.otherInput(at: 0.05)
        dictated.otherInput(at: 0.06)
        dictated.tap(.option, at: 0.12)
        expect(dictated.fired, [], "a foreign tool's keystrokes between taps cancel the pair")

        var shifted = Keyboard()
        shifted.press([.option], at: 0)
        shifted.press([.option, .shift], at: 0.02)
        shifted.release(at: 0.06)
        shifted.tap(.option, at: 0.10)
        expect(shifted.fired, [], "⌥⇧ held together is a chord, not the first ⌥ tap")
    }

    static func registrationIssues() {
        typealias Issue = HotKeyRegistrationIssue
        let space = kVK_Space
        let spotlight = Issue.SystemShortcut(carbonKeyCode: space, carbonModifiers: cmdKey)
        let characterViewer = Issue.SystemShortcut(
            carbonKeyCode: space, carbonModifiers: controlKey | cmdKey)
        let missionControl = Issue.SystemShortcut(
            carbonKeyCode: kVK_UpArrow, carbonModifiers: controlKey | Int(kEventKeyModifierFnMask))
        let system = [characterViewer, spotlight, missionControl]

        expect(
            Issue.diagnose(
                status: noErr, carbonKeyCode: space, carbonModifiers: optionKey,
                systemShortcuts: system) == nil,
            "⌥Space registered and unclaimed by macOS is live")
        expect(
            Issue.diagnose(
                status: noErr, carbonKeyCode: space, carbonModifiers: cmdKey,
                systemShortcuts: system) == .reservedBySystem,
            "⌘Space accepted by Carbon still loses to an enabled Spotlight shortcut")
        expect(
            Issue.diagnose(
                status: noErr, carbonKeyCode: space, carbonModifiers: cmdKey,
                systemShortcuts: [characterViewer]) == nil,
            "⌘Space is live once Spotlight's shortcut is off, whatever ⌃⌘Space does")
        expect(
            Issue.diagnose(
                status: OSStatus(eventHotKeyExistsErr), carbonKeyCode: space,
                carbonModifiers: optionKey, systemShortcuts: system) == .heldByAnotherApp,
            "an exclusive registration elsewhere reads as another app holding the chord")
        expect(
            Issue.diagnose(
                status: OSStatus(eventInternalErr), carbonKeyCode: kVK_ANSI_O,
                carbonModifiers: optionKey | shiftKey, systemShortcuts: [])
                == .refused(OSStatus(eventInternalErr)),
            "any other refusal keeps its status for the message")
        expect(
            Issue.diagnose(
                status: OSStatus(eventHotKeyExistsErr), carbonKeyCode: space,
                carbonModifiers: cmdKey, systemShortcuts: system) == .reservedBySystem,
            "a system shortcut is named ahead of whatever status came back")
        expect(
            Issue.diagnose(
                status: noErr, carbonKeyCode: kVK_UpArrow, carbonModifiers: controlKey,
                systemShortcuts: system) == .reservedBySystem,
            "macOS's fn bit on an arrow entry doesn't hide it from a recorded ⌃↑")
        expect(
            Issue.diagnose(
                status: noErr, carbonKeyCode: kVK_UpArrow, carbonModifiers: controlKey | shiftKey,
                systemShortcuts: system) == nil,
            "an extra modifier is a different chord")
        expect(
            [Issue.heldByAnotherApp, .reservedBySystem, .refused(-9868)].allSatisfy {
                $0.message.contains("retry")
            },
            "every issue message names the retry path")
    }

    // MARK: - Repeats

    static func repeats() {
        var keyboard = Keyboard()
        keyboard.tap(.command, at: 0)
        keyboard.tap(.command, at: 0.15)
        expect(keyboard.fired, [.command], "the pair fires")
        keyboard.tap(.command, at: 0.30)
        expect(keyboard.fired, [.command], "a triple-tap doesn't fire twice")
        keyboard.tap(.command, at: 0.45)
        expect(keyboard.fired, [.command, .command], "the next full pair fires again")
    }

    // MARK: - Reset

    static func resetting() {
        var keyboard = Keyboard()
        keyboard.tap(.command, at: 0)
        keyboard.detector.reset()
        keyboard.tap(.command, at: 0.15)
        expect(keyboard.fired, [], "reset drops the pending tap")

        // Reset also forgets held modifiers, so the next press still reads as a clean start.
        var stuck = Keyboard()
        stuck.press([.command], at: 0)
        stuck.detector.reset()
        stuck.tap(.command, at: 0.10)
        stuck.tap(.command, at: 0.25)
        expect(stuck.fired, [.command], "reset clears a half-held press")
    }

    // MARK: - Hyper Key rewriting

    /// ⌃⌥⇧⌘ plus the left-side device bits, and the same without ⇧.
    private static let hyperWithShift: UInt64 = 0x1E_0000 | 0x2B
    private static let hyperWithoutShift: UInt64 = 0x1C_0000 | 0x29
    /// Real events carry the non-coalesced bit; keeping it proves unrelated bits survive a rewrite.
    private static let nonCoalesced: UInt64 = 0x100
    private static let rightOptionDown: UInt64 = 0x8_0000 | 0x40 | nonCoalesced

    private static func rewrite(
        _ flags: UInt64, keyCode: Int? = nil, asFlagsChanged: Bool = false
    ) -> HyperKeyRewriter.Outcome {
        HyperKeyRewriter.Outcome(
            .rewrite(flags: flags, keyCode: keyCode.map(Int64.init), asFlagsChanged: asFlagsChanged))
    }

    static func hyperRewriting() {
        var keys = HyperKeys(.rightOption)
        expect(
            keys.key(kVK_ANSI_K, at: 0) == HyperKeyRewriter.Outcome(.pass),
            "a key typed with Hyper up passes untouched")
        expect(
            keys.modifier(flags: rightOptionDown, at: 10)
                == rewrite(rightOptionDown | hyperWithShift),
            "Right Option down becomes the whole chord, its own bits kept inside the set")
        expect(
            keys.key(kVK_ANSI_K, flags: nonCoalesced, at: 60)
                == rewrite(nonCoalesced | hyperWithShift),
            "a key typed while Hyper is held carries the chord")
        expect(
            keys.modifier(flags: nonCoalesced, at: 90) == rewrite(nonCoalesced),
            "Right Option up drops the chord")
        expect(!keys.rewriter.isHolding, "the release ends the hold")

        var shift = HyperKeys(.rightShift, includesShift: false)
        expect(
            shift.modifier(flags: 0x2_0000 | 0x4 | nonCoalesced, at: 0)
                == rewrite(nonCoalesced | hyperWithoutShift),
            "a Right Shift outside the set has its generic mask and device bit scrubbed")

        var caps = HyperKeys(.capsLock)
        expect(
            caps.key(kVK_F18, flags: 0x80_0000, at: 0)
                == rewrite(hyperWithShift, keyCode: kVK_Control, asFlagsChanged: true),
            "F18 down becomes a Control flagsChanged with fn scrubbed")
        expect(
            caps.key(kVK_F18, flags: 0x80_0000, at: 40, autorepeat: true)
                == HyperKeyRewriter.Outcome(.suppress),
            "F18 autorepeat is swallowed")
        expect(
            caps.key(kVK_F18, type: .keyUp, flags: 0x80_0000, at: 400)
                == rewrite(0, keyCode: kVK_Control, asFlagsChanged: true),
            "F18 up becomes the Control release")

        var early = HyperKeys(.capsLock)
        expect(
            early.modifier(keyCode: kVK_CapsLock, flags: 0x1_0000, at: 0)
                == rewrite(hyperWithShift, keyCode: kVK_Control),
            "before the remap lands, Caps Lock rides the modifier path without its latch bit")
    }

    static func hyperQuickPress() {
        func lonePress(heldFor milliseconds: Int, typing: Bool = false) -> HyperKeyRewriter.QuickPress? {
            var keys = HyperKeys(.capsLock, quickPress: .escape)
            _ = keys.key(kVK_F18, at: 1_000)
            if typing { _ = keys.key(kVK_ANSI_J, at: 1_000 + milliseconds / 2) }
            return keys.key(kVK_F18, type: .keyUp, at: 1_000 + milliseconds).quickPress
        }
        let escape = HyperKeyRewriter.QuickPress(action: .escape, key: .capsLock)
        expect(lonePress(heldFor: 249) == escape, "a lone press inside 250 ms fires Quick Press")
        expect(lonePress(heldFor: 250) == nil, "a press held 250 ms is a hold, not a tap")
        expect(lonePress(heldFor: 30, typing: true) == nil, "a key typed under Hyper makes a combo")

        var silent = HyperKeys(.capsLock, quickPress: .none)
        _ = silent.key(kVK_F18, at: 0)
        expect(
            silent.key(kVK_F18, type: .keyUp, at: 20).quickPress == nil,
            "Quick Press set to nothing reports nothing to fire")
    }

    /// Right Option as Hyper while Tinycast and a dictation tool both inject a phrase.
    static func hyperSynthetics() {
        var keys = HyperKeys(.rightOption, quickPress: .escape)
        _ = keys.modifier(flags: rightOptionDown, at: 0)
        let tinycast = (0..<5).map { index in
            keys.key(kVK_ANSI_A, flags: nonCoalesced, at: 10 + index, synthetic: true)
        }
        expect(
            tinycast.allSatisfy { $0 == HyperKeyRewriter.Outcome(.pass) },
            "Tinycast's own injected phrase passes with the flags it was posted with")
        expect(
            keys.modifier(flags: nonCoalesced, at: 120).quickPress
                == HyperKeyRewriter.QuickPress(action: .escape, key: .rightOption),
            "Tinycast's own keystrokes do not turn a lone press into a combo")

        _ = keys.modifier(flags: rightOptionDown, at: 500)
        let dictated = (0..<3).map { index in
            keys.key(kVK_ANSI_A, flags: nonCoalesced, at: 510 + index)
        }
        expect(
            dictated.allSatisfy { $0 == rewrite(nonCoalesced | hyperWithShift) },
            "another tool's untagged phrase is rewritten like typing while Hyper is held")
        expect(
            keys.modifier(flags: nonCoalesced, at: 560).quickPress == nil,
            "an injected phrase under Hyper makes the press a combo, so nothing fires")
    }

    static func hyperCancelledHold() {
        var heldThrough = HyperKeys(.rightOption)
        _ = heldThrough.modifier(flags: rightOptionDown, at: 0)
        heldThrough.rewriter.cancelHold()
        expect(!heldThrough.rewriter.isHolding, "re-enabling a disabled tap drops the hold")
        expect(
            heldThrough.key(kVK_ANSI_K, flags: nonCoalesced, at: 30) == HyperKeyRewriter.Outcome(.pass),
            "a key typed after the drop no longer carries the chord")
        expect(
            heldThrough.modifier(flags: nonCoalesced, at: 60) == rewrite(nonCoalesced),
            "the release of a key held across the gap reads as a release, not a new press")
        expect(
            !heldThrough.rewriter.isHolding
                && heldThrough.key(kVK_ANSI_K, at: 90) == HyperKeyRewriter.Outcome(.pass),
            "so Hyper is not left stuck down after it")
        _ = heldThrough.modifier(flags: rightOptionDown, at: 400)
        expect(
            heldThrough.key(kVK_ANSI_K, at: 420) == rewrite(hyperWithShift),
            "the next real press holds Hyper again")

        var releasedInGap = HyperKeys(.rightOption)
        _ = releasedInGap.modifier(flags: rightOptionDown, at: 0)
        releasedInGap.rewriter.cancelHold()
        expect(
            releasedInGap.modifier(flags: rightOptionDown, at: 700)
                == rewrite(rightOptionDown | hyperWithShift),
            "when the release was lost while disabled, the next press still reads as a press")

        var bitless = HyperKeys(.rightOption)
        bitless.rewriter.cancelHold()
        _ = bitless.modifier(flags: 0x8_0000, at: 0)
        expect(bitless.rewriter.isHolding, "a press missing its device bit still reads as a press")

        let leftOptionHeld: UInt64 = 0x8_0000 | 0x20 | nonCoalesced
        var twinHeld = HyperKeys(.rightOption)
        _ = twinHeld.modifier(flags: rightOptionDown | 0x20, at: 0)
        twinHeld.rewriter.cancelHold()
        expect(
            twinHeld.modifier(flags: leftOptionHeld, at: 60) == rewrite(leftOptionHeld)
                && !twinHeld.rewriter.isHolding,
            "a release under a held Left Option reads as a release: the left bit owns the mask")

        var reinstalled = HyperKeys(.rightOption)
        expect(
            reinstalled.modifier(flags: nonCoalesced, at: 0) == rewrite(nonCoalesced)
                && !reinstalled.rewriter.isHolding,
            "a fresh tap whose first event is a release of a key held since before it starts no hold")

        var caps = HyperKeys(.capsLock, quickPress: .escape)
        _ = caps.key(kVK_F18, at: 0)
        caps.rewriter.cancelHold()
        let release = caps.key(kVK_F18, type: .keyUp, at: 50)
        expect(
            release == rewrite(0, keyCode: kVK_Control, asFlagsChanged: true),
            "an F18 release after a drop still converts, and fires no Quick Press")

        var moved = HyperKeys(.rightOption)
        _ = moved.modifier(flags: rightOptionDown, at: 0)
        moved.rewriter.configure(.init(key: .rightOption, includesShift: false, quickPress: .none))
        expect(
            moved.key(kVK_ANSI_K, at: 20) == rewrite(hyperWithoutShift),
            "Include Shift moving mid-hold keeps the hold and drops ⇧ from the chord")
        moved.rewriter.configure(.init(key: .rightCommand, includesShift: false, quickPress: .none))
        expect(!moved.rewriter.isHolding, "choosing another key drops the hold")
    }
}

/// Feeds `HyperKeyRewriter` one event at a time on a virtual clock, in milliseconds.
private struct HyperKeys {
    var rewriter: HyperKeyRewriter
    private let origin = ContinuousClock.now

    init(
        _ key: HyperKeyPhysicalKey, includesShift: Bool = true,
        quickPress: HyperKeyQuickPress = .none
    ) {
        rewriter = HyperKeyRewriter(
            configuration: .init(key: key, includesShift: includesShift, quickPress: quickPress))
    }

    mutating func key(
        _ keyCode: Int, type: CGEventType = .keyDown, flags: UInt64 = 0, at milliseconds: Int,
        autorepeat: Bool = false, synthetic: Bool = false
    ) -> HyperKeyRewriter.Outcome {
        rewriter.decide(
            type: type, keyCode: keyCode, flagsRaw: flags, isAutorepeat: autorepeat,
            isSynthetic: synthetic, at: origin + .milliseconds(milliseconds))
    }

    /// A `flagsChanged` from the configured key itself unless another code is given.
    mutating func modifier(
        keyCode: Int? = nil, flags: UInt64, at milliseconds: Int
    ) -> HyperKeyRewriter.Outcome {
        key(
            keyCode ?? rewriter.configuration.key.keyCode ?? 0, type: .flagsChanged, flags: flags,
            at: milliseconds)
    }
}
