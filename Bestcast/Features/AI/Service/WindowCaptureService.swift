import AppKit
import ScreenCaptureKit

/// One still of an app's frontmost window, for Quick AI to stage; every call runs off-main.
nonisolated enum WindowCaptureService {
    enum Failure: Error {
        case noWindow
        case captureFailed
    }

    /// PNG bytes of the front on-screen, normal-layer window `pid` owns.
    static func captureFrontWindow(of pid: pid_t) async throws -> Data {
        guard let windowID = frontWindowID(of: pid) else { throw Failure.noWindow }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw Failure.noWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure.captureFailed }
        return png
    }

    /// The window server lists on-screen windows front to back, which ScreenCaptureKit does not.
    private static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (info[kCGWindowLayer as String] as? Int) == 0,
                let number = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return number
        }
        return nil
    }
}
