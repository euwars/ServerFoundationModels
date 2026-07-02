// swift-log integration: silent by default, and when a Logger is supplied
// the transport reports request lifecycle and anomalies — without ever
// logging prompt or response content.

import Foundation
import Logging
import Testing
import ServerFoundationModels

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("swift-log integration")
struct LoggingTests {

    private func makeModel(port: UInt16, records: LogRecords) -> ChatCompletionsLanguageModel {
        var logger = Logger(label: "test", factory: { _ in RecordingLogHandler(records: records) })
        logger.logLevel = .trace
        var model = ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "http://127.0.0.1:\(port)")!
        )
        model.logger = logger
        return model
    }

    @Test("a successful round logs the request at debug, never the prompt text")
    func successfulRoundLogs() async throws {
        let server = try CaptureServer()
        defer { server.stop() }
        let records = LogRecords()

        let session = LanguageModelSession(model: makeModel(port: server.port, records: records))
        _ = try await session.respond(to: "this prompt text must never be logged")

        let all = records.all
        #expect(all.contains { $0.level == .debug && $0.message.contains("request") })
        #expect(!all.contains { $0.message.contains("never be logged") || "\($0.metadata)".contains("never be logged") })
    }

    @Test("HTTP error responses are logged at warning with the status code")
    func errorResponseLogs() async throws {
        let server = try CaptureServer(
            body: #"{"error": "rate limit exceeded"}"#,
            head: "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 5\r\nConnection: close"
        )
        defer { server.stop() }
        let records = LogRecords()

        let session = LanguageModelSession(model: makeModel(port: server.port, records: records))
        _ = try? await session.respond(to: "hi")

        #expect(records.all.contains { record in
            record.level == .warning && "\(record.metadata)".contains("429")
        })
    }

    @Test("malformed SSE frames are logged at debug and skipped")
    func malformedFrameLogs() async throws {
        let server = try CaptureServer(body: [
            "data: {broken",
            #"data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" }.joined())
        defer { server.stop() }
        let records = LogRecords()

        let session = LanguageModelSession(model: makeModel(port: server.port, records: records))
        let response = try await session.respond(to: "hi")

        #expect(response.content == "ok")
        #expect(records.all.contains { $0.level == .debug && $0.message.contains("malformed") })
    }

    @Test("the default logger is a no-op: nothing is emitted anywhere")
    func defaultLoggerIsNoOp() {
        let model = ChatCompletionsLanguageModel(name: "m", url: URL(string: "http://127.0.0.1:1")!)
        #expect(model.logger.handler is SwiftLogNoOpLogHandler)
    }
}

// MARK: - Recording log handler

final class LogRecords: @unchecked Sendable {
    struct Record {
        let level: Logger.Level
        let message: String
        let metadata: Logger.Metadata
    }

    private let lock = NSLock()
    private var records: [Record] = []

    func append(_ record: Record) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    var all: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

struct RecordingLogHandler: LogHandler {
    let records: LogRecords
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        log(
            level: event.level, message: event.message, metadata: event.metadata,
            source: event.source, file: event.file, function: event.function, line: event.line
        )
    }

    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {
        records.append(.init(
            level: level,
            message: message.description,
            metadata: (self.metadata).merging(metadata ?? [:]) { _, new in new }
        ))
    }
}
