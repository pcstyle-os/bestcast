import Foundation

/// Voice input's pure rules: how the heard words join the composer, and when a session ends.
@main
@MainActor
struct VoiceInputTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        transcript()
        holdToTalk()
        tapToLatch()
        toggles()
        submitting()
        cancelling()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    static func transcript() {
        var empty = VoiceTranscript(base: "")
        expect(empty.text == "", "nothing heard leaves an empty field empty")
        empty.apply("hello", isFinal: false)
        expect(empty.text == "hello", "a live guess shows at once")
        empty.apply("hello there", isFinal: false)
        expect(empty.text == "hello there", "a newer guess replaces the older one")
        empty.apply("Hello there.", isFinal: true)
        expect(empty.text == "Hello there.", "the final result replaces the guess it settles")
        expect(empty.volatile.isEmpty, "settling clears the live guess")
        empty.apply("how", isFinal: false)
        expect(empty.text == "Hello there. how", "the next guess follows the settled words")
        empty.apply("How are you?", isFinal: true)
        expect(empty.text == "Hello there. How are you?", "settled segments join with one space")

        var typed = VoiceTranscript(base: "Summarise")
        expect(typed.text == "Summarise", "the typed text stays until something is heard")
        typed.apply(" this page ", isFinal: false)
        expect(typed.text == "Summarise this page", "speech is spaced from the typed text")

        var spaced = VoiceTranscript(base: "Translate: ")
        spaced.apply("bonjour", isFinal: true)
        expect(spaced.text == "Translate: bonjour", "a trailing space is not doubled")

        var lines = VoiceTranscript(base: "first line\n")
        lines.apply("second", isFinal: true)
        expect(lines.text == "first line\nsecond", "a trailing newline counts as the separator")

        var blank = VoiceTranscript(base: "ask")
        blank.apply("   ", isFinal: false)
        blank.apply("", isFinal: true)
        expect(blank.text == "ask", "silence adds nothing, not even a space")
        expect(blank.spoken.isEmpty, "silence leaves nothing spoken")
    }

    static func holdToTalk() {
        var machine = VoiceDictationMachine()
        expect(machine.press(at: t0, autoSend: false) == .start, "a press starts listening")
        expect(machine.phase == .starting, "listening waits on permissions and the model")
        machine.started()
        expect(machine.phase == .listening, "the service reports it is hearing")
        let release = machine.release(at: t0.addingTimeInterval(1.2), autoSend: false)
        expect(release == .stop, "releasing after a hold stops")
        expect(machine.phase == .finishing, "stopping waits for the last words")
        expect(!machine.finished(), "a hold without auto-send leaves the words to review")
        expect(machine.phase == .idle, "the session is over once it finishes")

        var sending = VoiceDictationMachine()
        _ = sending.press(at: t0, autoSend: true)
        sending.started()
        _ = sending.release(at: t0.addingTimeInterval(2), autoSend: true)
        expect(sending.finished(), "auto-send sends once the words settle")

        var early = VoiceDictationMachine()
        _ = early.press(at: t0, autoSend: false)
        let before = early.release(at: t0.addingTimeInterval(1), autoSend: false)
        expect(before == .stop, "a hold released before the mic is up still stops")
        early.started()
        expect(early.phase == .finishing, "a late start report does not revive a stopped session")
    }

    static func tapToLatch() {
        var machine = VoiceDictationMachine()
        _ = machine.press(at: t0, autoSend: false)
        machine.started()
        let tap = machine.release(at: t0.addingTimeInterval(0.1), autoSend: false)
        expect(tap == .none, "a quick tap keeps listening hands-free")
        expect(machine.phase == .listening, "a latched session is still listening")
        let second = machine.press(at: t0.addingTimeInterval(5), autoSend: true)
        expect(second == .stop, "the next press ends a latched session")
        let secondUp = machine.release(at: t0.addingTimeInterval(6), autoSend: true)
        expect(secondUp == .none, "the release of the stopping press is ignored")
        expect(machine.finished(), "the stopping press carries the auto-send setting")

        var repeats = VoiceDictationMachine()
        _ = repeats.press(at: t0, autoSend: false)
        let again = repeats.press(at: t0.addingTimeInterval(0.2), autoSend: false)
        expect(again == .none, "a second down while held does not stop")
        let threshold = VoiceDictationMachine.holdThreshold
        let exact = repeats.release(at: t0.addingTimeInterval(threshold), autoSend: false)
        expect(exact == .stop, "a hold exactly at the threshold counts as a hold")

        var stray = VoiceDictationMachine()
        expect(stray.release(at: t0, autoSend: false) == .none, "a release without a press is ignored")
        expect(stray.phase == .idle, "a stray release starts nothing")
    }

    static func toggles() {
        var machine = VoiceDictationMachine()
        expect(machine.toggle(autoSend: false) == .start, "the button starts listening")
        machine.started()
        let keyDown = machine.press(at: t0, autoSend: false)
        expect(keyDown == .stop, "the key ends what the button started")

        var button = VoiceDictationMachine()
        _ = button.toggle(autoSend: false)
        expect(button.toggle(autoSend: true) == .stop, "the button stops what it started")
        expect(button.toggle(autoSend: true) == .none, "pressing again while finishing waits")
        expect(button.finished(), "the stop carries auto-send")
        expect(button.toggle(autoSend: false) == .start, "a finished session can start again")
    }

    static func submitting() {
        var machine = VoiceDictationMachine()
        expect(machine.submit() == .none, "return while idle is the ordinary send")
        _ = machine.toggle(autoSend: false)
        machine.started()
        expect(machine.submit() == .stop, "return while listening stops first")
        expect(machine.finished(), "and sends once the words settle, auto-send or not")

        var late = VoiceDictationMachine()
        _ = late.toggle(autoSend: false)
        _ = late.toggle(autoSend: false)
        expect(late.submit() == .none, "return while finishing has nothing more to stop")
        expect(late.finished(), "but still sends when the words land")
    }

    static func cancelling() {
        var machine = VoiceDictationMachine()
        expect(machine.cancel() == .none, "cancelling nothing does nothing")
        _ = machine.press(at: t0, autoSend: true)
        machine.started()
        expect(machine.cancel() == .cancel, "escape drops the session")
        expect(machine.phase == .idle, "a cancelled session is over at once")
        expect(!machine.finished(), "the service's own end after a cancel never sends")

        var failed = VoiceDictationMachine()
        _ = failed.toggle(autoSend: true)
        failed.started()
        expect(!failed.finished(), "a session that ends on its own never sends")
        expect(!failed.isActive, "and leaves the machine idle")
    }
}
