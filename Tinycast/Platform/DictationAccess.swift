import Foundation

/// What the Mac lets dictation use: it needs both the microphone and speech recognition.
enum DictationAccess: Sendable {
    case granted
    case microphoneDenied
    case speechDenied
}
