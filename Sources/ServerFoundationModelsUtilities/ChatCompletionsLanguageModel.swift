// ChatCompletionsLanguageModel — a LanguageModel that talks to any
// OpenAI-compatible /chat/completions endpoint (Ollama, vLLM, llama-server,
// LM Studio, OpenRouter, ...). Modeled on Apple's implementation in
// apple/foundation-models-utilities (Apache 2.0).

import Foundation
import Logging
import Synchronization
import ServerFoundationModels
#if canImport(os)
import os
#endif
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

    /// How structured output rides the wire. OpenAI-style endpoints take the
    /// full JSON schema (`.jsonSchema`); some (Ollama's compat layer) silently
    /// IGNORE it and only honor `{"type":"json_object"}` — the schema then
    /// constrains via the prompt, which the session includes by default.
    public enum SchemaWire: String, Hashable, Sendable {
        case jsonSchema
        /// json_schema with `strict: false` — some models (glm via Vercel)
        /// emit a degenerate `{"":""}` under strict enforcement but honor the
        /// schema correctly when it is advisory. Pair with lenient decoding.
        case jsonSchemaLoose
        case jsonObject
    }
    public var schemaWire: SchemaWire

    /// Provider-executed server tools (e.g. `openrouter:web_search`) injected
    /// verbatim into each request's `tools` array.
    public var serverTools: [ChatCompletionsServerTool]

    /// When false, requests are sent non-streaming (a single JSON response).
    /// Some providers are more reliable non-streaming for structured output
    /// combined with server tools.
    public var stream: Bool

    /// Per-request timeout, in seconds.
    public var timeout: TimeInterval

    /// A JSON object merged verbatim into every request body — for provider
    /// routing controls the standard fields don't cover, e.g. OpenRouter's
    /// `{"provider":{"order":["SomeProvider"],"allow_fallbacks":false}}`.
    /// Invalid or non-object JSON is ignored.
    public var additionalBodyJSON: String?

    /// Transport diagnostics via swift-log: request lifecycle at `.debug`,
    /// HTTP errors at `.warning`, skipped SSE frames at `.debug`. Prompt,
    /// instruction, and response CONTENT is never logged at any level.
    /// Silent (no-op handler) unless you assign your own logger.
    public var logger = Logging.Logger(label: "ServerFoundationModels", factory: { _ in SwiftLogNoOpLogHandler() })

    public init(
        name: String,
        url: URL,
        additionalHeaders: [String: String] = [:],
        supportsGuidedGeneration: Bool = true,
        schemaWire: SchemaWire = .jsonSchema,
        serverTools: [ChatCompletionsServerTool] = [],
        stream: Bool = true,
        timeout: TimeInterval = 600,
        additionalBodyJSON: String? = nil
    ) {
        self.name = name
        self.url = url
        self.additionalHeaders = additionalHeaders
        self.supportsGuidedGeneration = supportsGuidedGeneration
        self.schemaWire = schemaWire
        self.serverTools = serverTools
        self.stream = stream
        self.timeout = timeout
        self.additionalBodyJSON = additionalBodyJSON
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
            schemaWire: schemaWire,
            serverTools: serverTools,
            stream: stream,
            timeout: timeout,
            additionalBodyJSON: additionalBodyJSON
        )
    }

    // MARK: Executor

    public struct Executor: LanguageModelExecutor {
        public struct Configuration: Hashable, Sendable {
            var modelName: String
            var url: URL
            var additionalHeaders: [String: String]
            var supportsGuidedGeneration: Bool
            var schemaWire: SchemaWire = .jsonSchema
            var serverTools: [ChatCompletionsServerTool] = []
            var stream: Bool = true
            var timeout: TimeInterval = 600
            var additionalBodyJSON: String? = nil
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
            let clock = ContinuousClock()
            let enqueued = clock.now
            // One permit per HTTP request (connect through end of stream),
            // never per session turn — a tool handler that calls a model
            // itself cannot deadlock on the gate.
            try await RequestGate.shared.withPermit {
                let started = clock.now
                let timing = RequestTimingBox()
                #if canImport(os)
                let session = (request.metadata["timeline.session"] as? String) ?? ""
                let signpost = FMSignpost.request
                let interval = signpost.beginInterval(
                    "request", id: signpost.makeSignpostID(),
                    "model=\(configuration.modelName, privacy: .public) session=\(session, privacy: .public)")
                #endif
                let promptExcerpt: String = {
                    for entry in request.transcript.reversed() {
                        if case .prompt(let prompt) = entry {
                            let text = prompt.segments.compactMap { segment -> String? in
                                if case .text(let text) = segment { return text.content }
                                return nil
                            }.joined(separator: " ")
                            return String(text.prefix(400))
                        }
                    }
                    return ""
                }()
                func record(succeeded: Bool) async {
                    let finished = clock.now
                    #if canImport(os)
                    let ttft = (timing.firstEventAt ?? finished) - started
                    signpost.endInterval(
                        "request", interval,
                        "ttft_ms=\(ttft.wholeMilliseconds, privacy: .public) in=\(timing.inputTokens, privacy: .public) out=\(timing.outputTokens, privacy: .public) ok=\(succeeded ? 1 : 0, privacy: .public)")
                    #endif
                    await RequestTimeline.shared.record(ModelRequestTiming(
                        model: configuration.modelName,
                        session: (request.metadata["timeline.session"] as? String) ?? "",
                        sessionInstance: (request.metadata["timeline.instance"] as? Int) ?? 0,
                        start: RequestTimeline.shared.offset(of: started),
                        gateWait: started - enqueued,
                        connect: (timing.connectAt ?? finished) - started,
                        firstToken: (timing.firstEventAt ?? finished) - started,
                        total: finished - started,
                        succeeded: succeeded,
                        promptExcerpt: promptExcerpt,
                        responseExcerpt: timing.responseExcerpt,
                        inputTokens: timing.inputTokens,
                        outputTokens: timing.outputTokens
                    ))
                }
                do {
                    try await gatedRespond(to: request, model: model, streamingInto: channel, timing: timing)
                    await record(succeeded: true)
                } catch {
                    await record(succeeded: false)
                    throw error
                }
            }
        }

        private func gatedRespond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ChatCompletionsLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel,
            timing: RequestTimingBox
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
            timing.connectAt = ContinuousClock().now

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
                try await respondNonStreaming(lines: lines, channel: channel, logger: logger, timing: timing)
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
                    timing.firstEventAt = ContinuousClock().now
                    // A single leading U+FEFF BOM at stream start is ignored.
                    if line.first == "\u{FEFF}" { line.removeFirst() }
                }
                if line.isEmpty {
                    guard !pendingData.isEmpty else { continue }
                    let payload = pendingData.joined(separator: "\n")
                    pendingData.removeAll()
                    if try await processEvent(payload, toolCalls: &toolCalls, citations: &citations, channel: channel, logger: logger, timing: timing) {
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
                _ = try await processEvent(payload, toolCalls: &toolCalls, citations: &citations, channel: channel, logger: logger, timing: timing)
            }

            for index in toolCalls.calls.keys.sorted() {
                let call = toolCalls.calls[index]!
                // A round whose whole answer is tool calls has no text — the
                // timeline shows the calls instead of an empty response.
                timing.appendResponse("→ \(call.name) \(String(call.arguments.prefix(140)))\n")
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
            logger: Logging.Logger,
            timing: RequestTimingBox
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
                timing.appendResponse(content)
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
                timing.inputTokens = intValue(usage["prompt_tokens"])
                timing.outputTokens = intValue(usage["completion_tokens"])
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
                    timing.appendResponse("→ \(call.name) \(String(call.arguments.prefix(140)))\n")
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
            logger: Logging.Logger,
            timing: RequestTimingBox
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
                timing.appendResponse(content)
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
                timing.inputTokens = intValue(usage["prompt_tokens"])
                timing.outputTokens = intValue(usage["completion_tokens"])
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
            endpoint: URL, headers: [String: String], logger: Logging.Logger
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
            var messageNodes = makeMessages(from: request.transcript)
            // When the wire cannot carry the schema (json_object mode, or no
            // guided generation at all), it must reach the model through the
            // prompt — otherwise the model never sees the field names and
            // answers in prose. Suppressed per request once the transcript
            // demonstrates the format (includeSchemaInPrompt: false).
            if let schema = request.schema,
               configuration.schemaWire == .jsonObject || !configuration.supportsGuidedGeneration,
               request.contextOptions.includeSchemaInPrompt != false {
                messageNodes.append(.object([
                    .init(key: "role", value: .string("system")),
                    .init(key: "content", value: .string(
                        "Respond with a single JSON object matching this JSON schema exactly — no prose, no markdown fences:\n"
                            + schema.jsonSchemaDocument.serialized
                    )),
                ]))
            }
            members.append(.init(key: "messages", value: .array(messageNodes)))

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
            // passed through verbatim alongside any function tools — except on
            // turns that forbid tool calling (structured extraction), where a
            // server-side search would silently run and bill anyway.
            if request.generationOptions.toolCallingMode?.kind != .disallowed {
                for serverTool in configuration.serverTools {
                    if let node = try? JSONNode.parse(serverTool.json) {
                        tools.append(node)
                    }
                }
            }
            if !tools.isEmpty {
                members.append(.init(key: "tools", value: .array(tools)))
            }
            // tool_choice only makes sense when tools are on the request — and
            // xAI hard-rejects a tool_choice with an empty tools array. With no
            // tools there is nothing to call regardless, so omit it.
            if let toolCallingMode = options.toolCallingMode, !tools.isEmpty {
                let choice: String
                switch toolCallingMode.kind {
                case .allowed: choice = "auto"
                case .required: choice = "required"
                case .disallowed: choice = "none"
                }
                members.append(.init(key: "tool_choice", value: .string(choice)))
            }

            if let schema = request.schema, configuration.supportsGuidedGeneration {
                switch configuration.schemaWire {
                case .jsonSchema, .jsonSchemaLoose:
                    members.append(.init(key: "response_format", value: .object([
                        .init(key: "type", value: .string("json_schema")),
                        .init(key: "json_schema", value: .object([
                            .init(key: "name", value: .string("response")),
                            .init(key: "strict", value: .bool(configuration.schemaWire == .jsonSchema)),
                            .init(key: "schema", value: strictSchemaCompatible(schema.jsonSchemaDocument)),
                        ])),
                    ])))
                case .jsonObject:
                    // Endpoints that ignore json_schema still enforce JSON
                    // syntax; field structure rides in the prompt schema.
                    members.append(.init(key: "response_format", value: .object([
                        .init(key: "type", value: .string("json_object")),
                    ])))
                }
            }

            // Caller-supplied body fields ride last so explicit routing
            // controls (e.g. OpenRouter `provider`) reach the wire intact.
            if let extra = configuration.additionalBodyJSON,
               case .object(let extraMembers)? = try? JSONNode.parse(extra) {
                members.append(contentsOf: extraMembers)
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
            // A prompt-cache breakpoint: wrap text so the provider caches the
            // prefix up to here. Honored by Anthropic + Gemini via OpenRouter,
            // ignored by providers that don't support it — pure upside on the
            // repeated instructions and the gather tool-loop's growing context.
            func cacheable(_ text: String) -> JSONNode {
                .array([.object([
                    .init(key: "type", value: .string("text")),
                    .init(key: "text", value: .string(text)),
                    .init(key: "cache_control", value: .object([.init(key: "type", value: .string("ephemeral"))])),
                ])])
            }
            var messages: [JSONNode] = []
            for entry in transcript {
                switch entry {
                case .instructions(let instructions):
                    messages.append(.object([
                        .init(key: "role", value: .string("system")),
                        .init(key: "content", value: cacheable(instructions.segments.joinedText)),
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
            // Second breakpoint at the end of the accumulated context: the
            // gather tool-loop re-sends every prior tool output on each turn, so
            // caching that growing prefix is the largest single saving.
            for i in stride(from: messages.count - 1, through: 0, by: -1) {
                guard case .object(var members) = messages[i],
                      let ci = members.firstIndex(where: { $0.key == "content" }),
                      case .string(let text) = members[ci].value else { continue }
                members[ci] = .init(key: "content", value: cacheable(text))
                messages[i] = .object(members)
                break
            }
            return messages
        }
    }
}
