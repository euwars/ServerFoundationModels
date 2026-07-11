// Production-hardening proof for the SSE transport path: error mapping,
// malformed frames, keep-alive comments, and streams that end without [DONE].
// Uses the loopback CaptureServer so every scenario is deterministic.

import Foundation
import Testing
import ServerFoundationModels
import ServerFoundationModelsUtilities

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("SSE transport edge cases")
struct SSEEdgeCaseTests {

    private func makeSession(port: UInt16) -> LanguageModelSession {
        LanguageModelSession(model: ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "http://127.0.0.1:\(port)")!
        ))
    }

    @Test("HTTP 429 with Retry-After maps to LanguageModelError.rateLimited with a reset date")
    func rateLimitedMapping() async throws {
        let server = try CaptureServer(
            body: #"{"error": {"message": "rate limit exceeded"}}"#,
            head: "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nRetry-After: 30\r\nConnection: close"
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
            let reset = try #require(context.resetDate)
            #expect(reset.timeIntervalSinceNow > 20 && reset.timeIntervalSinceNow <= 31)
        }
    }

    @Test("HTTP 400 mentioning the context window maps to contextSizeExceeded")
    func contextOverflowMapping() async throws {
        let server = try CaptureServer(
            body: #"{"error": {"message": "this model's maximum context length is 4096 tokens"}}"#,
            head: "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close"
        )
        defer { server.stop() }

        do {
            _ = try await makeSession(port: server.port).respond(to: "hi")
            Issue.record("expected contextSizeExceeded to be thrown")
        } catch let error as LanguageModelError {
            guard case .contextSizeExceeded = error else {
                Issue.record("expected .contextSizeExceeded, got \(error)")
                return
            }
        }
    }

    @Test("other HTTP errors surface as LanguageModelTransportError with the body")
    func plainTransportError() async throws {
        let server = try CaptureServer(
            body: #"{"error": "boom"}"#,
            head: "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close"
        )
        defer { server.stop() }

        do {
            _ = try await makeSession(port: server.port).respond(to: "hi")
            Issue.record("expected a transport error")
        } catch let error as LanguageModelTransportError {
            #expect(error.statusCode == 503)
            #expect(error.message.contains("boom"))
        }
    }

    @Test("malformed data frames and SSE comments are skipped without failing the response")
    func malformedFramesAndComments() async throws {
        let server = try CaptureServer(body: [
            ": keep-alive ping",
            "data: {not valid json",
            "data:",
            #"data: {"choices":[{"index":0,"delta":{"content":"hel"}}]}"#,
            "event: message",
            #"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}"#,
            "data: [DONE]",
        ].map { $0 + "\n\n" }.joined())
        defer { server.stop() }

        let response = try await makeSession(port: server.port).respond(to: "hi")
        #expect(response.content == "hello")
    }

    @Test("a stream that ends without [DONE] still completes with the accumulated content")
    func missingDoneFrame() async throws {
        let server = try CaptureServer(
            body: #"data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}"# + "\n\n"
        )
        defer { server.stop() }

        let response = try await makeSession(port: server.port).respond(to: "hi")
        #expect(response.content == "partial")
    }

    @Test("CRLF-delimited SSE frames parse the same as LF frames")
    func crlfFrames() async throws {
        let server = try CaptureServer(body: [
            #"data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}"#,
            "data: [DONE]",
        ].map { $0 + "\r\n\r\n" }.joined())
        defer { server.stop() }

        let response = try await makeSession(port: server.port).respond(to: "hi")
        #expect(response.content == "ok")
    }

    @Test("CRLF final frame without a trailing newline strips the carriage return")
    func crlfFinalFrameNoNewline() async throws {
        let server = try CaptureServer(
            body: #"data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}"# + "\r\n\r\n"
                + #"data: [DONE]"# + "\r"
        )
        defer { server.stop() }

        let response = try await makeSession(port: server.port).respond(to: "hi")
        #expect(response.content == "ok")
    }
}
