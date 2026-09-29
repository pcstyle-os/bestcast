import AVFoundation
import Observation

/// Reads one reply aloud at a time, on-device; pressing Speak on the same reply again stops it.
@MainActor
@Observable
final class ChatSpeaker: NSObject {
    private(set) var speakingID: UUID?
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    /// The utterance still owed a finish, so a stopped one ending late cannot clear a newer one.
    @ObservationIgnored private var current: ObjectIdentifier?

    func toggle(_ id: UUID, text: String) {
        if speakingID == id {
            stop()
            return
        }
        stop()
        let spoken = Self.plain(text)
        guard !spoken.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: spoken)
        current = ObjectIdentifier(utterance)
        speakingID = id
        (synthesizer ?? makeSynthesizer()).speak(utterance)
    }

    func stop() {
        current = nil
        speakingID = nil
        synthesizer?.stopSpeaking(at: .immediate)
    }

    private func makeSynthesizer() -> AVSpeechSynthesizer {
        let made = AVSpeechSynthesizer()
        made.delegate = self
        synthesizer = made
        return made
    }

    private func finished(_ utterance: ObjectIdentifier) {
        guard current == utterance else { return }
        current = nil
        speakingID = nil
    }

    /// Markup read aloud is noise: the voice gets the text the transcript draws.
    private static func plain(_ markdown: String) -> String {
        let text = ChatChoices.split(markdown).text
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let rendered = (try? AttributedString(markdown: text, options: options))
            .map { String($0.characters) } ?? text
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ChatSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
}
