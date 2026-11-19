import Foundation

/// The system's own region picker, then the bundled recognition helper. See
/// docs/features/screen-capture.md.
nonisolated enum ScreenRegionReader {
    /// Nil when the reader pressed Escape: `screencapture` then writes no file.
    static func read() async throws -> ScreenCaptureReading? {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bestcast-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // Interactive, silent, without the window shadow a Space-toggled window capture adds.
        process.arguments = ["-i", "-x", "-o", url.path]
        // Awaited, not waited on: the picker stays up as long as the reader takes to drag.
        try await withCheckedThrowingContinuation { (exit: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in exit.resume() }
            do { try process.run() } catch { exit.resume(throwing: error) }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let codes = try await ClipboardTextWorker.extract(at: url, mode: .codes)
        if !codes.isEmpty {
            return ScreenCaptureReading(lines: [], codes: codes.components(separatedBy: "\0"))
        }
        let text = try await ClipboardTextWorker.extract(at: url, mode: .image)
        return ScreenCaptureReading(lines: text.components(separatedBy: "\n"), codes: [])
    }
}
