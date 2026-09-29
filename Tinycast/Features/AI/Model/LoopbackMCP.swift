import Foundation

/// The HTTP and JSON-RPC halves of the MCP endpoint a CLI route reaches Tinycast's own tools on.
enum LoopbackMCP {
    /// A write carries at most 64 KB; escaping can double it, and nothing else comes close.
    static let maxRequestBytes = 256 * 1024
    /// The API loop's per-result cap, so a CLI route's context fills no faster than that one.
    static let maxResultBytes = 32_768
    static let pathPrefix = "/mcp/"
    static let serverName = "tinycast"
    static let version = "2025-06-18"
    static let supportedVersions: Set<String> = [version, "2025-03-26", "2024-11-05"]

    /// One server a handle names: an integration, or an extension's tools.
    struct Server: Equatable, Sendable {
        let title: String
        let tools: [Tool]
    }

    /// A tool under its name inside the server; a CLI prefixes the server's own.
    struct Tool: Equatable, Sendable {
        let name: String
        let title: String
        let description: String
        let inputSchema: JSONValue
        let isReadOnly: Bool
    }

    struct Request: Equatable, Sendable {
        let method: String
        let path: String
        /// Lowercased names; a header sent twice keeps its last value.
        let headers: [String: String]
        let body: Data
    }

    enum Parsed: Equatable, Sendable {
        case incomplete
        case invalid
        case tooLarge
        case request(Request)
    }

    static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxRequestBytes ? .tooLarge : .incomplete
        }
        guard let head = String(bytes: data[..<end.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .invalid }
        let length = headers["content-length"].map { Int($0) } ?? 0
        guard let length, length >= 0 else { return .invalid }
        guard length <= maxRequestBytes else { return .tooLarge }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .request(
            Request(
                method: String(start[0]), path: String(start[1]), headers: headers,
                body: Data(body.prefix(length))))
    }

    /// The integration a path names, `/mcp/<handle>`; a query string is ignored.
    static func handle(inPath path: String) -> String? {
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard bare.hasPrefix(pathPrefix) else { return nil }
        let handle = String(bare.dropFirst(pathPrefix.count))
        return handle.isEmpty || handle.contains("/") ? nil : handle
    }

    /// Compared in full every time, so how long a refusal takes says nothing about the token.
    static func isAuthorized(_ request: Request, token: String) -> Bool {
        let expected = Array("Bearer \(token)".utf8)
        let given = Array((request.headers["authorization"] ?? "").utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// What one POST body asks for, with the id its answer must carry.
    enum Call: Equatable, Sendable {
        case initialize(id: JSONValue, version: String?)
        case notification
        case listTools(id: JSONValue)
        case callTool(id: JSONValue, name: String, arguments: String)
        case ping(id: JSONValue)
        case unknown(id: JSONValue, method: String)
        case invalid
    }

    static func call(from body: Data) -> Call {
        guard let object = JSONValue(data: body)?.objectValue,
            let method = object["method"]?.stringValue
        else { return .invalid }
        guard let id = object["id"], id != .null else { return .notification }
        let params = object["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            return .initialize(id: id, version: params["protocolVersion"]?.stringValue)
        case "tools/list":
            return .listTools(id: id)
        case "tools/call":
            guard let name = params["name"]?.stringValue else { return .invalid }
            let arguments = params["arguments"].map(text) ?? "{}"
            return .callTool(id: id, name: name, arguments: arguments)
        case "ping":
            return .ping(id: id)
        default:
            return .unknown(id: id, method: method)
        }
    }

    static func initializeResult(version requested: String?, title: String) -> JSONValue {
        let agreed = requested.flatMap { supportedVersions.contains($0) ? $0 : nil }
        return .object([
            "protocolVersion": .string(agreed ?? version),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string(serverName), "title": .string(title)])
        ])
    }

    static func toolList(_ tools: [Tool]) -> JSONValue {
        .object([
            "tools": .array(
                tools.map { tool in
                    .object([
                        "name": .string(tool.name), "title": .string(tool.title),
                        "description": .string(tool.description),
                        "inputSchema": tool.inputSchema,
                        "annotations": .object(["readOnlyHint": .bool(tool.isReadOnly)])
                    ])
                })
        ])
    }

    static func toolResult(_ result: AIToolResult) -> JSONValue {
        .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(clipped(result.content))])
            ]),
            "isError": .bool(result.isError)
        ])
    }

    static func clipped(_ content: String) -> String {
        let utf8 = content.utf8
        guard utf8.count > maxResultBytes else { return content }
        // A cut can land mid-scalar; `String(decoding:)` turns the remainder into a replacement.
        return String(decoding: Array(utf8.prefix(maxResultBytes)), as: UTF8.self) + "\n…truncated."
    }

    static func response(id: JSONValue, result: JSONValue) -> Data {
        Data(text(.object(["jsonrpc": .string("2.0"), "id": id, "result": result])).utf8)
    }

    static func error(id: JSONValue?, code: Int, message: String) -> Data {
        Data(
            text(
                .object([
                    "jsonrpc": .string("2.0"), "id": id ?? .null,
                    "error": .object(["code": .number(Double(code)), "message": .string(message)])
                ])
            ).utf8)
    }

    static func http(status: String, body: Data? = nil) -> Data {
        var head = "HTTP/1.1 \(status)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n\r\n"
        return Data(head.utf8) + (body ?? Data())
    }

    /// Compact and key-sorted, so a model reads the same result the same way every time.
    static func text(_ value: JSONValue) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value.jsonObject,
                options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
            let text = String(bytes: data, encoding: .utf8)
        else { return "null" }
        return text
    }
}
