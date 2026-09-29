import AppKit
import Observation

/// Voice input for both AI composers: permissions, the on-device model, and the words as they land.
@MainActor
@Observable
final class DictationCoordinator {
    enum Target: Equatable {
        case quickAI
        case window
    }

    private(set) var target: Target?
    private var machine = VoiceDictationMachine()
    @ObservationIgnored private var transcript = VoiceTranscript(base: "")
    /// Bumped per session, so a cancelled one's late words never land in the next one's field.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var endings: AsyncStream<DictationService.Ending>.Continuation?
    /// ⌥Space went down as dictation's, so its release is dictation's too, whatever else changed.
    @ObservationIgnored private var holdsKey = false
    private unowned let core: AppCore

    init(core: AppCore) {
        self.core = core
    }

    var phase: VoiceDictationMachine.Phase { machine.phase }

    func isActive(in target: Target) -> Bool {
        self.target == target && machine.isActive
    }

    private var autoSend: Bool { core.aiSettings.voiceAutoSend }

    // MARK: - Gestures

    /// The mic button and ⌘K: a toggle, since neither has a release to wait for.
    func toggle(in target: Target) {
        guard core.settings.aiEnabled else { return }
        retarget(to: target)
        apply(machine.toggle(autoSend: autoSend), in: target)
    }

    /// Ask AI by Voice: Quick AI opens listening, and a second run while it listens stops.
    func askByVoice() {
        guard core.settings.aiEnabled else { return }
        if !core.paletteCoordinator.isShowing(.ai) {
            cancel()
            core.quickAICoordinator.show()
        }
        toggle(in: .quickAI)
    }

    /// ⌥Space down; auto-repeats are swallowed so a hold never types spaces into the field.
    func keyDown(in target: Target, isRepeat: Bool) {
        guard core.settings.aiEnabled else { return }
        holdsKey = true
        guard !isRepeat else { return }
        retarget(to: target)
        apply(machine.press(at: Date(), autoSend: autoSend), in: target)
    }

    /// ⌥Space up; false when the matching down was never dictation's.
    func keyUp() -> Bool {
        guard holdsKey else { return false }
        holdsKey = false
        if let target { apply(machine.release(at: Date(), autoSend: autoSend), in: target) }
        return true
    }

    /// Return while dictating sends once the last words land; false leaves Return its own send.
    func submit(in target: Target) -> Bool {
        guard isActive(in: target) else { return false }
        apply(machine.submit(), in: target)
        return true
    }

    /// Escape, a hidden palette or AI switched off: the heard words go, the typed ones stay.
    @discardableResult
    func cancel(in target: Target? = nil) -> Bool {
        guard let current = self.target, target == nil || target == current,
            machine.cancel() == .cancel
        else { return false }
        endSession(.cancel)
        write(transcript.base, to: current)
        self.target = nil
        return true
    }

    func paletteDidHide() {
        cancel(in: .quickAI)
    }

    // MARK: - Session

    private func retarget(to target: Target) {
        if let current = self.target, current != target { cancel() }
    }

    private func apply(_ effect: VoiceDictationMachine.Effect, in target: Target) {
        switch effect {
        case .none: break
        case .start: start(in: target)
        case .stop: endings?.yield(.finish)
        case .cancel: cancel()
        }
    }

    private func start(in target: Target) {
        // Its own voice would be heard and typed back into the question.
        core.aiChatCoordinator.speaker.stop()
        self.target = target
        transcript = VoiceTranscript(base: text(in: target))
        generation += 1
        let session = generation
        let (endingStream, endings) = AsyncStream.makeStream(of: DictationService.Ending.self)
        self.endings = endings
        let locale = Locale.current
        Task { [weak self] in
            guard let self else { return }
            guard await prepare(locale), generation == session, machine.phase == .starting else {
                conclude(session, failure: nil)
                return
            }
            let (events, reporter) = AsyncStream.makeStream(of: DictationService.Event.self)
            let listening = Task.detached {
                defer { reporter.finish() }
                try await DictationService.listen(
                    locale: locale, until: endingStream, reporting: reporter)
            }
            for await event in events where generation == session {
                receive(event)
            }
            let failure: (any Error)?
            do {
                try await listening.value
                failure = nil
            } catch {
                failure = error
            }
            conclude(session, failure: failure)
        }
    }

