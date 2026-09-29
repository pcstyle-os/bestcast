import Foundation

/// Bestcast's own tools: what a turn is offered, who is asked first, and the endpoint CLIs reach.
@MainActor
final class BuiltInToolCoordinator {
    private unowned let core: AppCore
    private let runner: BuiltInToolRunner
    private lazy var endpoint = LoopbackToolEndpoint(
        service: LoopbackToolEndpoint.Service(
            server: { [weak self] handle in
                guard let self, let integration = BuiltInIntegration(handle: handle),
                    offeredIntegrations.contains(integration)
                else { return nil }
                return LoopbackMCP.Server(
                    title: integration.title,
                    tools: BuiltInToolCatalog.tools(for: integration).map(\.loopbackTool))
            },
            call: { [weak self] handle, name, arguments in
                guard let self, let tool = BuiltInToolCatalog.tool(handle: handle, name: name) else {
                    return .failure("", "Bestcast is shutting down.")
                }
                return await run(tool, arguments: arguments, callID: "")
            }))
    /// The dialog takes one question at a time, and a CLI or an extension may ask several at once.
    private var consentTail: Task<Void, Never>?

    init(core: AppCore) {
        self.core = core
        runner = BuiltInToolRunner(core: core)
    }

    var enabled: Set<BuiltInIntegration> {
        core.settings.aiEnabled ? core.aiSettings.integrations : []
    }

    /// Switched on and not lost to an MCP server saved under the same name before these existed.
    var offeredIntegrations: [BuiltInIntegration] {
        let enabled = enabled
        let slugs = core.mcpCoordinator.slugs
        return BuiltInIntegration.allCases.filter {
            enabled.contains($0) && !slugs.contains($0.handle)
        }
    }

    var handles: Set<String> { Set(offeredIntegrations.map(\.handle)) }

    var sources: [ChatToolSource] {
        offeredIntegrations.map {
            ChatToolSource(handle: $0.handle, title: $0.title, symbol: $0.symbol, kind: .bestcast)
        }
    }

    func tools(scopedTo scope: Set<String>?, excluded: Set<String>) -> [AITool] {
        BuiltInToolCatalog.offered(
            enabled: enabled, shadowedBy: core.mcpCoordinator.slugs, scope: scope,
            excluded: excluded
        ).map(\.aiTool)
    }

    /// The same list for a CLI route: one loopback server per integration, started on first use.
    func toolServers(scopedTo scope: Set<String>?, excluded: Set<String>) async -> [AIToolServer] {
        let integrations = offeredIntegrations.filter { integration in
            !excluded.contains(integration.handle) && scope?.contains(integration.handle) ?? true
        }
        guard !integrations.isEmpty, let port = await endpoint.start() else { return [] }
        return integrations.map { integration in
            AIToolServer(
                handle: integration.handle, title: integration.title,
                transport: .url(
                    endpoint.url(port: port, handle: integration.handle),
                    headerName: "Authorization", headerValue: "Bearer \(endpoint.token)"))
        }
    }

    /// A CLI asks before every call; a write is asked about at the endpoint, where its text is.
    func permit(_ call: AIToolServerCall) -> Bool {
        handles.contains(call.handle)
            && BuiltInToolCatalog.tool(handle: call.handle, name: call.tool) != nil
    }

    func invoke(_ call: AIToolCall) async -> AIToolResult {
        guard let tool = BuiltInToolCatalog.tool(wireName: call.name) else {
            return .failure(call.id, "Bestcast has no tool called \(call.name).")
        }
        return await run(tool, arguments: call.arguments, callID: call.id)
    }

    /// Nothing left on offer means nothing listening, and a CLI launched with one loses it.
    func applyEnabled() {
        if handles.isEmpty { endpoint.stop() }
        core.mcpCoordinator.dropWithdrawnServers()
    }

    private func run(_ tool: BuiltInTool, arguments: String, callID: String) async -> AIToolResult {
        guard handles.contains(tool.integration.handle) else {
            return .failure(callID, "\(tool.integration.title) is switched off in Bestcast.")
        }
        let verdict = BuiltInToolPolicy.decide(tool, enabled: enabled)
        guard verdict != .refuse else {
            return .failure(callID, "\(tool.integration.title) is switched off in Bestcast.")
        }
        let request: BuiltInToolRequest
        switch BuiltInToolRequest.parse(tool, arguments: arguments, now: Date(), calendar: .current) {
        case .success(let parsed): request = parsed
        case .failure(let failure): return .failure(callID, failure.message)
        }
        do {
            let step = try await runner.prepare(request)
            if verdict == .ask {
                guard let prompt = BuiltInToolPrompt.make(for: request, subject: step.subject),
                    await confirm(
                        title: prompt.title, message: prompt.message,
                        confirmTitle: prompt.confirmTitle, symbol: tool.integration.symbol)
                else { return .failure(callID, "The user declined this tool call.") }
            }
            return AIToolResult(callID: callID, content: try await step.perform(), isError: false)
        } catch let failure as BuiltInToolRequest.Failure {
            return .failure(callID, failure.message)
        } catch {
            return .failure(callID, error.localizedDescription)
        }
    }

    /// Every tool consent queues here, so two sources never race for the one dialog.
    func confirm(
        title: String, message: String, confirmTitle: String, symbol: String,
        isDestructive: Bool = false
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let previous = consentTail
        let asking = Task { [core] in
            await previous?.value
            return await core.confirm(
                title: title, message: message, symbol: symbol, confirmTitle: confirmTitle,
                tone: isDestructive ? .danger : .neutral,
                confirmRole: isDestructive ? .destructive : .standard, dismissTitle: "Don't Allow")
        }
        consentTail = Task { _ = await asking.value }
        return await asking.value
    }
}
