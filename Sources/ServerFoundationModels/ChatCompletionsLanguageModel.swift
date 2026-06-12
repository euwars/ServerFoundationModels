// ChatCompletionsLanguageModel — a LanguageModel that talks to any
// OpenAI-compatible /chat/completions endpoint (Ollama, vLLM, llama-server,
// LM Studio, OpenRouter, ...). Modeled on Apple's implementation in
// apple/foundation-models-utilities (Apache 2.0).

import Foundation
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

    /// Per-request timeout, in seconds.
    public var timeout: TimeInterval

    public init(
        name: String,
        url: URL,
        additionalHeaders: [String: String] = [:],
        supportsGuidedGeneration: Bool = true,
        timeout: TimeInterval = 600
    ) {
        self.name = name
        self.url = url
        self.additionalHeaders = additionalHeaders
        self.supportsGuidedGeneration = supportsGuidedGeneration
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
            let urlRequest = try makeURLRequest(for: request)
            let (lines, response) = try await HTTPLineStream.connect(urlRequest)

            if response.statusCode != 200 {
                var body = ""
                for try await line in lines {
                    body += line
                    if body.count > 4096 { break }
                }
                if response.statusCode == 429 {
                    let resetDate = response.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init)
                        .map { Date(timeIntervalSinceNow: $0) }
                    throw LanguageModelError.rateLimited(.init(resetDate: resetDate, debugDescription: body))
                }
                // Providers report context overflow as a 400/413 mentioning
                // the context/token limit; surface it as the typed error.
                let lowered = body.lowercased()
                if [400, 413].contains(response.statusCode),
                    lowered.contains("context") || lowered.contains("maximum length"),
                    lowered.contains("token") || lowered.contains("length") || lowered.contains("window") {
                    throw LanguageModelError.contextSizeExceeded(.init(
                        contextSize: 0, tokenCount: 0, debugDescription: body
                    ))
                }
                throw LanguageModelTransportError(statusCode: response.statusCode, message: body)
            }

            // Accumulates streamed tool-call fragments by choice index.
            var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]

            for try await line in lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let chunk = try? JSONNode.parse(payload) else { continue }

                let delta = chunk["choices"]?[0]?["delta"]
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
                    for call in calls {
                        var index = 0
                        if case .integer(let i) = call["index"] { index = i }
                        var accumulated = toolCalls[index] ?? (id: "", name: "", arguments: "")
                        if case .string(let id) = call["id"], !id.isEmpty {
                            accumulated.id = id
                        }
                        if case .string(let name) = call["function"]?["name"], !name.isEmpty {
                            accumulated.name = name
                        }
                        if case .string(let fragment) = call["function"]?["arguments"] {
                            accumulated.arguments += fragment
                        }
                        toolCalls[index] = accumulated
                    }
                }
            }

            for index in toolCalls.keys.sorted() {
                let call = toolCalls[index]!
                await channel.send(.toolCalls(action: .toolCall(
                    id: call.id.isEmpty ? UUID().uuidString : call.id,
                    name: call.name,
                    action: .appendArguments(call.arguments, tokenCount: 0)
                )))
            }
        }

        // MARK: Request construction

        func makeURLRequest(for request: LanguageModelExecutorGenerationRequest) throws -> URLRequest {
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.timeoutInterval = configuration.timeout
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            for (header, value) in configuration.additionalHeaders {
                urlRequest.setValue(value, forHTTPHeaderField: header)
            }
            let body = makeBody(for: request).serialized
            if ProcessInfo.processInfo.environment["LF_DEBUG"] != nil {
                FileHandle.standardError.write(Data("LF_DEBUG body: \(body)\n".utf8))
            }
            urlRequest.httpBody = Data(body.utf8)
            return urlRequest
        }

        var endpoint: URL {
            if configuration.url.pathComponents.contains("v1") {
                return configuration.url.appendingPathComponent("chat/completions")
            }
            return configuration.url.appendingPathComponent("v1/chat/completions")
        }

        func makeBody(for request: LanguageModelExecutorGenerationRequest) -> JSONNode {
            var members: [JSONNode.Member] = [
                .init(key: "model", value: .string(configuration.modelName)),
                .init(key: "stream", value: .bool(true)),
                .init(key: "stream_options", value: .object([
                    .init(key: "include_usage", value: .bool(true))
                ])),
                .init(key: "messages", value: .array(makeMessages(from: request.transcript))),
            ]

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

            if !request.enabledToolDefinitions.isEmpty {
                let tools = request.enabledToolDefinitions.map { definition in
                    JSONNode.object([
                        .init(key: "type", value: .string("function")),
                        .init(key: "function", value: .object([
                            .init(key: "name", value: .string(definition.name)),
                            .init(key: "description", value: .string(definition.description)),
                            .init(key: "parameters", value: definition.parameters.jsonSchemaDocument),
                        ])),
                    ])
                }
                members.append(.init(key: "tools", value: .array(tools)))
            }

            if let schema = request.schema, configuration.supportsGuidedGeneration {
                members.append(.init(key: "response_format", value: .object([
                    .init(key: "type", value: .string("json_schema")),
                    .init(key: "json_schema", value: .object([
                        .init(key: "name", value: .string("response")),
                        .init(key: "strict", value: .bool(true)),
                        .init(key: "schema", value: schema.jsonSchemaDocument),
                    ])),
                ])))
            }

            return .object(members)
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
}