    private func receive(_ event: DictationService.Event) {
        guard let target else { return }
        // Leaving Quick AI for its history or the launcher takes the field with it.
        if target == .quickAI, core.palette.mode != .ai {
            cancel()
            return
        }
        switch event {
        case .listening:
            machine.started()
        case .text(let text, let isFinal):
            transcript.apply(text, isFinal: isFinal)
            write(transcript.text, to: target)
        }
    }

    private func conclude(_ session: Int, failure: (any Error)?) {
        guard generation == session, let target else { return }
        let send = machine.finished()
        endings = nil
        self.target = nil
        if let failure { report(failure) }
        guard send, !transcript.spoken.isEmpty else { return }
        sendTranscript(from: target)
    }

    private func endSession(_ ending: DictationService.Ending) {
        generation += 1
        endings?.yield(ending)
        endings?.finish()
        endings = nil
    }

    // MARK: - Composers

    private func text(in target: Target) -> String {
        switch target {
        case .quickAI: core.palette.query
        case .window: core.aiChats.window.draft
        }
    }

    private func write(_ text: String, to target: Target) {
        switch target {
        case .quickAI:
            guard core.palette.mode == .ai else { return }
            core.palette.query = text
        case .window:
            core.aiChats.window.draft = text
        }
    }

    private func sendTranscript(from target: Target) {
        switch target {
        case .quickAI:
            guard core.palette.mode == .ai,
                core.aiChatCoordinator.sendSpoken(core.palette.query, in: core.aiChats.quickAI)
            else { return }
            core.palette.query = ""
        case .window:
            let chat = core.aiChats.window
            guard core.aiChatCoordinator.sendSpoken(chat.draft, in: chat) else { return }
            chat.draft = ""
        }
    }

    // MARK: - Permissions and the model

    /// Asked on the first dictation only; a refusal is explained once, with the way back.
    private func prepare(_ locale: Locale) async -> Bool {
        let access = await Permissions.requestDictationAccess()
        guard access == .granted else {
            await reportRefusal(access)
            return false
        }
        switch await DictationService.readiness(for: locale) {
        case .ready:
            return true
        case .unsupported:
            core.showMessage("Dictation isn't available in \(languageName(locale))", tone: .danger)
            return false
        case .needsDownload:
            await offerDownload(locale)
            return false
        }
    }

    private func offerDownload(_ locale: Locale) async {
        let language = languageName(locale)
        NSApp.activate(ignoringOtherApps: true)
        guard
            await core.confirm(
                title: "Download \(language) dictation?",
                message:
                    "Dictation runs on this Mac and needs Apple's speech model for \(language) "
                    + "first. It downloads once; what you say is never sent anywhere.",
                symbol: "mic", confirmTitle: "Download", tone: .neutral, confirmRole: .standard)
        else { return }
        core.showProgress("Downloading the speech model…")
        do {
            try await Task.detached { try await DictationService.installModel(for: locale) }.value
            core.hideProgress()
            core.showMessage("Dictation is ready. Press ⌥Space to talk.")
        } catch {
            core.hideProgress()
            core.showMessage("The speech model didn't download", tone: .danger)
        }
    }

    private func reportRefusal(_ access: DictationAccess) async {
        let microphone = access == .microphoneDenied
        let permission = microphone ? "Microphone" : "Speech Recognition"
        NSApp.activate(ignoringOtherApps: true)
        guard
            await core.reportFailure(
                title: "Tinycast can't hear you",
                message:
                    "Dictation needs the \(permission) permission. Turn it on for Tinycast in "
                    + "System Settings, then try again.",
                symbol: "mic.slash", recovery: "Open System Settings")
        else { return }
        if microphone {
            Permissions.openMicrophoneSettings()
        } else {
            Permissions.openSpeechRecognitionSettings()
        }
    }

    private func report(_ failure: any Error) {
        switch failure {
        case DictationService.Failure.noMicrophone:
            core.showMessage("No microphone to dictate with", tone: .danger)
        case DictationService.Failure.unsupported:
            core.showMessage("Dictation isn't available in this language", tone: .danger)
        default:
            core.showMessage("Dictation stopped: \(failure.localizedDescription)", tone: .danger)
        }
    }

    private func languageName(_ locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
