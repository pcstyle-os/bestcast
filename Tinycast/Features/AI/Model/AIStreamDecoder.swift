import Foundation

struct SSEParser: Sendable {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var payloads: [String] = []
        while let boundary = nextBoundary() {
            let frame = buffer[..<boundary.lowerBound]
            buffer.removeSubrange(buffer.startIndex..<boundary.upperBound)
            if let payload = Self.payload(in: frame) { payloads.append(payload) }
        }
        return payloads
    }

    mutating func finish() -> [String] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll() }
        return Self.payload(in: buffer).map { [$0] } ?? []
    }

    private func nextBoundary() -> Range<Data.Index>? {
        let lf = buffer.range(of: Data([0x0A, 0x0A]))
        let crlf = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        switch (lf, crlf) {
        case (let lhs?, let rhs?): return lhs.lowerBound < rhs.lowerBound ? lhs : rhs
        case (let range?, nil), (nil, let range?): return range
        case (nil, nil): return nil
        }
    }

    private static func payload(in frame: some DataProtocol) -> String? {
        let text = String(decoding: frame, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var dataLines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(":") { continue }
            if line == "data" {
                dataLines.append("")
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.first == " " { value = value.dropFirst() }
                dataLines.append(String(value))
            }
        }
        return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
    }
}

struct AIStreamDecoder: Sendable {
    /// A call arrives in fragments keyed by index, with its id and name only on the first one.
    private struct PartialToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private let shape: AIHTTPConfiguration.APIShape
    private var parser = SSEParser()
    private var usage = AIUsage()
    private var partialToolCalls: [Int: PartialToolCall] = [:]
    /// Anthropic's own searches by block index, each gathering its query as the JSON streams in.
    private var searchQueries: [Int: (id: String, query: String)] = [:]
    /// Searches shown as running whose result block has not arrived yet.
    private var openSearches: [String] = []
    private var citations = AnthropicCitations()
    private(set) var isTerminal = false
    private(set) var stopReason: String?
    private var rawBlocks: [Int: JSONValue] = [:]
    private var rawInputs: [Int: String] = [:]
    private var continuationCount = 0

    mutating func resumePausedTurn() throws -> [JSONValue]? {
        guard isTerminal, stopReason == "pause_turn" else { return nil }
        guard continuationCount < 3 else {
            throw AIProviderError.responseFailed("The provider paused too many times. Try again.")
        }
        guard !rawBlocks.isEmpty else { throw AIProviderError.malformedResponse }
        let blocks = rawBlocks.sorted { $0.key < $1.key }.map(\.value)
        continuationCount += 1
        rawBlocks.removeAll()
        rawInputs.removeAll()
        parser = SSEParser()
        usage = AIUsage()
        stopReason = nil
        isTerminal = false
        return blocks
    }

    init(shape: AIHTTPConfiguration.APIShape) {
        self.shape = shape
    }

    /// Assembled in index order, so a turn's calls reach the loop as the model listed them.
    private mutating func flushToolCalls() -> [AIStreamEvent] {
        guard !partialToolCalls.isEmpty else { return [] }
        let calls = partialToolCalls.sorted { $0.key < $1.key }.map(\.value)
        partialToolCalls.removeAll()
        return calls.compactMap { call in
            guard !call.name.isEmpty else { return nil }
            return .toolCallRequested(
                AIToolCall(id: call.id, name: call.name, arguments: call.arguments))
        }
    }

    mutating func feed(_ data: Data) throws -> [AIStreamEvent] {
        try decode(parser.feed(data))
    }

    mutating func finish() throws -> [AIStreamEvent] {
        try decode(parser.finish())
    }

    private mutating func decode(_ payloads: [String]) throws -> [AIStreamEvent] {
        var events: [AIStreamEvent] = []
        for payload in payloads where !isTerminal {
            if payload == "[DONE]" {
                isTerminal = true
                events.append(contentsOf: flushToolCalls())
                events.append(.finished)
                continue
            }
            switch shape {
            case .openAICompatible:
                events.append(contentsOf: try decodeOpenAI(payload))
            case .anthropic:
                events.append(contentsOf: try decodeAnthropic(payload))
            }
        }
        return events
    }