// MARK: - Cross-platform SSE line streaming

/// Streams an HTTP response body line by line. Darwin uses `URLSession.bytes`;
/// Linux corelibs lacks it, so a data-delegate feeds an AsyncThrowingStream.
enum HTTPLineStream {
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
                for try await line in bytes.lines {
                    continuation.yield(line)
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
/// One shared URLSession for all SSE requests; the router delegate fans
/// events out to per-task line streams. (Per-request URLSession instances
/// churn file descriptors and worker threads under production load.)
final class LinuxSSESession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = LinuxSSESession()

    private let lock = NSLock()
    private var handlers: [Int: LineStreamDelegate] = [:]
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
        lock.lock()
        handlers[task.taskIdentifier] = handler
        lock.unlock()
        handler.onTerminate = { [weak task] in task?.cancel() }
        return (handler, task)
    }

    private func handler(for task: URLSessionTask) -> LineStreamDelegate? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[task.taskIdentifier]
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
        lock.lock()
        handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        finished?.complete(error: error)
    }
}
#endif

#if !canImport(Darwin)
final class LineStreamDelegate: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>?
    private var storedResponse: HTTPURLResponse?
    private var finishedEarly: (any Error)??

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
                lock.lock()
                if let storedResponse {
                    lock.unlock()
                    continuation.resume(returning: storedResponse)
                } else if let finishedEarly {
                    lock.unlock()
                    continuation.resume(throwing: finishedEarly ?? LanguageModelTransportError(
                        statusCode: 0, message: "connection closed before a response arrived"
                    ))
                } else {
                    responseContinuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            onTerminate?()
        }
    }

    func receive(response: URLResponse) {
        lock.lock()
        storedResponse = response as? HTTPURLResponse
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
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
        lock.lock()
        buffer.append(data)
        var emitted: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            emitted.append(String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        lock.unlock()
        for line in emitted {
            lineContinuation.yield(line)
        }
    }

    func complete(error: (any Error)?) {
        lock.lock()
        if !buffer.isEmpty {
            let trailing = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            lineContinuation.yield(trailing)
        }
        let continuation = responseContinuation
        responseContinuation = nil
        finishedEarly = .some(error)
        lock.unlock()
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

extension HTTPLineStream {
    /// NIO-based transport: pooled connections, concurrent-safe streaming.
    static func connectViaAsyncHTTPClient(
        _ request: URLRequest
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

        let response = try await HTTPClient.shared.execute(httpRequest, timeout: .seconds(Int64(request.timeoutInterval)))
        guard let httpResponse = HTTPURLResponse(
            url: url, statusCode: Int(response.status.code), httpVersion: nil,
            headerFields: Dictionary(response.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        ) else {
            throw LanguageModelTransportError(statusCode: 0, message: "could not form response")
        }

        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let pump = Task {
            var buffer = Data()
            do {
                for try await chunk in response.body {
                    buffer.append(contentsOf: chunk.readableBytesView)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        continuation.yield(String(decoding: lineData, as: UTF8.self)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                    }
                }
                if !buffer.isEmpty {
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { reason in
            if case .cancelled = reason { pump.cancel() }
        }
        return (stream, httpResponse)
    }
}
#endif
