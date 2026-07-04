// ChatCompletionsLanguageModel — a LanguageModel that talks to any
// OpenAI-compatible /chat/completions endpoint (Ollama, vLLM, llama-server,
// LM Studio, OpenRouter, ...). Modeled on Apple's implementation in
// apple/foundation-models-utilities (Apache 2.0).

import Foundation
import Logging
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ChatCompletionsLanguageModel: Sendable, LanguageModel {
    /// The model identifier sent in the `model` field of each request.
    public var name: String

    /// The base URL of the endpoint. `v1/chat/completions` is appended when
    /// the URL does not already include a `v1` path segment.
    public var url: URL

    /// Headers merged on top of the defaults (e.g. an `Authorization` header).
    public var additionalHeaders: [String: String]

    /// Whether the endpoint supports `response_format` for structured output.
    public var supportsGuidedGeneration: Bool

    /// Provider-executed server tools (e.g. `openrouter:web_search`) injected
    /// verbatim into each request's `tools` array.
    public var serverTools: [ChatCompletionsServerTool]

    /// When false, requests are sent non-streaming (a single JSON response).
    /// Some providers are more reliable non-streaming for structured output
    /// combined with server tools.
    public var stream: Bool

    /// Per-request timeout, in seconds.
    public var timeout: TimeInterval

    /// Transport diagnostics via swift-log: request lifecycle at `.debug`,
    /// HTTP errors at `.warning`, skipped SSE frames at `.debug`. Prompt,
    /// instruction, and response CONTENT is never logged at any level.
    /// Silent (no-op handler) unless you assign your own logger.
    public var logger = Logger(label: "ServerFoundationModels", factory: { _ in SwiftLogNoOpLogHandler() })

    public init(
        name: String,
        url: URL,
        additionalHeaders: [String: String] = [:],
        supportsGuidedGeneration: Bool = true,
        serverTools: [ChatCompletionsServerTool] = [],
        stream: Bool = true,
        timeout: TimeInterval = 600
    ) {
        self.name = name
        self.url = url
        self.additionalHeaders = additionalHeaders
        self.supportsGuidedGeneration = supportsGuidedGeneration
        self.serverTools = serverTools
        self.stream = stream
        self.timeout = timeout
    }

    public var capabilities: LanguageModelCapabilities {
        if supportsGuidedGeneration {
            return LanguageModelCapabilities(capabilities: [.vision, .toolCalling, .reasoning, .guidedGeneration])
        }
        return LanguageModelCapabilities(capabilities: [.vision, .toolCalling, .reasoning])
    }

    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(
            modelName: name,
            url: url,
            additionalHeaders: additionalHeaders,
            supportsGuidedGeneration: supportsGuidedGeneration,
            serverTools: serverTools,
            stream: stream,
            timeout: timeout
        )
    }

    // MARK: Executor

    public struct Executor: LanguageModelExecutor {
        public struct Configuration: Hashable, Sendable {
            var modelName: String
            var url: URL
            var additionalHeaders: [String: String]
            var supportsGuidedGeneration: Bool
            var serverTools: [ChatCompletionsServerTool] = []
            var stream: Bool = true
            var timeout: TimeInterval = 600
        }

        let configuration: Configuration

        public init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ChatCompletionsLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let logger = model.logger
            let urlRequest = try makeURLRequest(for: request)
            Self.warnIfPlainHTTPAuthorization(
                endpoint: endpoint, headers: configuration.additionalHeaders, logger: logger
            )
            logger.debug("chat.completions request", metadata: [
                "model": .string(configuration.modelName),
                "host": .string(urlRequest.url?.host ?? "?"),
                "tools": .stringConvertible(request.enabledToolDefinitions.count),
                "guided": .stringConvertible(request.schema != nil),
            ])
            let (lines, response) = try await HTTPLineStream.connect(urlRequest)

            if !(200..<300).contains(response.statusCode) {
                var bodyLines: [String] = []
                var bodyByteCount = 0
                for try await line in lines {
                    bodyLines.append(line)
                    bodyByteCount += line.utf8.count
                    if bodyLines.count > 1 { bodyByteCount += 1 }
                    if bodyByteCount > 4096 { break }
                }
                let body = bodyLines.joined(separator: "\n")
                logger.warning("chat.completions error response", metadata: [
                    "status": .stringConvertible(response.statusCode),
                    "body": .string(String(body.prefix(256))),
                ])
                if response.statusCode == 429 {
                    let resetDate = response.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { HTTPErrorHeuristics.retryAfterDate(fromHeaderValue: $0) }
                    throw LanguageModelError.rateLimited(.init(resetDate: resetDate, debugDescription: body))
                }
                if HTTPErrorHeuristics.isContextOverflow(statusCode: response.statusCode, body: body) {
                    throw LanguageModelError.contextSizeExceeded(.init(
                        contextSize: 0, tokenCount: 0, debugDescription: body
                    ))
                }
                throw LanguageModelTransportError(statusCode: response.statusCode, message: body)
            }

            // Non-streaming: read the whole JSON body and emit once.
            if !configuration.stream {
                try await respondNonStreaming(lines: lines, channel: channel, logger: logger)
                return
            }

            // Accumulates streamed tool-call fragments by choice index.
            var toolCalls = ToolCallAccumulator()
            // Accumulates url_citation annotations (e.g. from server web search).
            var citations: [WebCitationSegment.Citation] = []
            // SSE event assembly: consecutive `data:` lines belong to one
            // event and are joined with "\n"; a blank line dispatches it.
            var pendingData: [String] = []
            var isFirstLine = true

            for try await rawLine in lines {
                var line = Substring(rawLine)
                if isFirstLine {
                    isFirstLine = false
                    // A single leading U+FEFF BOM at stream start is ignored.
                    if line.first == "\u{FEFF}" { line.removeFirst() }
                }
                if line.isEmpty {
                    guard !pendingData.isEmpty else { continue }
                    let payload = pendingData.joined(separator: "\n")
                    pendingData.removeAll()
                    if try await processEvent(payload, toolCalls: &toolCalls, citations: &citations, channel: channel, logger: logger) {
                        break
                    }
                    continue
                }
                guard line.hasPrefix("data:") else { continue }
                var value = line.dropFirst(5)
                if value.first == " " { value.removeFirst() }
                pendingData.append(String(value))
            }
            // A final event the stream closed without terminating: process it
            // anyway so providers that omit the trailing blank line still work.
            if !pendingData.isEmpty {
                let payload = pendingData.joined(separator: "\n")
                _ = try await processEvent(payload, toolCalls: &toolCalls, citations: &citations, channel: channel, logger: logger)
            }

            for index in toolCalls.calls.keys.sorted() {
                let call = toolCalls.calls[index]!
                await channel.send(.toolCalls(action: .toolCall(
                    id: call.id.isEmpty ? UUID().uuidString : call.id,
                    name: call.name,
                    action: .appendArguments(call.arguments, tokenCount: 0)
                )))
            }

            // Surface any web-search citations as a custom transcript segment.
            if !citations.isEmpty {
                var seen = Set<String>()
                let unique = citations.filter { seen.insert($0.url.absoluteString).inserted }
                await channel.send(.response(action: .updateCustomSegment(
                    WebCitationSegment(id: UUID().uuidString, citations: unique)
                )))
            }
        }

        /// Reads a complete (non-streamed) chat-completions JSON body and emits
        /// its content, reasoning, tool calls, usage, and citations at once.
        private func respondNonStreaming(
            lines: AsyncThrowingStream<String, any Error>,
            channel: LanguageModelExecutorGenerationChannel,
            logger: Logger
        ) async throws {
            var body = ""
            for try await line in lines { body += line + "\n" }
            guard let chunk = try? JSONNode.parse(body) else {
                throw LanguageModelTransportError(
                    statusCode: 200,
                    message: "unparseable non-streaming response: \(String(body.prefix(256)))"
                )
            }

            let message = chunk["choices"]?[0]?["message"]
            if case .string(let content)? = message?["content"], !content.isEmpty {
                await channel.send(.response(action: .appendText(content, tokenCount: 0)))
            }
            for reasoningKey in ["reasoning", "reasoning_content"] {
                if case .string(let reasoning)? = message?[reasoningKey], !reasoning.isEmpty {
                    await channel.send(.reasoning(action: .appendText(reasoning, tokenCount: 0)))
                }
            }
            if let usage = chunk["usage"], case .object = usage {
                func intValue(_ node: JSONNode?) -> Int {
                    if case .integer(let value) = node { return value }
                    if case .number(let value) = node, let exact = Int(exactly: value) { return exact }
                    return 0
                }
                await channel.send(.response(action: .updateUsage(
                    input: .init(
                        totalTokenCount: intValue(usage["prompt_tokens"]),
                        cachedTokenCount: intValue(usage["prompt_tokens_details"]?["cached_tokens"])
                    ),
                    output: .init(
                        totalTokenCount: intValue(usage["completion_tokens"]),
                        reasoningTokenCount: intValue(usage["completion_tokens_details"]?["reasoning_tokens"])
                    )
                )))
            }
            if case .array(let calls)? = message?["tool_calls"] {
                var accumulator = ToolCallAccumulator()
                accumulator.ingest(calls)
                for index in accumulator.calls.keys.sorted() {
                    let call = accumulator.calls[index]!
                    await channel.send(.toolCalls(action: .toolCall(
                        id: call.id.isEmpty ? UUID().uuidString : call.id,
                        name: call.name,
                        action: .appendArguments(call.arguments, tokenCount: 0)
                    )))
                }
            }
            var citations: [WebCitationSegment.Citation] = []
            Self.collectCitations(from: message?["annotations"], into: &citations)
            if !citations.isEmpty {
                var seen = Set<String>()
                let unique = citations.filter { seen.insert($0.url.absoluteString).inserted }
                await channel.send(.response(action: .updateCustomSegment(
                    WebCitationSegment(id: UUID().uuidString, citations: unique)
                )))
            }
            if case .string(let finishReason)? = chunk["choices"]?[0]?["finish_reason"],
                finishReason == "content_filter" {
                throw LanguageModelError.guardrailViolation(.init(
                    debugDescription: "provider stopped generation with finish_reason=content_filter"
                ))
            }
        }

        /// Handles one assembled SSE event payload. Returns `true` when the
        /// stream is finished (`[DONE]`).
        private func processEvent(
            _ payload: String,
            toolCalls: inout ToolCallAccumulator,
            citations: inout [WebCitationSegment.Citation],
            channel: LanguageModelExecutorGenerationChannel,
            logger: Logger
        ) async throws -> Bool {
            if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { return true }
            guard let chunk = try? JSONNode.parse(payload) else {
                // Frame content is provider JSON, not user text, but log
                // only its size to keep the no-content guarantee simple.
                logger.debug("skipping malformed SSE frame", metadata: [
                    "bytes": .stringConvertible(payload.utf8.count)
                ])
                return false
            }

            let choice = chunk["choices"]?[0]
            let delta = choice?["delta"]
            if case .string(let content) = delta?["content"], !content.isEmpty {
                await channel.send(.response(action: .appendText(content, tokenCount: 0)))
            }
            for reasoningKey in ["reasoning", "reasoning_content"] {
                if case .string(let reasoning) = delta?[reasoningKey], !reasoning.isEmpty {
                    await channel.send(.reasoning(action: .appendText(reasoning, tokenCount: 0)))
                }
            }
            if let usage = chunk["usage"], case .object = usage {
                func intValue(_ node: JSONNode?) -> Int {
                    if case .integer(let value) = node { return value }
                    // Some providers serialize token counts as JSON floats
                    // (e.g. "prompt_tokens": 57.0); accept integral doubles.
                    if case .number(let value) = node, let exact = Int(exactly: value) { return exact }
                    return 0
                }
                await channel.send(.response(action: .updateUsage(
                    input: .init(
                        totalTokenCount: intValue(usage["prompt_tokens"]),
                        cachedTokenCount: intValue(usage["prompt_tokens_details"]?["cached_tokens"])
                    ),
                    output: .init(
                        totalTokenCount: intValue(usage["completion_tokens"]),
                        reasoningTokenCount: intValue(usage["completion_tokens_details"]?["reasoning_tokens"])
                    )
                )))
            }
            if case .array(let calls) = delta?["tool_calls"] {
                toolCalls.ingest(calls)
            }
            // Citations arrive as `url_citation` annotations, either streamed on
            // the delta or attached to a full message.
            Self.collectCitations(from: delta?["annotations"], into: &citations)
            Self.collectCitations(from: choice?["message"]?["annotations"], into: &citations)
            if case .string(let finishReason) = choice?["finish_reason"] {
                switch finishReason {
                case "content_filter":
                    // The provider's safety system stopped generation.
                    throw LanguageModelError.guardrailViolation(.init(
                        debugDescription: "provider stopped generation with finish_reason=content_filter"
                    ))
                case "length":
                    logger.warning(
                        "response truncated by provider; guided-generation output may fail JSON decoding",
                        metadata: ["finish_reason": .string("length")]
                    )
                default:
                    break
                }
            }
            return false
        }

        /// Parses `url_citation` annotations from an annotations array node into
        /// accumulated citations. Handles both the nested
        /// `{ "type":"url_citation", "url_citation": {...} }` shape and a flat
        /// `{ "url":..., "title":... }`.
        static func collectCitations(
            from node: JSONNode?,
            into citations: inout [WebCitationSegment.Citation]
        ) {
            guard case .array(let annotations)? = node else { return }
            func intValue(_ node: JSONNode?) -> Int? {
                if case .integer(let value)? = node { return value }
                return nil
            }
            for annotation in annotations {
                if case .string(let type)? = annotation["type"], type != "url_citation" { continue }
                let source = annotation["url_citation"] ?? annotation
                guard case .string(let urlString)? = source["url"],
                    let url = URL(string: urlString) else { continue }
                let title: String?
                if case .string(let value)? = source["title"] { title = value } else { title = nil }
                citations.append(.init(
                    url: url, title: title,
                    startIndex: intValue(source["start_index"]),
                    endIndex: intValue(source["end_index"])
                ))
            }
        }

        /// Merges streamed tool-call delta fragments into complete calls.
        ///
        /// With an `index` field the provider addresses calls explicitly.
        /// Without one, an element carrying an `id` starts a NEW call
        /// (monotonic counter); elements with neither `id` nor `index`
        /// append arguments to the most recent call.
        struct ToolCallAccumulator {
            private(set) var calls: [Int: (id: String, name: String, arguments: String)] = [:]
            private var nextSyntheticIndex = 0
            private var lastIndex: Int?

            mutating func ingest(_ elements: [JSONNode]) {
                for call in elements {
                    let index: Int
                    if case .integer(let explicit) = call["index"] {
                        index = explicit
                        nextSyntheticIndex = max(nextSyntheticIndex, explicit + 1)
                    } else if case .string(let id) = call["id"], !id.isEmpty {
                        index = nextSyntheticIndex
                        nextSyntheticIndex += 1
                    } else {
                        index = lastIndex ?? 0
                    }
                    lastIndex = index

                    var accumulated = calls[index] ?? (id: "", name: "", arguments: "")
                    if case .string(let id) = call["id"], !id.isEmpty {
                        accumulated.id = id
                    }
                    if case .string(let name) = call["function"]?["name"], !name.isEmpty {
                        accumulated.name = name
                    }
                    if case .string(let fragment) = call["function"]?["arguments"] {
                        accumulated.arguments += fragment
                    }
                    calls[index] = accumulated
                }
            }
        }

        private static let plainHTTPAuthWarningLogged = Mutex(false)

        static func warnIfPlainHTTPAuthorization(
            endpoint: URL, headers: [String: String], logger: Logger
        ) {
            guard endpoint.scheme?.lowercased() == "http",
                headers.contains(where: { $0.key.lowercased() == "authorization" }) else { return }
            let shouldLog = plainHTTPAuthWarningLogged.withLock { logged -> Bool in
                guard !logged else { return false }
                logged = true
                return true
            }
            if shouldLog {
                logger.warning("sending Authorization header over plain HTTP", metadata: [
                    "host": .string(endpoint.host ?? "?"),
                ])
            }
        }

        // MARK: Request construction

        func makeURLRequest(for request: LanguageModelExecutorGenerationRequest) throws -> URLRequest {
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.timeoutInterval = configuration.timeout
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue(
                configuration.stream ? "text/event-stream" : "application/json",
                forHTTPHeaderField: "Accept"
            )
            for (header, value) in configuration.additionalHeaders {
                if value.contains(where: { $0 == "\n" || $0 == "\r" }) {
                    throw TransportConfigurationError(
                        "additionalHeaders values must not contain newline characters"
                    )
                }
                urlRequest.setValue(value, forHTTPHeaderField: header)
            }
            let bodyNode = makeBody(for: request)
            // getenv (not ProcessInfo) so the flag is honored even when set
            // after process start (Darwin caches ProcessInfo's environment).
            if getenv("LF_DEBUG") != nil {
                // Redacted dump: structure stays visible, but prompt /
                // instruction / tool content never reaches stderr (this
                // file's no-content-logging guarantee).
                FileHandle.standardError.write(Data("LF_DEBUG body: \(bodyNode.redactingContent().serialized)\n".utf8))
            }
            urlRequest.httpBody = Data(bodyNode.serialized.utf8)
            return urlRequest
        }

        var endpoint: URL {
            // A URL that already names the chat completions endpoint is
            // used verbatim — never doubled.
            var path = configuration.url.path
            while path.hasSuffix("/") { path.removeLast() }
            if path.hasSuffix("/chat/completions") {
                return configuration.url
            }
            if configuration.url.pathComponents.contains("v1") {
                return configuration.url.appendingPathComponent("chat/completions")
            }
            return configuration.url.appendingPathComponent("v1/chat/completions")
        }

        func makeBody(for request: LanguageModelExecutorGenerationRequest) -> JSONNode {
            var members: [JSONNode.Member] = [
                .init(key: "model", value: .string(configuration.modelName)),
            ]
            if configuration.stream {
                members.append(.init(key: "stream", value: .bool(true)))
                members.append(.init(key: "stream_options", value: .object([
                    .init(key: "include_usage", value: .bool(true))
                ])))
            }
            members.append(.init(key: "messages", value: .array(makeMessages(from: request.transcript))))

            if let reasoningLevel = request.contextOptions.reasoningLevel {
                let effort: String
                switch reasoningLevel {
                case .light: effort = "low"
                case .moderate: effort = "medium"
                case .deep: effort = "high"
                case .custom(let value): effort = value
                }
                members.append(.init(key: "reasoning_effort", value: .string(effort)))
            }

            let options = request.generationOptions
            if let temperature = options.temperature {
                members.append(.init(key: "temperature", value: .number(temperature)))
            }
            if let maximum = options.maximumResponseTokens {
                members.append(.init(key: "max_tokens", value: .integer(maximum)))
            }
            if let samplingMode = options.samplingMode {
                switch samplingMode.kind {
                case .greedy:
                    // Deterministic decoding; an explicit temperature wins.
                    if options.temperature == nil {
                        members.append(.init(key: "temperature", value: .integer(0)))
                    }
                case .nucleus(let threshold, let seed):
                    members.append(.init(key: "top_p", value: .number(threshold)))
                    if let seed, let exact = Int(exactly: seed) {
                        members.append(.init(key: "seed", value: .integer(exact)))
                    }
                case .top(_, let seed):
                    // top-k has no standard chat-completions field; the seed
                    // still rides the request.
                    if let seed, let exact = Int(exactly: seed) {
                        members.append(.init(key: "seed", value: .integer(exact)))
                    }
                }
            }

            var tools: [JSONNode] = request.enabledToolDefinitions.map { definition in
                JSONNode.object([
                    .init(key: "type", value: .string("function")),
                    .init(key: "function", value: .object([
                        .init(key: "name", value: .string(definition.name)),
                        .init(key: "description", value: .string(definition.description)),
                        .init(key: "parameters", value: definition.parameters.jsonSchemaDocument),
                    ])),
                ])
            }
            // Provider-executed server tools (e.g. openrouter:web_search) are
            // passed through verbatim alongside any function tools.
            for serverTool in configuration.serverTools {
                if let node = try? JSONNode.parse(serverTool.json) {
                    tools.append(node)
                }
            }
            if !tools.isEmpty {
                members.append(.init(key: "tools", value: .array(tools)))
            }
            if let toolCallingMode = options.toolCallingMode {
                let choice: String
                switch toolCallingMode.kind {
                case .allowed: choice = "auto"
                case .required: choice = "required"
                case .disallowed: choice = "none"
                }
                members.append(.init(key: "tool_choice", value: .string(choice)))
            }

            if let schema = request.schema, configuration.supportsGuidedGeneration {
                members.append(.init(key: "response_format", value: .object([
                    .init(key: "type", value: .string("json_schema")),
                    .init(key: "json_schema", value: .object([
                        .init(key: "name", value: .string("response")),
                        .init(key: "strict", value: .bool(true)),
                        .init(key: "schema", value: strictSchemaCompatible(schema.jsonSchemaDocument)),
                    ])),
                ])))
            }

            return .object(members)
        }

        // Strict structured-output endpoints (OpenAI, Anthropic) reject
        // value-constraint keywords in response schemas. Dropping them silently
        // would lose authored intent — each folds into the description the
        // model reads instead. Only response_format is sanitized; tool
        // parameter schemas are not validated strictly by these endpoints.
        func strictSchemaCompatible(_ node: JSONNode) -> JSONNode {
            switch node {
            case .array(let items):
                return .array(items.map(strictSchemaCompatible))
            case .object(let members):
                let constraintKeys = [
                    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
                    "multipleOf", "minItems", "maxItems", "minLength", "maxLength",
                ]
                var folded: [String] = []
                var kept: [JSONNode.Member] = []
                for member in members {
                    let scalar: String? = switch member.value {
                    case .integer(let i): String(i)
                    case .number(let d): d == d.rounded() ? String(Int(d)) : String(d)
                    default: nil
                    }
                    // Only scalar-valued matches are schema keywords; an object
                    // under the same key is a property that shares the name.
                    if let scalar, constraintKeys.contains(member.key) {
                        folded.append("\(member.key) \(scalar)")
                        continue
                    }
                    kept.append(.init(key: member.key, value: strictSchemaCompatible(member.value)))
                }
                guard !folded.isEmpty else { return .object(kept) }
                let suffix = "(" + folded.joined(separator: ", ") + ")"
                if let i = kept.firstIndex(where: { $0.key == "description" }),
                   case .string(let existing) = kept[i].value {
                    kept[i].value = .string(existing.isEmpty ? suffix : existing + " " + suffix)
                } else {
                    kept.append(.init(key: "description", value: .string(suffix)))
                }
                return .object(kept)
            default:
                return node
            }
        }

        func makeMessages(from transcript: Transcript) -> [JSONNode] {
            var messages: [JSONNode] = []
            for entry in transcript {
                switch entry {
                case .instructions(let instructions):
                    messages.append(.object([
                        .init(key: "role", value: .string("system")),
                        .init(key: "content", value: .string(instructions.segments.joinedText)),
                    ]))
                case .prompt(let prompt):
                    messages.append(.object([
                        .init(key: "role", value: .string("user")),
                        .init(key: "content", value: .string(prompt.segments.joinedText)),
                    ]))
                case .response(let response):
                    messages.append(.object([
                        .init(key: "role", value: .string("assistant")),
                        .init(key: "content", value: .string(response.segments.joinedText)),
                    ]))
                case .toolCalls(let toolCalls):
                    let calls = toolCalls.calls.map { call in
                        JSONNode.object([
                            .init(key: "id", value: .string(call.id)),
                            .init(key: "type", value: .string("function")),
                            .init(key: "function", value: .object([
                                .init(key: "name", value: .string(call.toolName)),
                                .init(key: "arguments", value: .string(call.arguments.jsonString)),
                            ])),
                        ])
                    }
                    messages.append(.object([
                        .init(key: "role", value: .string("assistant")),
                        .init(key: "tool_calls", value: .array(calls)),
                    ]))
                case .toolOutput(let toolOutput):
                    messages.append(.object([
                        .init(key: "role", value: .string("tool")),
                        .init(key: "tool_call_id", value: .string(toolOutput.id)),
                        .init(key: "content", value: .string(toolOutput.segments.joinedText)),
                    ]))
                case .reasoning:
                    continue
                }
            }
            return messages
        }
    }
}

