import Foundation

/// `@bestcast/api/compose` for one session, and the awaited `launchCommand` beside it.
@MainActor
final class ExtensionComposeBridge {
    private weak var engine: ExtensionTriggerEngine?
    let scope: ExtensionRunScope

    init(engine: ExtensionTriggerEngine, scope: ExtensionRunScope) {
        self.engine = engine
        self.scope = scope
    }

    func perform(
        method: String, arguments: [RenderValue], caller: String, isBackground: Bool
    ) async throws -> Any? {
        guard let engine else { throw ExtensionHostError.noActiveExtension }
        switch method {
        case "callExport":
            guard let target = arguments.first?.stringValue, let name = arguments[safe: 1]?.stringValue
            else { throw ExtensionHostError.unsupported("callExport without an extension and a name") }
            let input = JSONValue(arguments[safe: 2]?.jsonValue ?? NSNull())
            var scope = scope
            scope.canPrompt = scope.canPrompt && !isBackground
            return try await engine.callExport(
                name, of: target, input: input, caller: caller, scope: scope
            ).get().jsonObject
        case "listExports":
            return engine.listExports(caller: caller).map {
                ["extension": $0.extension, "name": $0.export.name, "description": $0.export.description]
            }
        default:
            throw ExtensionHostError.unknown("bestcastCompose.\(method)")
        }
    }

    /// Awaiting is for the caller's own no-view commands; anything else keeps Raycast's semantics.
    func canAwait(command: String, of caller: String) -> Bool {
        guard let engine, !engine.store.isPaused,
            let owner = engine.manager?.extensionNamed(caller)
        else { return false }
        return owner.command(named: command)?.mode == .noView
    }

    func runCommand(
        _ name: String, of caller: String, arguments: [String: String],
        launchType: ExtensionLaunchType, launchContext: [String: RenderValue]
    ) async throws -> Any {
        guard let engine, let manager = engine.manager, let owner = manager.extensionNamed(caller),
            let command = owner.command(named: name)
        else { throw ExtensionLaunchError.unknownCommand(name) }
        let key = ExtensionTriggerPolicy.callKey(extension: caller, export: "command:" + name)
        if let refusal = ExtensionTriggerEngine.refusal(chain: scope.chain, next: key) { throw refusal }
        let props = JSONValue.object([
            "launchType": .string(launchType.rawValue),
            "arguments": .object(arguments.mapValues(JSONValue.string)),
            "launchContext": .object(launchContext.mapValues { JSONValue($0.jsonValue) })
        ])
        var scope = scope
        scope.chain.append(key)
        return try await engine.runner.runCommand(command, of: owner, props: props, scope: scope)
            .get().jsonObject
    }
}
