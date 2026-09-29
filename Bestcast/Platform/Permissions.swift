import AVFoundation
import AppKit
import EventKit
import Speech
// `@preconcurrency` downgrades AX diagnostics: the option key is a constant C global.
@preconcurrency import ApplicationServices

enum Permissions {
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Returns current trust state and prompts the user to grant it if needed.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @MainActor
    static func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func openAutomationSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Checked, never requested: only the user's own visit to System Settings grants it.
    static func isScreenRecordingTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    static func openScreenRecordingSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func calendarAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        // Write-only is the same as nothing here: Bestcast only ever reads.
        default: return .denied
        }
    }

    /// The store is built and dropped here: a grant is process-wide, so nothing travels.
    nonisolated static func requestCalendarAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    static func cameraAccess() -> CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// The one camera prompt, raised from the gesture that asked for it.
    nonisolated static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Asks only for what is still undecided, microphone first, from the gesture that dictates.
    nonisolated static func requestDictationAccess() async -> DictationAccess {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return .microphoneDenied
        }
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        return speech == .authorized ? .granted : .speechDenied
    }

    @MainActor
    static func openMicrophoneSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func openSpeechRecognitionSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func openCalendarSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