// MARK: - JSONNode traversal conveniences

extension JSONNode {
    subscript(key: String) -> JSONNode? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    subscript(index: Int) -> JSONNode? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    /// Returns a copy with every string value under a "content" or
    /// "arguments" key replaced by "<redacted, N chars>". Keeps the request
    /// structure visible in debug dumps without leaking prompt, instruction,
    /// response, or tool-argument text.
    func redactingContent() -> JSONNode {
        switch self {
        case .array(let elements):
            return .array(elements.map { $0.redactingContent() })
        case .object(let members):
            return .object(members.map { member in
                if member.key == "content" || member.key == "arguments",
                    case .string(let text) = member.value {
                    return Member(key: member.key, value: .string("<redacted, \(text.count) chars>"))
                }
                return Member(key: member.key, value: member.value.redactingContent())
            })
        default:
            return self
        }
    }
}


// MARK: - Cross-platform SSE line streaming

/// Streams an HTTP response body line by line. Darwin uses `URLSession.bytes`;
/// Linux corelibs lacks it, so a data-delegate feeds an AsyncThrowingStream.
enum HTTPLineStream {
    /// Decodes one raw SSE line (without its terminating `\n`), stripping at
    /// most one trailing `\r` from `\r\n` framing per the SSE spec.
    static func decodeLine(_ bytes: some Collection<UInt8>) -> String {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.last == "\r" { line.removeLast() }
        return line
    }

