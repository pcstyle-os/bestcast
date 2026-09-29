import Foundation
import OSLog

/// One AI tool call's own runtime: loaded once, asked for `confirmation`, run, then torn down.
@MainActor
final class ExtensionToolSession: ExtensionRuntimeDelegate {
    enum Outcome: Equatable, Sendable {
        case returned(ExtensionToolReturn)
        case failed(String)
    }

    let id = UUID().uuidString
    private let runtime: ExtensionRuntime
    private let teardown: () -> Void
    private var waiting: CheckedContinuation<Outcome, Never>?
    /// A failure with nobody waiting — the bundle threw as it loaded — answers the next call.
    private var failure: String?
    private var isEnded = false

    init(runtime: ExtensionRuntime, teardown: @escaping () -> Void) {
        self.runtime = runtime
        self.teardown = teardown
        runtime.setDelegate(self)
    }

    func load(code: String, file: URL, context: ExtensionLaunchContext, support: URL) async throws {
        try await runtime.boot(config: .current(supportDirectory: support))
        await runtime.loadTool(session: id, code: code, file: file, context: context)
    }

    /// `timeout` bounds the extension's own work; a call past it is reported, not waited on.
    func call(_ export: String, input: String, timeout: Duration) async -> Outcome {
        if let failure { return .failed(failure) }
        guard !isEnded, !Task.isCancelled else { return .failed("The tool call was cancelled.") }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.settle(.failed("The tool did not finish within \(timeout.components.seconds) seconds."))
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                Task { [runtime, id] in await runtime.callTool(session: id, export: export, input: input) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.settle(.failed("The tool call was cancelled.")) }
        }
    }

    func end() {
        guard !isEnded else { return }
        isEnded = true
        settle(.failed("The tool call was cancelled."))
        Task { [runtime, id] in await runtime.stop(session: id) }
        runtime.shutdown()
        teardown()
    }

    private func settle(_ outcome: Outcome) {
        guard let waiting else {
            if case .failed(let message) = outcome, failure == nil, !isEnded { failure = message }
            return
        }
        self.waiting = nil
        waiting.resume(returning: outcome)
    }

    func runtime(_ runtime: ExtensionRuntime, session: String, didReturn json: String) {
        guard session == id else { return }
        settle(.returned(ExtensionToolReturn(json: json)))
    }

    func runtime(_ runtime: ExtensionRuntime, session: String, didFail message: String) {
        guard session == id else { return }
        settle(.failed(message))
    }

    func runtime(_ runtime: ExtensionRuntime, session: String, didRender tree: RenderTree) {}
    func runtime(_ runtime: ExtensionRuntime, session: String, navigationDepth: Int) {}
    func runtime(_ runtime: ExtensionRuntime, session: String, didFinish: Void) {}

    func runtime(_ runtime: ExtensionRuntime, log level: String, message: String) {
        if level == "error" {
            Logger(subsystem: "com.tinycast", category: "extension-tool").error(
                "\(message, privacy: .public)")
        }
    }
}
