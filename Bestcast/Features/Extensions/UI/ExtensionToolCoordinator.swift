import Foundation

/// Installed extensions' AI tools, handed to chat as plain `AITool`s and `@` sources.
@MainActor
final class ExtensionToolCoordinator {
    /// Past this a tool is reported as stuck; a network call on a slow link fits well inside.
    static let callTimeout: Duration = .seconds(60)
    static let symbol = "puzzlepiece.extension"

    private unowned let core: AppCore
    private lazy var endpoint = LoopbackToolEndpoint(
        service: LoopbackToolEndpoint.Service(
            server: { [weak self] handle in
                self?.sources.first { $0.handle == handle }?.loopbackServer
            },
            call: { [weak self] handle, name, arguments in
                guard let self, let source = sources.first(where: { $0.handle == handle }),
                    let tool = source.tool(innerName: name)
                else { return .failure("", "No extension offers \(name) any more.") }
                return await run(tool, of: source, arguments: arguments, callID: "")
            }))

    init(core: AppCore) {
        self.core = core
    }

    /// Everything installed with tools; a turn only reaches the ones it `@`-names.
    var sources: [ExtensionToolSource] {
        guard core.settings.aiEnabled, core.extensions.isEnabled else { return [] }
        return ExtensionToolPolicy.sources(
            core.extensions.installed.map(\.manifest),
            taken: BuiltInIntegration.handles.union(core.mcpCoordinator.slugs))
    }

    var handles: Set<String> { Set(sources.map(\.handle)) }

    var chatSources: [ChatToolSource] {
        sources.map {
            ChatToolSource(handle: $0.handle, title: $0.title, symbol: Self.symbol, kind: .raycastExtension)
        }
    }

    func tools(scopedTo scope: Set<String>?, excluded: Set<String>) -> [AITool] {
        offered(scopedTo: scope, excluded: excluded).flatMap(\.aiTools)
    }

    /// What the addressed extensions' `ai.instructions` ask the model to know.
    func instructions(scopedTo scope: Set<String>?, excluded: Set<String>) -> String? {
        ExtensionToolPolicy.instructions(for: offered(scopedTo: scope, excluded: excluded))
    }

    /// The same list for a CLI route: one loopback server per addressed extension.
    func toolServers(scopedTo scope: Set<String>?, excluded: Set<String>) async -> [AIToolServer] {
        let offered = offered(scopedTo: scope, excluded: excluded)
        guard !offered.isEmpty, let port = await endpoint.start() else { return [] }
        return offered.map { source in
            AIToolServer(
                handle: source.handle, title: source.title,
                transport: .url(
                    endpoint.url(port: port, handle: source.handle),
                    headerName: "Authorization", headerValue: "Bearer \(endpoint.token)"))
        }
    }

    func owns(_ wireName: String) -> Bool {
        sources.contains { $0.tool(wireName: wireName) != nil }
    }

    /// A CLI asks before every call; the extension's own question is asked at the endpoint.
    func permit(_ call: AIToolServerCall) -> Bool {
        sources.first { $0.handle == call.handle }?.tool(innerName: call.tool) != nil
    }

    func invoke(_ call: AIToolCall) async -> AIToolResult {
        for source in sources {
            if let tool = source.tool(wireName: call.name) {
                return await run(tool, of: source, arguments: call.arguments, callID: call.id)
            }
        }
        return .failure(call.id, "No installed extension has a tool called \(call.name).")
    }

    /// Nothing left on offer means nothing listening, and a CLI launched with one loses it.
    func applyEnabled() {
        if sources.isEmpty { endpoint.stop() }
        core.mcpCoordinator.dropWithdrawnServers()
    }

    private func offered(scopedTo scope: Set<String>?, excluded: Set<String>) -> [ExtensionToolSource] {
        ExtensionToolPolicy.offered(sources, scope: scope, excluded: excluded)
    }

    private func run(
        _ tool: ExtensionTool, of source: ExtensionToolSource, arguments: String, callID: String
    ) async -> AIToolResult {
        let input = arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : arguments
        let session: ExtensionToolSession
        do {
            session = try await core.extensions.openToolSession(
                extensionName: source.extensionName, tool: tool)
        } catch {
            return .failure(callID, error.localizedDescription)
        }
        defer { session.end() }
        let confirmation: ExtensionToolReturn
        switch await session.call("confirmation", input: input, timeout: Self.callTimeout) {
        case .failed(let message): return .failure(callID, message)
        case .returned(let answer): confirmation = answer
        }
        let verdict = ExtensionToolPolicy.decide(tool, of: source, confirmation: confirmation, input: input)
        if case .ask(let prompt) = verdict {
            guard
                await core.builtInTools.confirm(
                    title: prompt.title, message: prompt.message, confirmTitle: prompt.confirmTitle,
                    symbol: Self.symbol, isDestructive: prompt.isDestructive)
            else { return .failure(callID, "The user declined this tool call.") }
        }
        switch await session.call("default", input: input, timeout: Self.callTimeout) {
        case .failed(let message):
            return .failure(callID, message)
        case .returned(.missing):
            return .failure(callID, "\(tool.title) has no default export to run.")
        case .returned(.value(let value)):
            return AIToolResult(callID: callID, content: ExtensionToolOutput.text(value), isError: false)
        }
    }
}
