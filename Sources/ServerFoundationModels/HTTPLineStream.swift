// Cross-platform SSE line streaming shared by every HTTP-backed provider.
//
// Darwin uses `URLSession.bytes`; Linux corelibs lacks it, so a URLSession
// data-delegate feeds an `AsyncThrowingStream`; the `AsyncHTTPClient` trait
// swaps in a pooled NIO transport. Lives in the core module because both the
// native XAI provider and the ChatCompletions provider (now in the utilities
// target) stream through it. The JSONNode traversal helpers below are shared
// the same way.

import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - JSONNode traversal conveniences

extension JSONNode {
    package subscript(key: String) -> JSONNode? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    package subscript(index: Int) -> JSONNode? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    /// Returns a copy with every string value under a "content" or
    /// "arguments" key replaced by "<redacted, N chars>". Keeps the request
    /// structure visible in debug dumps without leaking prompt, instruction,
    /// response, or tool-argument text.
    package func redactingContent() -> JSONNode {
        switch self {
        case .array(let elements):
            return .array(elements.map { $0.redactingContent() })
        case .object(let members):
            return .object(members.map { member in
                // "text" covers content that rides as an array of typed parts
                // (`{"type":"text","text":…}`, e.g. cache_control breakpoints) —
                // without it the part's text would leak past redaction.
                if member.key == "content" || member.key == "arguments" || member.key == "text",
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
package enum HTTPLineStream {
    /// Decodes one raw SSE line (without its terminating `\n`), stripping at
    /// most one trailing `\r` from `\r\n` framing per the SSE spec.
    static func decodeLine(_ bytes: some Collection<UInt8>) -> String {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.last == "\r" { line.removeLast() }
        return line
    }

    package static func connect(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, any Error>, HTTPURLResponse) {
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