    static func connect(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, any Error>, HTTPURLResponse) {
        #if AsyncHTTPClient
        return try await connectViaAsyncHTTPClient(request)
        #elseif canImport(Darwin)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LanguageModelTransportError(statusCode: 0, message: "non-HTTP response")
        }
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let task = Task {
            do {
                // Manual 0x0A byte splitting, matching the Linux and
                // AsyncHTTPClient transports: `bytes.lines` would also split
                // on U+2028/U+2029/NEL, which may legally occur inside JSON
                // string content.
                var buffer = [UInt8]()
                for try await byte in bytes {
                    if byte == 0x0A {
                        continuation.yield(decodeLine(buffer))
                        buffer.removeAll(keepingCapacity: true)
                    } else {
                        buffer.append(byte)
                    }
                }
                if !buffer.isEmpty {
                    continuation.yield(decodeLine(buffer))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return (stream, http)
        #else
        return try await LinuxSSESession.shared.connect(request)
        #endif
    }
}

#if !canImport(Darwin)
import Synchronization

/// One shared URLSession for all SSE requests; the router delegate fans
/// events out to per-task line streams. (Per-request URLSession instances
/// churn file descriptors and worker threads under production load.)
///
/// @unchecked Sendable invariant: `handlers` is guarded by `Mutex`; delegate
/// callbacks run on URLSession's queue and never escape handler references.
final class LinuxSSESession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = LinuxSSESession()

    private let handlers = Mutex([Int: LineStreamDelegate]())
    // Eagerly created: a `lazy var` is not thread-safe, and a first-use race
    // from concurrent sessions can construct several URLSessions whose
    // per-session taskIdentifiers collide in `handlers`, routing events to
    // the wrong stream and stranding the losers mid-await.
    private var session: URLSession!

    private override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, any Error>, HTTPURLResponse) {
        let (handler, task) = register(request)
        task.resume()
        let response = try await handler.response()
        return (handler.lines, response)
    }

