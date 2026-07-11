// Wire-level proof of the OpenRouter-specific surface: provider routing,
// reasoning, native web search, app attribution headers, and body merging all
// leave the process as expected — plus credit-exhaustion mapping. Mirrors the
// XAI wire tests, driving OpenRouterLanguageModel against the loopback
// CaptureServer (defined in WireCaptureTests).

import Foundation
import Testing
@testable import ServerFoundationModels
import ServerFoundationModelsUtilities
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("OpenRouter provider — wire + behaviour")
struct OpenRouterWireTests {

    @Test("provider routing, reasoning, native web search, and attribution reach the wire")
    func openRouterSpecificsGoOut() async throws {
        let server = try CaptureServer()
        defer { server.stop() }

        let model = OpenRouterLanguageModel(
            model: "anthropic/claude-sonnet-4",
            apiKey: "or-test-key",
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            providerRouting: .init(order: ["anthropic", "google-vertex"], allowFallbacks: false, sort: .throughput),
            serverTools: [.webSearch(engine: .native)],
            reasoning: .init(effort: .high),
            appURL: "https://example.com",
            appTitle: "Deep Research"
        )
        _ = try await LanguageModelSession(model: model, instructions: "You are a research analyst.")
            .respond(to: "hello")

        let body = try #require(server.lastBody, "the request body must be captured")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "anthropic/claude-sonnet-4")

        // Provider routing, pinned so the run can't drift across backends.
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["order"] as? [String] == ["anthropic", "google-vertex"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
        #expect(provider["sort"] as? String == "throughput")

        // Reasoning controls.
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "high")

        // Native web search — engine "native" explicitly, never left to auto.
        let tools = try #require(json["tools"] as? [[String: Any]])
        let webSearch = try #require(tools.first { ($0["type"] as? String) == "openrouter:web_search" })
        #expect((webSearch["parameters"] as? [String: Any])?["engine"] as? String == "native")

        // Auth + OpenRouter app-attribution headers.
        #expect(server.lastHeaders["authorization"] == "Bearer or-test-key")
        #expect(server.lastHeaders["http-referer"] == "https://example.com")
        #expect(server.lastHeaders["x-title"] == "Deep Research")
    }

    @Test("extraBodyJSON merges with — and can override — typed fields")
    func extraBodyMerges() async throws {
        let server = try CaptureServer()
        defer { server.stop() }
        let model = OpenRouterLanguageModel(
            model: "x",
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            reasoning: .init(effort: .low),
            extraBodyJSON: #"{"reasoning":{"effort":"high"},"transforms":["middle-out"]}"#
        )
        _ = try await LanguageModelSession(model: model).respond(to: "hi")

        let body = try #require(server.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // The user's extra body wins over the typed reasoning value.
        #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(json["transforms"] as? [String] == ["middle-out"])
    }

    @Test("credit exhaustion (HTTP 402 / 403-credit) is recognized")
    func creditExhaustionHeuristic() {
        #expect(HTTPErrorHeuristics.isCreditExhaustion(statusCode: 402, body: "anything"))
        #expect(HTTPErrorHeuristics.isCreditExhaustion(statusCode: 403, body: "Key limit exceeded"))
        #expect(HTTPErrorHeuristics.isCreditExhaustion(statusCode: 403, body: "no credit remaining"))
        #expect(!HTTPErrorHeuristics.isCreditExhaustion(statusCode: 403, body: "forbidden"))
        #expect(!HTTPErrorHeuristics.isCreditExhaustion(statusCode: 500, body: "credit"))
        #expect(!HTTPErrorHeuristics.isCreditExhaustion(statusCode: 429, body: "rate"))
    }

    @Test("a 402 response surfaces as OpenRouterError.creditExhausted")
    func creditExhaustionMapping() async throws {
        let server = try CaptureServer(
            body: #"{"error":{"message":"Insufficient credits"}}"#,
            head: "HTTP/1.1 402 Payment Required\r\nContent-Type: application/json\r\nConnection: close"
        )
        defer { server.stop() }
        let model = OpenRouterLanguageModel(model: "x", baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        await #expect(throws: OpenRouterError.self) {
            _ = try await LanguageModelSession(model: model).respond(to: "hi")
        }
    }
}