    private mutating func decodeOpenAI(_ payload: String) throws -> [AIStreamEvent] {
        guard let data = payload.data(using: .utf8),
            let chunk = try? JSONDecoder().decode(OpenAIChunk.self, from: data)
        else {
            isTerminal = true
            throw AIProviderError.malformedResponse
        }

        // OpenRouter reports a mid-stream failure as a 200 payload, so it's an event, not a status.
        if let message = chunk.error?.message {
            isTerminal = true
            throw AIProviderError.responseFailed(message)
        }
        var events: [AIStreamEvent] = []
        if let choice = chunk.choices?.first {
            if let content = choice.delta?.content, !content.isEmpty {
                events.append(.text(content))
            } else if let reasoning = choice.delta?.reasoningText {
                events += [.thinking, .reasoning(reasoning)]
            }
            for fragment in choice.delta?.toolCalls ?? [] { absorb(fragment) }
            if choice.finishReason == "tool_calls" { events.append(contentsOf: flushToolCalls()) }
        }
        if let reported = chunk.usage {
            usage.inputTokens = reported.promptTokens ?? usage.inputTokens
            usage.outputTokens = reported.completionTokens ?? usage.outputTokens
            usage.reasoningTokens =
                reported.completionTokensDetails?.reasoningTokens ?? usage.reasoningTokens
            usage.costUSD = reported.cost ?? usage.costUSD
            events.append(.usage(usage))
        }
        return events
    }

    /// A fragment's index is the only stable handle; a gateway may omit it when there is one call.
    private mutating func absorb(_ fragment: OpenAIChunk.Choice.Delta.ToolCall) {
        var partial = partialToolCalls[fragment.index ?? 0] ?? PartialToolCall()
        if let id = fragment.id, !id.isEmpty { partial.id = id }
        if let name = fragment.function?.name, !name.isEmpty { partial.name = name }
        partial.arguments += fragment.function?.arguments ?? ""
        partialToolCalls[fragment.index ?? 0] = partial
    }

    private mutating func decodeAnthropic(_ payload: String) throws -> [AIStreamEvent] {
        guard let data = payload.data(using: .utf8),
            let event = try? JSONDecoder().decode(AnthropicEvent.self, from: data)
        else {
            isTerminal = true
            throw AIProviderError.malformedResponse
        }

        let index = event.index ?? 0
        try retainAnthropicBlock(data, event: event, index: index)
        switch event.type {
        case "content_block_start":
            switch event.contentBlock?.type {
            case "tool_use":
                partialToolCalls[index] = PartialToolCall(
                    id: event.contentBlock?.id ?? "", name: event.contentBlock?.name ?? "",
                    arguments: "")
            case "server_tool_use" where event.contentBlock?.name == "web_search":
                searchQueries[index] = (event.contentBlock?.id ?? "", "")
            case "web_search_tool_result":
                let id = event.contentBlock?.toolUseID
                openSearches.removeAll { $0 == id }
                return [.searched(nil, id: id, failed: event.contentBlock?.isSearchError == true)]
            default:
                break
            }
            return []
        case "content_block_delta":
            if event.delta?.type == "text_delta", let text = event.delta?.text, !text.isEmpty {
                let shown = citations.release(text, in: index)
                return shown.isEmpty ? [] : [.text(shown)]
            }
            if event.delta?.type == "input_json_delta" {
                let fragment = event.delta?.partialJSON ?? ""
                partialToolCalls[index]?.arguments += fragment
                searchQueries[index]?.query += fragment
                return []
            }
            if event.delta?.type == "citations_delta", let citation = event.delta?.citation {
                citations.cite(url: citation.url, title: citation.title, in: index)
                return []
            }
            guard event.delta?.type == "thinking_delta" else { return [] }
            guard let thinking = event.delta?.thinking, !thinking.isEmpty else { return [.thinking] }
            return [.thinking, .reasoning(thinking)]
        case "content_block_stop":
            // The query is whole once its block closes; the search itself runs after that.
            if let search = searchQueries.removeValue(forKey: index) {
                openSearches.append(search.id)
                return [.searching(Self.searchQuery(search.query), id: search.id)]
            }
            return citations.close(index).map { [.text($0)] } ?? []
        case "message_start":
            let reported = event.message?.usage
            usage.inputTokens = reported?.inputTokens ?? usage.inputTokens
            let cached = [reported?.cacheReadInputTokens, reported?.cacheCreationInputTokens]
                .compactMap { $0 }
            if !cached.isEmpty { usage.cachedInputTokens = cached.reduce(0, +) }
            return [.usage(usage)]
        case "message_delta":
            usage.outputTokens = event.usage?.outputTokens ?? usage.outputTokens
            stopReason = event.delta?.stopReason ?? stopReason
            guard stopReason != "pause_turn" else { return [.usage(usage)] }
            let unrun = openSearches.map { AIStreamEvent.searched(nil, id: $0, failed: true) }
            openSearches.removeAll()
            // The calls are complete here, and `message_stop` may never arrive on a tool turn.
            guard event.delta?.stopReason == "tool_use" else { return [.usage(usage)] + unrun }
            return [.usage(usage)] + unrun + flushToolCalls()
        case "message_stop":
            isTerminal = true
            return stopReason == "pause_turn" ? [] : flushToolCalls() + [.finished]
        case "error":
            isTerminal = true
            throw AIProviderError.responseFailed(Self.anthropicErrorMessage(event.error?.type))
        default:
            return []
        }
    }