    private func register(_ request: URLRequest) -> (LineStreamDelegate, URLSessionDataTask) {
        let handler = LineStreamDelegate()
        let task = session.dataTask(with: request)
        handlers.withLock { $0[task.taskIdentifier] = handler }
        handler.onTerminate = { [weak task] in task?.cancel() }
        return (handler, task)
    }

    private func handler(for task: URLSessionTask) -> LineStreamDelegate? {
        handlers.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        handler(for: dataTask)?.receive(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(for: dataTask)?.receive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let finished = handler(for: task)
        handlers.withLock { _ = $0.removeValue(forKey: task.taskIdentifier) }
        finished?.complete(error: error)
    }
}
#endif

#if !canImport(Darwin)
private struct LineStreamState {
    var buffer = Data()
    var responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>?
    var storedResponse: HTTPURLResponse?
    var finishedEarly: (any Error)??
}

/// @unchecked Sendable invariant: stream state is guarded by `Mutex`;
/// continuations are resumed outside the lock after being taken.
final class LineStreamDelegate: @unchecked Sendable {
    private let state = Mutex(LineStreamState())

    var onTerminate: (@Sendable () -> Void)?

    let lines: AsyncThrowingStream<String, any Error>
    private let lineContinuation: AsyncThrowingStream<String, any Error>.Continuation

