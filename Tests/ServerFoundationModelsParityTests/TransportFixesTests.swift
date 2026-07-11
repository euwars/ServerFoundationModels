// Regression coverage for transport fixes: RFC 7231 Retry-After dates,
// tool_choice/sampling option encoding, finish_reason handling, indexless
// tool-call deltas, endpoint doubling, float usage values, SSE event
// assembly (multi-line data:, BOM), and LF_DEBUG content redaction.
//
// Everything runs offline against the loopback CaptureServer (see
// WireCaptureTests.swift) or a local path-capturing sibling. Only the
// package's public API is used (no @testable; the macro target cannot be
// linked into the test product in testable mode).

import Foundation
import Logging
import Testing
import ServerFoundationModels
import ServerFoundationModelsUtilities

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Transport fixes")
struct TransportFixesTests {

    private func makeSession(port: UInt16, path: String = "") -> LanguageModelSession {
        LanguageModelSession(model: ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "http://127.0.0.1:\(port)\(path)")!
        ))
    }

    /// Runs the executor directly against a mock server and collects every
    /// channel event (the session would try to execute unknown tools). A
    /// sentinel metadata event marks the end of the captured stream.
    private func collectEvents(
        port: UInt16
    ) async throws -> [any LanguageModelExecutorGenerationChannel.Event] {
        let model = ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "http://127.0.0.1:\(port)")!
        )
        let executor = try ChatCompletionsLanguageModel.Executor(configuration: model.executorConfiguration)
        let channel = LanguageModelExecutorGenerationChannel()
        let request = LanguageModelExecutorGenerationRequest(
            transcript: Transcript(entries: [
                .prompt(.init(segments: [.text(.init(content: "hi"))]))
            ])
        )
        try await executor.respond(to: request, model: model, streamingInto: channel)
        await channel.send(.response(action: .updateMetadata(["sentinel": "end"])))

        var events: [any LanguageModelExecutorGenerationChannel.Event] = []
        for try await event in channel {
            if let response = event as? LanguageModelExecutorGenerationChannel.Response,
                case .updateMetadata(let metadata) = response.action,
                metadata.values["sentinel"] as? String == "end" {
                break
            }
            events.append(event)
        }
        return events
    }

    private static let httpDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        return formatter
    }()

    // MARK: Retry-After

    @Test("Retry-After HTTP-date on a 429 yields a non-nil resetDate")
    func retryAfterHTTPDate() async throws {
        let date = Self.httpDateFormat.string(from: Date(timeIntervalSinceNow: 30))
        let server = try CaptureServer(
            body: #"{"error": {"message": "rate limit exceeded"}}"#,
            head: "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nRetry-After: \(date)\r\nConnection: close"
        )
        defer { server.stop() }

        do {
            _ = try await makeSession(port: server.port).respond(to: "hi")
            Issue.record("expected rateLimited to be thrown")
        } catch let error as LanguageModelError {
            guard case .rateLimited(let context) = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
            let reset = try #require(context.resetDate, "an HTTP-date Retry-After must parse")
            // The HTTP-date format truncates sub-second precision.
            #expect(reset.timeIntervalSinceNow > 20 && reset.timeIntervalSinceNow <= 31)
        }
    }

    // MARK: Generation options on the wire

    @Test("tool_choice, top_p, and seed reach the outgoing request body")
    func toolChoiceAndSamplingGoOut() async throws {
        let server = try CaptureServer()
        defer { server.stop() }

        let session = LanguageModelSession(
            model: ChatCompletionsLanguageModel(
                name: "wire-model",
                url: URL(string: "http://127.0.0.1:\(server.port)")!
            ),
            tools: [ThermometerTool(recorder: CallRecorder())]
        )
        _ = try await session.respond(to: "hi", options: GenerationOptions(
            samplingMode: .random(probabilityThreshold: 0.9, seed: 42),
            toolCallingMode: .required
        ))

        let body = try #require(server.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["tool_choice"] as? String == "required")
        #expect(json["top_p"] as? Double == 0.9)
        #expect(json["seed"] as? Int == 42)
    }

    @Test("tool calling modes map to auto/required/none")
    func toolCallingModeMapping() async throws {
        let server = try CaptureServer()
        defer { server.stop() }
        // `tool_choice` only rides the wire when the request actually carries
        // tools — some providers (xAI) reject a tool_choice against an empty
        // tools array — so give the session a tool to exercise the mapping.
        let session = LanguageModelSession(
            model: ChatCompletionsLanguageModel(
                name: "wire-model",
                url: URL(string: "http://127.0.0.1:\(server.port)")!
            ),
            tools: [ThermometerTool(recorder: CallRecorder())]
        )

        func wiredToolChoice(_ mode: GenerationOptions.ToolCallingMode) async throws -> String? {
            _ = try await session.respond(to: "hi", options: GenerationOptions(toolCallingMode: mode))
            let body = try #require(server.lastBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            return json["tool_choice"] as? String
        }

        #expect(try await wiredToolChoice(.allowed) == "auto")
        #expect(try await wiredToolChoice(.required) == "required")
        #expect(try await wiredToolChoice(.disallowed) == "none")
    }

    @Test("greedy sampling sends temperature 0 only when no explicit temperature is set")
    func greedySamplingMapping() async throws {
        let server = try CaptureServer()
        defer { server.stop() }
        let session = makeSession(port: server.port)

        func wiredTemperature(_ options: GenerationOptions) async throws -> Double? {
            _ = try await session.respond(to: "hi", options: options)
            let body = try #require(server.lastBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            return json["temperature"] as? Double
        }

        #expect(try await wiredTemperature(GenerationOptions(samplingMode: .greedy)) == 0)
        #expect(try await wiredTemperature(GenerationOptions(samplingMode: .greedy, temperature: 0.25)) == 0.25)
    }

    // MARK: finish_reason

    @Test("finish_reason content_filter throws guardrailViolation")
    func contentFilterThrows() async throws {
        let server = try CaptureServer(body: [
            #"data: {"choices":[{"index":0,"delta":{"content":"par"}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"content_filter"}]}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" }.joined())
        defer { server.stop() }

        do {
            _ = try await makeSession(port: server.port).respond(to: "hi")
            Issue.record("expected guardrailViolation to be thrown")
        } catch let error as LanguageModelError {
            guard case .guardrailViolation = error else {
                Issue.record("expected .guardrailViolation, got \(error)")
                return
            }
        }
    }

    @Test("finish_reason length logs a truncation warning")
    func lengthLogsWarning() async throws {
        let server = try CaptureServer(body: [
            #"data: {"choices":[{"index":0,"delta":{"content":"cut"}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" }.joined())
        defer { server.stop() }

        let records = LogRecords()
        var logger = Logger(label: "test", factory: { _ in RecordingLogHandler(records: records) })
        logger.logLevel = .trace
        var model = ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "http://127.0.0.1:\(server.port)")!
        )
        model.logger = logger

        let response = try await LanguageModelSession(model: model).respond(to: "hi")
        #expect(response.content == "cut")
        #expect(records.all.contains { record in
            record.level == .warning && "\(record.metadata)".contains("length")
        })
    }

    // MARK: Tool-call deltas without index

    @Test("indexless tool-call deltas produce distinct calls keyed by id arrival")
    func indexlessToolCallDeltas() async throws {
        let server = try CaptureServer(body: [
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_a","type":"function","function":{"name":"alpha","arguments":""}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"{\"x\":1}"}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_b","type":"function","function":{"name":"beta","arguments":"{}"}}]}}]}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" }.joined())
        defer { server.stop() }

        let events = try await collectEvents(port: server.port)
        let calls = events.compactMap { event -> (id: String, name: String, arguments: String)? in
            guard let toolEvent = event as? LanguageModelExecutorGenerationChannel.ToolCalls,
                case .toolCall(let call) = toolEvent.action,
                case .appendArguments(let fragment) = call.action else { return nil }
            return (call.id, call.name, fragment.content)
        }

        try #require(calls.count == 2, "two ids must yield two distinct calls, got \(calls)")
        #expect(calls[0].id == "call_a")
        #expect(calls[0].name == "alpha")
        #expect(calls[0].arguments == #"{"x":1}"#)
        #expect(calls[1].id == "call_b")
        #expect(calls[1].name == "beta")
        #expect(calls[1].arguments == "{}")
    }

    @Test("indexed tool-call deltas keep merging by index")
    func indexedToolCallDeltas() async throws {
        let server = try CaptureServer(body: [
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"alpha","arguments":"{\"a\""}}]}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":":1}"}}]}}]}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" }.joined())
        defer { server.stop() }

        let events = try await collectEvents(port: server.port)
        let calls = events.compactMap { event -> (name: String, arguments: String)? in
            guard let toolEvent = event as? LanguageModelExecutorGenerationChannel.ToolCalls,
                case .toolCall(let call) = toolEvent.action,
                case .appendArguments(let fragment) = call.action else { return nil }
            return (call.name, fragment.content)
        }
        try #require(calls.count == 1)
        #expect(calls[0].name == "alpha")
        #expect(calls[0].arguments == #"{"a":1}"#)
    }

    // MARK: Endpoint doubling

    @Test("a URL already ending in chat/completions is used verbatim on the wire")
    func endpointNotDoubled() async throws {
        let server = try PathCaptureServer()
        defer { server.stop() }

        let response = try await makeSession(port: server.port, path: "/v1/chat/completions").respond(to: "hi")
        #expect(response.content == "ok")

        let path = try #require(server.lastPath)
        #expect(path == "/v1/chat/completions")
        #expect(path.components(separatedBy: "chat/completions").count == 2, "path must contain chat/completions exactly once")
    }

    @Test("endpoint heuristics: verbatim full paths, v1 bases, bare bases")
    func endpointHeuristics() async throws {
        let server = try PathCaptureServer()
        defer { server.stop() }

        func servedPath(base: String) async throws -> String {
            _ = try await makeSession(port: server.port, path: base).respond(to: "hi")
            return try #require(server.lastPath)
        }

        #expect(try await servedPath(base: "") == "/v1/chat/completions")
        #expect(try await servedPath(base: "/v1") == "/v1/chat/completions")
        #expect(try await servedPath(base: "/api/chat/completions") == "/api/chat/completions")
        #expect(try await servedPath(base: "/v1/chat/completions") == "/v1/chat/completions")
    }

    // MARK: Usage as floats

    @Test("usage token counts serialized as JSON floats decode to their integral values")
    func floatUsageValues() async throws {
        let server = try CaptureServer(body: [
            #"data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":57.0,"completion_tokens":3.0,"prompt_tokens_details":{"cached_tokens":2.0},"completion_tokens_details":{"reasoning_tokens":1.0}}}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" }.joined())
        defer { server.stop() }

        let response = try await makeSession(port: server.port).respond(to: "hi")
        #expect(response.content == "ok")
        #expect(response.usage.input.totalTokenCount == 57)
        #expect(response.usage.input.cachedTokenCount == 2)
        #expect(response.usage.output.totalTokenCount == 3)
        #expect(response.usage.output.reasoningTokenCount == 1)
    }

    // MARK: SSE spec gaps

    @Test("consecutive data: lines of one event are joined with a newline")
    func multiLineDataEvent() async throws {
        let server = try CaptureServer(
            body: "data: {\"choices\":[{\"index\":0,\ndata: \"delta\":{\"content\":\"joined\"}}]}\n\ndata: [DONE]\n\n"
        )
        defer { server.stop() }

        let response = try await makeSession(port: server.port).respond(to: "hi")
        #expect(response.content == "joined")
    }

    @Test("a leading U+FEFF BOM at stream start is stripped")
    func bomPrefixedStream() async throws {
        let server = try CaptureServer(body: "\u{FEFF}" + [
            #"data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" }.joined())
        defer { server.stop() }

        let response = try await makeSession(port: server.port).respond(to: "hi")
        #expect(response.content == "ok")
    }

    @Test("data:[DONE] without a space still terminates the stream")
    func doneWithoutSpace() async throws {
        let server = try CaptureServer(body: [
            #"data:{"choices":[{"index":0,"delta":{"content":"ok"}}]}"#,
            "data:[DONE]",
        ].map { $0 + "\n\n" }.joined())
        defer { server.stop() }

        let response = try await makeSession(port: server.port).respond(to: "hi")
        #expect(response.content == "ok")
    }

    // MARK: Streaming idle timeout

    @Test("streaming idle timeout when the server stalls after the first chunk")
    func streamingIdleTimeoutOnStall() async throws {
        let server = try StallMidStreamServer()
        defer { server.stop() }

        let model = ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "http://127.0.0.1:\(server.port)")!,
            timeout: 1
        )
        let started = Date()
        do {
            _ = try await LanguageModelSession(model: model).respond(to: "hi")
            Issue.record("expected a timeout error")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            #expect(Date().timeIntervalSince(started) < 5, "must not hang waiting for stalled bytes")
        } catch {
            Issue.record("expected URLError.timedOut, got \(error)")
        }
    }

    // MARK: LF_DEBUG redaction

    @Test("LF_DEBUG dumps the request body with content redacted")
    func lfDebugRedactsContent() async throws {
        let server = try CaptureServer()
        defer { server.stop() }
        let secret = "transport-fixes-super-secret-prompt"

        // Capture stderr around the request while LF_DEBUG is set.
        let pipe = Pipe()
        let savedStderr = dup(STDERR_FILENO)
        setenv("LF_DEBUG", "1", 1)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        var requestError: (any Error)?
        do {
            _ = try await makeSession(port: server.port).respond(to: secret)
        } catch {
            requestError = error
        }

        dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        unsetenv("LF_DEBUG")
        pipe.fileHandleForWriting.closeFile()
        let captured = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pipe.fileHandleForReading.closeFile()

        if let requestError { throw requestError }
        #expect(captured.contains("LF_DEBUG body:"), "the debug dump must still be emitted")
        #expect(!captured.contains(secret), "prompt text must never reach stderr")
        #expect(captured.contains("<redacted, \(secret.count) chars>"), "content is replaced by a size marker")
        // Structure stays visible.
        #expect(captured.contains(#""role":"user""#))
        #expect(captured.contains(#""model":"wire-model""#))
    }
}

// MARK: - Loopback server that stalls mid-stream

/// Sends response headers and one SSE chunk, then blocks without closing.
final class StallMidStreamServer: @unchecked Sendable {
    private let socket: Int32
    let port: UInt16
    private let lock = NSLock()
    private var running = true

    init() throws {
        let fd = Foundation.socket(AF_INET, PATH_SOCK_STREAM_VALUE, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 4) == 0 else {
            throw CaptureServer.CaptureError(message: "could not bind loopback server")
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        socket = fd
        port = UInt16(bigEndian: bound.sin_port)
        Thread.detachNewThread { [weak self] in
            while let self, self.isRunning {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                self.handle(client: client)
                close(client)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        close(socket)
    }

    private func handle(client: Int32) {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var contentLength = 0
        var headerEnd: Int?
        while true {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            data.append(contentsOf: chunk[0..<count])
            if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
                let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                for line in head.split(separator: "\r\n").dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].lowercased() == "content-length" {
                        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
            }
            if let headerEnd, data.count - headerEnd >= contentLength {
                break
            }
        }

        let firstChunk = #"data: {"choices":[{"index":0,"delta":{"content":"x"}}]}"# + "\n\n"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: keep-alive\r\n\r\n\(firstChunk)"
        _ = response.withCString { pointer in
            write(client, pointer, response.utf8.count)
        }

        var sink = [UInt8](repeating: 0, count: 1024)
        while isRunning {
            let count = read(client, &sink, sink.count)
            if count <= 0 { break }
        }
    }
}

// MARK: - Loopback server that records the request path

/// Like CaptureServer, but records the HTTP request line so tests can assert
/// the exact path the transport hit.
final class PathCaptureServer: @unchecked Sendable {
    private let socket: Int32
    let port: UInt16
    private let lock = NSLock()
    private var _requestLine: String?
    private var running = true

    private static let responseBody = "data: "
        + #"{"choices":[{"index":0,"delta":{"content":"ok"}}]}"#
        + "\n\ndata: [DONE]\n\n"

    var requestLine: String? {
        lock.lock()
        defer { lock.unlock() }
        return _requestLine
    }

    /// The path component of the captured request line ("POST /p HTTP/1.1").
    var lastPath: String? {
        guard let requestLine else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    init() throws {
        let fd = Foundation.socket(AF_INET, PATH_SOCK_STREAM_VALUE, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 4) == 0 else {
            throw CaptureServer.CaptureError(message: "could not bind loopback server")
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        socket = fd
        port = UInt16(bigEndian: bound.sin_port)
        Thread.detachNewThread { [weak self] in
            while let self, self.isRunning {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                self.handle(client: client)
                close(client)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        close(socket)
    }

    private func handle(client: Int32) {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var contentLength = 0
        var headerEnd: Int?
        while true {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            data.append(contentsOf: chunk[0..<count])
            if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
                let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
                lock.lock()
                _requestLine = lines.first.map(String.init)
                lock.unlock()
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].lowercased() == "content-length" {
                        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
            }
            if let headerEnd, data.count - headerEnd >= contentLength {
                break
            }
        }

        let body = PathCaptureServer.responseBody
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = response.withCString { pointer in
            write(client, pointer, response.utf8.count)
        }
    }
}

#if canImport(Darwin)
private let PATH_SOCK_STREAM_VALUE = SOCK_STREAM
#else
private let PATH_SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
#endif
