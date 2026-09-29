import Foundation

/// The composer while dictating: what was typed first, the settled speech, and the live guess.
struct VoiceTranscript: Equatable, Sendable {
    let base: String
    private(set) var settled: [String] = []
    private(set) var volatile = ""

    init(base: String) {
        self.base = base
    }

    /// A final result settles the words heard so far; a volatile one only replaces the live guess.
    mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            settled.append(text)
            volatile = ""
        } else {
            volatile = text
        }
    }

    var spoken: String {
        (settled + [volatile])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var text: String {
        let spoken = spoken
        guard !spoken.isEmpty else { return base }
        guard let last = base.last else { return spoken }
        return last.isWhitespace ? base + spoken : base + " " + spoken
    }
}

/// Hold-to-talk and toggle on one key: a long hold ends on release, a tap latches until the next.
struct VoiceDictationMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// Permissions and the on-device model are being checked; nothing is heard yet.
        case starting
        case listening
        /// Told to stop, waiting for the last words to settle.
        case finishing
    }

    enum Effect: Equatable, Sendable {
        case none
        case start
        case stop
        case cancel
    }

    static let holdThreshold: TimeInterval = 0.35

    private(set) var phase: Phase = .idle
    private(set) var sendsWhenDone = false
    private var pressedAt: Date?
    private var latched = false

    var isActive: Bool { phase != .idle }

    /// A key-down; the caller drops auto-repeats, which would otherwise read as a second press.
    mutating func press(at now: Date, autoSend: Bool) -> Effect {
        switch phase {
        case .idle:
            begin(latched: false)
            pressedAt = now
            return .start
        case .starting, .listening:
            return latched ? stop(sending: autoSend) : .none
        case .finishing:
            return .none
        }
    }

    mutating func release(at now: Date, autoSend: Bool) -> Effect {
        guard let pressedAt else { return .none }
        self.pressedAt = nil
        guard phase == .starting || phase == .listening else { return .none }
        if now.timeIntervalSince(pressedAt) >= Self.holdThreshold {
            return stop(sending: autoSend)
        }
        latched = true
        return .none
    }

    /// The mic button and Ask AI by Voice, which have no release to wait for.
    mutating func toggle(autoSend: Bool) -> Effect {
        switch phase {
        case .idle:
            begin(latched: true)
            return .start
        case .starting, .listening:
            return stop(sending: autoSend)
        case .finishing:
            return .none
        }
    }

    /// Return while dictating sends, but only once the words still in flight have landed.
    mutating func submit() -> Effect {
        switch phase {
        case .idle:
            return .none
        case .starting, .listening:
            return stop(sending: true)
        case .finishing:
            sendsWhenDone = true
            return .none
        }
    }

    mutating func started() {
        if phase == .starting { phase = .listening }
    }

    /// The session ended on its own or as asked; true when the transcript should now be sent.
    mutating func finished() -> Bool {
        let send = phase == .finishing && sendsWhenDone
        self = Self()
        return send
    }

    mutating func cancel() -> Effect {
        guard phase != .idle else { return .none }
        self = Self()
        return .cancel
    }

    private mutating func begin(latched: Bool) {
        phase = .starting
        sendsWhenDone = false
        self.latched = latched
    }

    private mutating func stop(sending: Bool) -> Effect {
        phase = .finishing
        sendsWhenDone = sending
        pressedAt = nil
        return .stop
    }
}