    init() {
        (lines, lineContinuation) = AsyncThrowingStream.makeStream()
        lineContinuation.onTermination = { [self] reason in
            if case .cancelled = reason { onTerminate?() }
        }
    }

    func response() async throws -> HTTPURLResponse {
        // Cancellation-aware: cancelling the surrounding task cancels the
        // URLSession task, whose didComplete callback resumes us with the
        // cancellation error instead of stranding the continuation.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Outcome {
                    case stored(HTTPURLResponse)
                    case failed(any Error)
                    case pending
                }
                let outcome = state.withLock { snapshot -> Outcome in
                    if let storedResponse = snapshot.storedResponse {
                        return .stored(storedResponse)
                    }
                    if let finishedEarly = snapshot.finishedEarly {
                        return .failed(finishedEarly ?? LanguageModelTransportError(
                            statusCode: 0, message: "connection closed before a response arrived"
                        ))
                    }
                    snapshot.responseContinuation = continuation
                    return .pending
                }
                switch outcome {
                case .stored(let response):
                    continuation.resume(returning: response)
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .pending:
                    break
                }
            }
        } onCancel: {
            onTerminate?()
        }
    }

    func receive(response: URLResponse) {
        let continuation = state.withLock { snapshot -> CheckedContinuation<HTTPURLResponse, any Error>? in
            snapshot.storedResponse = response as? HTTPURLResponse
            let continuation = snapshot.responseContinuation
            snapshot.responseContinuation = nil
            return continuation
        }
        if let continuation {
            if let http = response as? HTTPURLResponse {
                continuation.resume(returning: http)
            } else {
                continuation.resume(throwing: LanguageModelTransportError(
                    statusCode: 0, message: "non-HTTP response"
                ))
            }
        }
    }

    func receive(data: Data) {
        let emitted = state.withLock { snapshot -> [String] in
            snapshot.buffer.append(data)
            var lines: [String] = []
            var lineStart = snapshot.buffer.startIndex
            while lineStart < snapshot.buffer.endIndex,
                let newline = snapshot.buffer[lineStart...].firstIndex(of: 0x0A) {
                lines.append(HTTPLineStream.decodeLine(snapshot.buffer[lineStart..<newline]))
                lineStart = snapshot.buffer.index(after: newline)
            }
            if lineStart != snapshot.buffer.startIndex {
                snapshot.buffer.removeSubrange(snapshot.buffer.startIndex..<lineStart)
            }
            return lines
        }
        for line in emitted {
            lineContinuation.yield(line)
        }
    }

    func complete(error: (any Error)?) {
        let trailing = state.withLock { snapshot -> String? in
            guard !snapshot.buffer.isEmpty else { return nil }
            let text = HTTPLineStream.decodeLine(snapshot.buffer)
            snapshot.buffer.removeAll()
            return text
        }
        if let trailing { lineContinuation.yield(trailing) }
        let continuation = state.withLock { snapshot -> CheckedContinuation<HTTPURLResponse, any Error>? in
            let continuation = snapshot.responseContinuation
            snapshot.responseContinuation = nil
            snapshot.finishedEarly = .some(error)
            return continuation
        }
        if let continuation {
            continuation.resume(throwing: error ?? LanguageModelTransportError(
                statusCode: 0, message: "connection closed before a response arrived"
            ))
        }
        if let error {
            lineContinuation.finish(throwing: error)
        } else {
            lineContinuation.finish()
        }
    }
}
#endif