    private mutating func retainAnthropicBlock(
        _ data: Data, event: AnthropicEvent, index: Int
    ) throws {
        let raw = JSONValue(data: data)?.objectValue
        switch event.type {
        case "content_block_start":
            rawBlocks[index] = raw?["content_block"]
        case "content_block_delta":
            guard var block = rawBlocks[index]?.objectValue,
                let delta = raw?["delta"]?.objectValue
            else { return }
            switch event.delta?.type {
            case "text_delta", "thinking_delta", "signature_delta":
                let key = String((event.delta?.type ?? "").dropLast(6))
                block[key] = .string(
                    (block[key]?.stringValue ?? "") + (delta[key]?.stringValue ?? ""))
            case "input_json_delta":
                rawInputs[index, default: ""] += event.delta?.partialJSON ?? ""
            case "citations_delta":
                if let citation = delta["citation"] {
                    block["citations"] = .array((block["citations"]?.arrayValue ?? []) + [citation])
                }
            default:
                break
            }
            rawBlocks[index] = .object(block)
        case "content_block_stop":
            if let input = rawInputs.removeValue(forKey: index) {
                guard let value = JSONValue(data: Data(input.utf8)),
                    var block = rawBlocks[index]?.objectValue
                else { throw AIProviderError.malformedResponse }
                block["input"] = value
                rawBlocks[index] = .object(block)
            }
        default:
            break
        }
    }

    private static func searchQuery(_ json: String) -> String? {
        let query = JSONValue(data: Data(json.utf8))?.objectValue?["query"]?.stringValue
        return query?.isEmpty == false ? query : nil
    }

    private static func anthropicErrorMessage(_ type: String?) -> String {
        switch type {
        case "authentication_error": return "API key rejected — check it in Settings."
        case "rate_limit_error": return "Rate limit reached — try again later."
        default: return "The provider stopped the response with an error."
        }
    }
}

private struct OpenAIChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ReasoningDetail: Decodable { let text: String? }

            struct ToolCall: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }

                let index: Int?
                let id: String?
                let function: Function?
            }

            let content: String?
            let reasoning: String?
            let reasoningContent: String?
            let reasoningDetails: [ReasoningDetail]?
            let toolCalls: [ToolCall]?

            /// OpenRouter says `reasoning`, DeepSeek and its copies `reasoning_content`.
            var reasoningText: String? {
                let text =
                    [reasoning, reasoningContent].compactMap { $0 }.first { !$0.isEmpty }
                    ?? reasoningDetails?.compactMap(\.text).joined()
                return text?.isEmpty == false ? text : nil
            }

            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
                case reasoningDetails = "reasoning_details"
                case toolCalls = "tool_calls"
            }
        }

        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        struct CompletionDetails: Decodable {
            let reasoningTokens: Int?

            enum CodingKeys: String, CodingKey {
                case reasoningTokens = "reasoning_tokens"
            }
        }

        let promptTokens: Int?
        let completionTokens: Int?
        let completionTokensDetails: CompletionDetails?
        /// OpenRouter's own figure; a vendor API sends none.
        let cost: Double?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case completionTokensDetails = "completion_tokens_details"
            case cost
        }
    }

    struct ErrorBody: Decodable { let message: String? }

    let choices: [Choice]?
    let usage: Usage?
    let error: ErrorBody?
}

