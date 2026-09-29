import Foundation

/// Every extension's recent log lines, by manifest name; memory only, gone at quit.
@MainActor
@Observable
final class ExtensionConsole {
    private(set) var buffers: [String: ExtensionConsoleBuffer] = [:]

    func record(level: String, message: String, stack: String?, extension name: String) {
        buffers[name, default: ExtensionConsoleBuffer()].append(
            level: ExtensionConsoleLevel(runtimeLevel: level), message: message, stack: stack,
            at: Date())
    }

    func entries(for name: String) -> [ExtensionConsoleEntry] {
        buffers[name]?.entries ?? []
    }

    func clear(_ name: String) {
        buffers[name]?.clear()
    }

    func remove(_ name: String) {
        buffers[name] = nil
    }
}
