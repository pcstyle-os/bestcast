import AVFoundation
import Speech
import os

/// On-device dictation through SpeechAnalyzer: the audio and the words never leave the Mac.
nonisolated enum DictationService {
    enum Readiness: Sendable {
        case ready
        case needsDownload
        case unsupported
    }

    enum Event: Sendable {
        case listening
        case text(String, isFinal: Bool)
    }

    enum Ending: Sendable {
        case finish
        case cancel
    }

    enum Failure: Error {
        case unsupported
        case noMicrophone
    }

    private static let logger = Logger(subsystem: "com.tinycast", category: "Dictation")

    static func readiness(for locale: Locale) async -> Readiness {
        guard SpeechTranscriber.isAvailable,
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return .unsupported }
        switch await AssetInventory.status(forModules: [transcriber(for: supported)]) {
        case .installed: return .ready
        case .supported, .downloading: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Apple's own download of the speech model; the audio itself is never sent anywhere.
    static func installModel(for locale: Locale) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupported
        }
        let modules: [any SpeechModule] = [transcriber(for: supported)]
        try await AssetInventory.assetInstallationRequest(supporting: modules)?.downloadAndInstall()
    }

    /// Hears the microphone until `endings` says how to stop; a cancelled task counts as cancel.
    static func listen(
        locale: Locale, until endings: AsyncStream<Ending>,
        reporting events: AsyncStream<Event>.Continuation
    ) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupported
        }
        let transcriber = transcriber(for: supported)
        let modules: [any SpeechModule] = [transcriber]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        else { throw Failure.unsupported }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let microphone = input.outputFormat(forBus: 0)
        guard microphone.channelCount > 0,
            let converter = AVAudioConverter(from: microphone, to: format)
        else { throw Failure.noMicrophone }

        let results = transcriber.results
        let reader = Task {
            for try await result in results {
                events.yield(.text(String(result.text.characters), isFinal: result.isFinal))
            }
        }
        let (feed, feeder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: modules)
        installTap(on: input, format: microphone, converter: converter, into: feeder)
        do {
            try await analyzer.start(inputSequence: feed)
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            feeder.finish()
            await analyzer.cancelAndFinishNow()
            reader.cancel()
            logger.error("Dictation could not start: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        events.yield(.listening)

        var ending = Ending.cancel
        for await next in endings {
            ending = next
            break
        }
        engine.stop()
        input.removeTap(onBus: 0)
        feeder.finish()
        switch ending {
        case .finish:
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await reader.value
        case .cancel:
            await analyzer.cancelAndFinishNow()
            reader.cancel()
        }
    }

    private static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
            attributeOptions: [])
    }

    /// Built outside any actor: the tap runs on the audio thread, where an isolated closure traps.
    private static func installTap(
        on input: AVAudioInputNode, format microphone: AVAudioFormat,
        converter: AVAudioConverter, into feeder: AsyncStream<AnalyzerInput>.Continuation
    ) {
        let target = converter.outputFormat
        let ratio = target.sampleRate / microphone.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: microphone) { buffer, _ in
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else { return }
            let pending = PendingBuffer(buffer)
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                guard let next = pending.take() else {
                    status.pointee = .noDataNow
                    return nil
                }
                status.pointee = .haveData
                return next
            }
            guard error == nil, converted.frameLength > 0 else { return }
            feeder.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// The converter's input block is `@Sendable`, yet it only runs inside `convert`'s own call.
    private final class PendingBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}
