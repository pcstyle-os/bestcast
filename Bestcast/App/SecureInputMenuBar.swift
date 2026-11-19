import SwiftUI

/// Shown only while Secure Input silences a keystroke feature. See docs/features/hotkeys.md#secure-input.
struct SecureInputMenuBarLabel: View {
    let holder: SecureInputMonitor.Holder?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
            if let name = holder?.name { Text(name) }
        }
        .accessibilityLabel(holder?.name.map { "Secure Input is on, reported by \($0)" } ?? "Secure Input is on")
    }
}

struct SecureInputMenuBarMenu: View {
    let monitor: SecureInputMonitor

    var body: some View {
        let name = monitor.holder?.name
        Text(name.map { "Secure Input is on, reported by \($0)" } ?? "Secure Input is on")
        Text("Paused: " + monitor.pausedFeatures.joined(separator: ", "))
        if let app = monitor.holder?.app, let name {
            Divider()
            Button("Show \(name)") { app.activate() }
            // `terminate` asks the app to quit, so unsaved work still gets its own prompt.
            Button("Quit \(name)") { app.terminate() }
        }
    }
}