#if AsyncHTTPClient
import AsyncHTTPClient
import NIOCore

/// Process-global NIO HTTP client tuned for concurrent server-side model calls.
///
/// `HTTPClient.shared` caps HTTP/1 connections per host at 8, so a server firing
/// many concurrent requests at one provider host queues behind that ceiling.
/// This raises the soft limit. HTTP/2 (the default via `.automatic`) multiplexes
/// over a single connection when the server offers it, so the higher limit only
/// bites on HTTP/1 fallback. Held in a `static let` that lives for the process,
/// so it is never deinited without shutdown (which AsyncHTTPClient would log).
enum PooledHTTPClient {
    static let shared: HTTPClient = {
        var configuration = HTTPClient.Configuration()
        configuration.httpVersion = .automatic
        configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 50
        configuration.connectionPool.idleTimeout = .seconds(90)
        configuration.timeout.connect = .seconds(10)
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }()
}

/// Activity epoch for the AsyncHTTPClient body idle watchdog. A class wrapper
/// so closures capture a Sendable reference, not a bare `Mutex` value.
private final class StreamActivity: @unchecked Sendable {
    private let epochLock = Mutex<UInt64>(0)

    func bump() {
        epochLock.withLock { $0 += 1 }
    }

    func epoch() -> UInt64 {
        epochLock.withLock { $0 }
    }
}

