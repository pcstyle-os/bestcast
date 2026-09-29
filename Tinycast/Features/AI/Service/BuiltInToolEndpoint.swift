import Foundation
import Network

/// The loopback MCP server a CLI route's own client reaches Tinycast's tools through.
@MainActor
final class BuiltInToolEndpoint {
    /// What the endpoint serves; `tools` is `nil` for a handle that is not on offer right now.
    struct Service {
        let tools: @MainActor (_ handle: String) -> [BuiltInTool]?
        let call: @MainActor (_ tool: BuiltInTool, _ arguments: String) async -> AIToolResult
    }

    /// A request that has not arrived whole by then never will; a tool's own run is not bounded.
    private static let readTimeout: Duration = .seconds(30)

    /// Fresh each launch and only ever handed to a child process, so no other app can call in.
    let token: String
    private let service: Service
    private var task: Task<Void, Never>?
    private var port: UInt16?
    private var starting: [CheckedContinuation<UInt16?, Never>] = []

    init(service: Service) {
        self.service = service
        var generator = SystemRandomNumberGenerator()
        token = (0..<32).map { _ in String(format: "%02x", generator.next() as UInt8) }.joined()
    }

    isolated deinit { task?.cancel() }

    /// The port it listens on, starting it first if need be; `nil` when it cannot listen.
    func start() async -> UInt16? {
        if let port { return port }
        return await withCheckedContinuation { continuation in
            starting.append(continuation)
            guard task == nil else { return }
            launch()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        settle(nil)
    }

    func url(port: UInt16, handle: String) -> String {
        "http://127.0.0.1:\(port)\(LoopbackMCP.pathPrefix)\(handle)"
    }

    private func launch() {
        let listener: NetworkListener<TCP>
        do {
            listener = try NetworkListener(
                using: .parameters { TCP() }
                    .localEndpoint(.hostPort(host: .ipv4(.loopback), port: .any)))
        } catch {
            settle(nil)
            return
        }
        task = Task { [weak self] in
            try? await listener.onStateUpdate { [weak self] listener, state in
                switch state {
                case .ready: self?.settle(listener.port?.rawValue)
                case .waiting, .failed: self?.stop()
                default: break
                }
            }.run { [weak self] connection in
                await self?.serve(connection)
            }
            // A stop already cleaned up, and a newer listener may be starting in its place.
            if !Task.isCancelled { self?.ended() }
        }
    }

    private func settle(_ port: UInt16?) {
        self.port = port
        let waiting = starting
        starting = []
        for continuation in waiting { continuation.resume(returning: port) }
    }

    private func ended() {
        task = nil
        settle(nil)
    }

    private func serve(_ connection: NetworkConnection<TCP>) async {
        guard let reply = await respond(to: Self.read(connection)) else { return }
        try? await connection.send(reply, endOfStream: true)
    }

    nonisolated private static func read(
        _ connection: NetworkConnection<TCP>
    ) async -> LoopbackMCP.Parsed {
        await withTaskGroup(of: LoopbackMCP.Parsed.self) { group in
            group.addTask {
                var bytes = Data()
                while true {
                    guard let message = try? await connection.receive(atLeast: 1, atMost: 64 * 1024)
                    else { return .incomplete }
                    bytes.append(message.content)
                    let parsed = LoopbackMCP.parse(bytes)
                    guard parsed == .incomplete, !message.metadata.endOfStream else { return parsed }
                }
            }
            group.addTask {
                try? await Task.sleep(for: readTimeout)
                return .incomplete
            }
            defer { group.cancelAll() }
            return await group.next() ?? .incomplete
        }
    }

    private func respond(to parsed: LoopbackMCP.Parsed) async -> Data? {
        let request: LoopbackMCP.Request
        switch parsed {
        case .incomplete: return nil
        case .invalid: return LoopbackMCP.http(status: "400 Bad Request")
        case .tooLarge: return LoopbackMCP.http(status: "413 Content Too Large")
        case .request(let whole): request = whole
        }
        guard LoopbackMCP.isAuthorized(request, token: token) else {
            return LoopbackMCP.http(status: "401 Unauthorized")
        }
        guard let handle = LoopbackMCP.handle(inPath: request.path),
            let integration = BuiltInIntegration(handle: handle), let tools = service.tools(handle)
        else { return LoopbackMCP.http(status: "404 Not Found") }
        // No event stream to offer: a GET is how a client asks for one, and 405 is how it hears no.
        guard request.method == "POST" else { return LoopbackMCP.http(status: "405 Method Not Allowed") }
        let body: Data
        switch LoopbackMCP.call(from: request.body) {
        case .invalid:
            return LoopbackMCP.http(
                status: "400 Bad Request",
                body: LoopbackMCP.error(id: nil, code: -32700, message: "Parse error"))
        case .notification:
            return LoopbackMCP.http(status: "202 Accepted")
        case .initialize(let id, let version):
            body = LoopbackMCP.response(
                id: id,
                result: LoopbackMCP.initializeResult(version: version, title: integration.title))
        case .listTools(let id):
            body = LoopbackMCP.response(id: id, result: LoopbackMCP.toolList(tools))
        case .ping(let id):
            body = LoopbackMCP.response(id: id, result: .object([:]))
        case .callTool(let id, let name, let arguments):
            guard let tool = tools.first(where: { $0.name == name }) else {
                body = LoopbackMCP.error(id: id, code: -32602, message: "Unknown tool: \(name)")
                break
            }
            let result = await service.call(tool, arguments)
            body = LoopbackMCP.response(id: id, result: LoopbackMCP.toolResult(result))
        case .unknown(let id, let method):
            body = LoopbackMCP.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
        return LoopbackMCP.http(status: "200 OK", body: body)
    }
}
