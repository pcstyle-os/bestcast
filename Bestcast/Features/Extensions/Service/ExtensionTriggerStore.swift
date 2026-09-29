import Foundation

/// Every trigger's consent and history, the master pause, and cross-extension approvals.
/// Its own file so no settings backup or `settings.json` mirror can ever carry a grant.
@MainActor
@Observable
final class ExtensionTriggerStore {
    private struct Contents: Codable {
        var isPaused = false
        var triggers: [String: [String: ExtensionTriggerState]] = [:]
        /// `target/export` → the extensions the user let call it.
        var approvedCallers: [String: Set<String>] = [:]
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    private var contents: Contents

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        contents =
            (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) }
            ?? Contents()
    }

    var isPaused: Bool {
        get { contents.isPaused }
        set {
            guard newValue != contents.isPaused else { return }
            contents.isPaused = newValue
            scheduleFlush()
        }
    }

    func state(extension name: String, trigger: String) -> ExtensionTriggerState {
        contents.triggers[name]?[trigger] ?? ExtensionTriggerState()
    }

    func update(extension name: String, trigger: String, _ body: (inout ExtensionTriggerState) -> Void) {
        var record = state(extension: name, trigger: trigger)
        body(&record)
        guard contents.triggers[name]?[trigger] != record else { return }
        contents.triggers[name, default: [:]][trigger] = record
        scheduleFlush()
    }

    func isApproved(caller: String, extension target: String, export: String) -> Bool {
        contents.approvedCallers[ExtensionTriggerPolicy.callKey(extension: target, export: export)]?
            .contains(caller) == true
    }

    func approve(caller: String, extension target: String, export: String) {
        contents.approvedCallers[
            ExtensionTriggerPolicy.callKey(extension: target, export: export), default: []
        ].insert(caller)
        scheduleFlush()
    }

    func approvedCallers(extension target: String) -> [(export: String, caller: String)] {
        contents.approvedCallers.flatMap { key, callers -> [(export: String, caller: String)] in
            guard key.hasPrefix(target + "/") else { return [] }
            let export = String(key.dropFirst(target.count + 1))
            guard !export.contains("/") else { return [] }
            return callers.sorted().map { (export: export, caller: $0) }
        }
        .sorted { ($0.export, $0.caller) < ($1.export, $1.caller) }
    }

    func revoke(caller: String, extension target: String, export: String) {
        let key = ExtensionTriggerPolicy.callKey(extension: target, export: export)
        guard contents.approvedCallers[key]?.remove(caller) != nil else { return }
        if contents.approvedCallers[key]?.isEmpty == true { contents.approvedCallers[key] = nil }
        scheduleFlush()
    }

    /// Uninstall forgets it both ways: its own triggers and approvals, and every grant it was given.
    func forget(extension name: String) {
        contents.triggers[name] = nil
        for key in Array(contents.approvedCallers.keys) {
            let isTarget =
                key.hasPrefix(name + "/") && !key.dropFirst(name.count + 1).contains("/")
            contents.approvedCallers[key]?.remove(name)
            if isTarget || contents.approvedCallers[key]?.isEmpty == true {
                contents.approvedCallers[key] = nil
            }
        }
        scheduleFlush()
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard isDirty, let data = try? JSONEncoder().encode(contents) else { return }
        isDirty = false
        try? data.write(to: fileURL, options: .atomic)
    }

    private func scheduleFlush() {
        isDirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.flush()
        }
    }
}