extension HTTPLineStream {
    /// NIO-based transport: pooled connections, concurrent-safe streaming.
    static func connectViaAsyncHTTPClient(
        _ request: URLRequest
    ) async throws -> (AsyncThrowingStream<String, any Error>, HTTPURLResponse) {
        try await Self.connect(request, using: PooledHTTPClient.shared)
    }

    private static func connect(
        _ request: URLRequest,
        using client: HTTPClient
    ) async throws -> (AsyncThrowingStream<String, any Error>, HTTPURLResponse) {
        guard let url = request.url else {
            throw LanguageModelTransportError(statusCode: 0, message: "request has no URL")
        }
        var httpRequest = HTTPClientRequest(url: url.absoluteString)
        httpRequest.method = .RAW(value: request.httpMethod ?? "GET")
        for (header, value) in request.allHTTPHeaderFields ?? [:] {
            httpRequest.headers.add(name: header, value: value)
        }
        if let body = request.httpBody {
            httpRequest.body = .bytes(ByteBuffer(bytes: body))
        }

        // URLRequest.timeoutInterval is an idle (between-bytes) timeout on
        // URLSession. AsyncHTTPClient's execute `timeout` is a total deadline,
        // so confine it to connect + response headers; body bytes are guarded
        // by a long-lived idle watchdog below.
        let idleTimeout = request.timeoutInterval
        let idleNanos = UInt64((idleTimeout * 1_000_000_000).rounded())
        let headDeadline = TimeAmount.milliseconds(Int64((idleTimeout * 1000).rounded()))
        let response = try await client.execute(httpRequest, timeout: headDeadline)
        guard let httpResponse = HTTPURLResponse(
            url: url, statusCode: Int(response.status.code), httpVersion: nil,
            headerFields: Dictionary(response.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        ) else {
            throw LanguageModelTransportError(statusCode: 0, message: "could not form response")
        }

        let activity = StreamActivity()
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let idleWatchdog = Task<Void, Never> {
            var lastEpoch = activity.epoch()
            // Timeout precision is [idle, 2*idle): detected on the first wake
            // where no chunk arrived since the previous wake.
            while true {
                try? await Task.sleep(nanoseconds: idleNanos)
                if Task.isCancelled { return }
                let current = activity.epoch()
                if current == lastEpoch {
                    continuation.finish(throwing: URLError(.timedOut))
                    return
                }
                lastEpoch = current
            }
        }
        let pump = Task<Void, any Error> {
            defer { idleWatchdog.cancel() }
            var buffer = Data()

            do {
                for try await chunk in response.body {
                    activity.bump()
                    try Task.checkCancellation()
                    buffer.append(contentsOf: chunk.readableBytesView)
                    // Advance a cursor over the buffered bytes and compact the
                    // consumed prefix once per chunk. Removing each line from the
                    // front instead would re-shift the tail per line — O(n²) over
                    // a chunk with many lines.
                    var lineStart = buffer.startIndex
                    while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                        continuation.yield(HTTPLineStream.decodeLine(buffer[lineStart..<newline]))
                        lineStart = buffer.index(after: newline)
                    }
                    if lineStart != buffer.startIndex {
                        buffer.removeSubrange(buffer.startIndex..<lineStart)
                    }
                }
                if !buffer.isEmpty {
                    continuation.yield(HTTPLineStream.decodeLine(buffer))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            pump.cancel()
        }
        return (stream, httpResponse)
    }
}
#endif