/// A text block's web citations, closed into the Markdown links `ChatReferences` lists as sources.
private struct AnthropicCitations {
    private static let heldBack = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".,;:!?"))

    private var index: Int?
    private var sources: [(url: String, title: String)] = []
    /// A cited block's closing punctuation, so its link lands before the full stop, not after it.
    private var held = ""

    mutating func cite(url: String?, title: String?, in index: Int) {
        guard let source = Self.source(url: url, title: title) else { return }
        if self.index != index {
            self = AnthropicCitations()
            self.index = index
        }
        guard !sources.contains(where: { $0.url == source.url }) else { return }
        sources.append(source)
    }

    /// What of `text` may be shown now; an uncited block passes straight through.
    mutating func release(_ text: String, in index: Int) -> String {
        guard self.index == index, !sources.isEmpty else { return text }
        let scalars = (held + text).unicodeScalars
        let tail = scalars.reversed().prefix { Self.heldBack.contains($0) }.count
        let split = scalars.index(scalars.endIndex, offsetBy: -tail)
        held = String(scalars[split...])
        return String(scalars[..<split])
    }

    mutating func close(_ index: Int) -> String? {
        guard self.index == index else { return nil }
        defer { self = AnthropicCitations() }
        guard !sources.isEmpty else { return nil }
        let links = sources.map { "[\($0.title)](\($0.url))" }.joined(separator: ", ")
        return " (" + links + ")" + held
    }

    /// What inline Markdown acts on inside link text; `|` would split a table cell around it.
    private static let markdownActive: Set<Character> = [
        "\\", "`", "*", "_", "[", "]", "<", ">", "&", "~", "|"
    ]

    /// A title escaped so it cannot end its own link, and a URL that cannot close its parenthesis.
    private static func source(url: String?, title: String?) -> (url: String, title: String)? {
        guard let url, !url.contains(where: \.isWhitespace), let parsed = URL(string: url),
            let host = parsed.host(), ["http", "https"].contains(parsed.scheme?.lowercased())
        else { return nil }
        let safeURL = url.replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        let name = (title ?? "").replacing(#/\s*[\n\r]+\s*/#, with: " ")
            .trimmingCharacters(in: .whitespaces)
        let label = (name.isEmpty ? host : name).reduce(into: "") { label, character in
            if markdownActive.contains(character) { label.append("\\") }
            label.append(character)
        }
        return (safeURL, label)
    }
}

private struct AnthropicEvent: Decodable {
    struct Delta: Decodable {
        struct Citation: Decodable {
            let url: String?
            let title: String?
        }

        let type: String?
        let text: String?
        let thinking: String?
        let partialJSON: String?
        let stopReason: String?
        let citation: Citation?

        enum CodingKeys: String, CodingKey {
            case type, text, thinking, citation
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    struct ContentBlock: Decodable {
        struct ResultError: Decodable { let type: String? }

        let type: String?
        let id: String?
        let name: String?
        let toolUseID: String?
        /// A search result's `content` is a list of pages, or one error object when it failed.
        let resultError: ResultError?

        var isSearchError: Bool { resultError?.type == "web_search_tool_result_error" }

        enum CodingKeys: String, CodingKey {
            case type, id, name, content
            case toolUseID = "tool_use_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            toolUseID = try container.decodeIfPresent(String.self, forKey: .toolUseID)
            resultError = try? container.decodeIfPresent(ResultError.self, forKey: .content)
        }
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }

    struct Message: Decodable { let usage: Usage? }
    struct ErrorBody: Decodable { let type: String? }

    let type: String
    let index: Int?
    let delta: Delta?
    let contentBlock: ContentBlock?
    let usage: Usage?
    let message: Message?
    let error: ErrorBody?

    enum CodingKeys: String, CodingKey {
        case type, index, delta, usage, message, error
        case contentBlock = "content_block"
    }
}
