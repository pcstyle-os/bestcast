import AppKit

/// Capture Text from Screen and Pick Color. See docs/features/screen-capture.md.
@MainActor
final class ScreenCaptureCoordinator {
    private unowned let core: AppCore
    private var capture: Task<Void, Never>?
    /// Kept alive while its loupe is up; the sampler ends itself on a click or Escape.
    private var sampler: NSColorSampler?

    init(core: AppCore) {
        self.core = core
    }

    func captureText() {
        guard capture == nil else { return }
        guard Permissions.isScreenRecordingTrusted() else {
            Task { await reportScreenRecordingRefusal() }
            return
        }
        capture = Task { [weak self] in
            let result = await Task.detached { try await ScreenRegionReader.read() }.result
            guard let self else { return }
            capture = nil
            guard case .success(let reading) = result else {
                core.showMessage("Couldn’t read the text", tone: .danger)
                return
            }
            // Nil is an Escape out of the picker, which wants no report.
            guard let reading else { return }
            if let copied = reading.copied { Paster.copyPlainText(copied) }
            core.showMessage(reading.message, tone: reading.copied == nil ? .neutral : .success)
        }
    }

    func pickColor() {
        guard sampler == nil else { return }
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            MainActor.assumeIsolated {
                self?.sampler = nil
                guard let color = color?.usingColorSpace(.sRGB) else { return }
                let hex = HexColor.string(
                    red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
                Paster.copyPlainText(hex)
                self?.core.showMessage("Copied \(hex)")
            }
        }
    }

    private func reportScreenRecordingRefusal() async {
        NSApp.activate(ignoringOtherApps: true)
        guard
            await core.reportFailure(
                title: "Bestcast can't read the screen",
                message:
                    "Capture Text needs the Screen Recording permission. Turn it on for Bestcast "
                    + "in System Settings, then try again.",
                symbol: "text.viewfinder", recovery: "Open System Settings")
        else { return }
        Permissions.openScreenRecordingSettings()
    }
}
