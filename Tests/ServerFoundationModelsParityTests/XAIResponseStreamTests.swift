import Foundation
@testable import ServerFoundationModels
import Testing

@Suite struct XAIResponseStreamTests {
    @Test func streamsServerToolSegmentBeforeText() async throws {
        var accumulator = XAIResponseStream.Accumulator()
        let added = """
        {"type":"response.output_item.added","output_index":0,"item":{"type":"web_search_call","id":"ws_1","status":"in_progress","action":{"type":"search","query":"xAI"}}}
        """
        let done = """
        {"type":"response.output_item.done","output_index":0,"item":{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"xAI"}}}
        """
        let delta = """
        {"type":"response.output_text.delta","item_id":"msg_1","output_index":1,"content_index":0,"delta":"xAI is an AI company."}
        """
        let completed = """
        {"type":"response.completed","response":{"id":"resp_stream","output":[{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"xAI"}},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"xAI is an AI company."}]}],"citations":["https://x.ai/news"],"usage":{"input_tokens":10,"output_tokens":5}}}
        """

        let first = try accumulator.ingest(payload: added)
        #expect(first.count == 1)
        if case .updateCustomSegment(let segment) = first[0],
            case .webSearch(let search) = segment.content
        {
            #expect(search.query == "xAI")
            #expect(search.status == "in_progress")
        } else {
            Issue.record("expected in-progress web search segment")
        }

        _ = try accumulator.ingest(payload: done)
        _ = try accumulator.ingest(payload: delta)
        let final = try accumulator.ingest(payload: completed)

        let parsed = accumulator.finish()
        #expect(parsed.responseId == "resp_stream")
        #expect(parsed.text == "xAI is an AI company.")
        #expect(final.contains { action in
            if case .usage = action { return true }
            return false
        })
    }

    @Test func citationsAttachToLastSearchSegmentOnly() throws {
        let json = """
        {
          "id": "resp_cites",
          "output": [
            {
              "type": "web_search_call",
              "id": "ws_1",
              "status": "completed",
              "action": {"type": "search", "query": "first"}
            },
            {
              "type": "web_search_call",
              "id": "ws_2",
              "status": "completed",
              "action": {"type": "search", "query": "second"}
            },
            {
              "type": "message",
              "content": [{"type": "output_text", "text": "answer"}]
            }
          ],
          "citations": ["https://example.com/a", "https://example.com/b"]
        }
        """
        let parsed = try XAIResponseTranslator.parse(body: Data(json.utf8))
        let segments = parsed.orderedEvents.compactMap { event -> XAIServerToolSegment? in
            guard case .customSegment(let segment) = event.kind else { return nil }
            return segment
        }
        #expect(segments.count == 2)
        #expect(segments[0].outcomeCitationCount == 0)
        #expect(segments[1].outcomeCitationCount == 2)
    }

    // Regression: the function name lives on the `function_call` output item,
    // not on `function_call_arguments.done`, so a streamed client tool call must
    // still surface with its name (else the tool loop silently drops it).
    @Test func streamingCapturesClientFunctionCall() throws {
        var acc = XAIResponseStream.Accumulator()
        _ = try acc.ingest(payload: """
        {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"getWeather","arguments":""}}
        """)
        _ = try acc.ingest(payload: """
        {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\\"city\\":\\"Tokyo\\"}"}
        """)
        let completed = """
        {"type":"response.completed","response":{"id":"r1","output":[{"type":"function_call","id":"fc_1","call_id":"call_1","name":"getWeather","arguments":"{\\"city\\":\\"Tokyo\\"}"}],"usage":{"input_tokens":5,"output_tokens":3}}}
        """
        let actions = try acc.ingest(payload: completed)
        let call = actions.compactMap { action -> (id: String, name: String, args: String)? in
            if case .toolCall(let id, let name, let args) = action { return (id, name, args) }
            return nil
        }.first
        #expect(call?.name == "getWeather")
        #expect(call?.id == "call_1")
        #expect(call?.args.contains("Tokyo") == true)
    }

    @Test func skipsMalformedSSEFrame() throws {
        var acc = XAIResponseStream.Accumulator()
        let skipped = try acc.ingest(payload: "not valid json{{{")
        #expect(skipped.isEmpty)
        let delta = try acc.ingest(payload: #"{"type":"response.output_text.delta","delta":"hi"}"#)
        #expect(delta.count == 1)
    }

    @Test func streamRateLimitMapsToTypedError() throws {
        var acc = XAIResponseStream.Accumulator()
        do {
            _ = try acc.ingest(payload: #"{"type":"error","code":429,"message":"rate limited"}"#)
            Issue.record("expected rateLimited error")
        } catch let error as LanguageModelError {
            guard case .rateLimited = error else {
                Issue.record("expected rateLimited, got \(error)")
            }
        }
    }

    @Test func streamContextOverflowMapsToTypedError() throws {
        var acc = XAIResponseStream.Accumulator()
        do {
            _ = try acc.ingest(payload: """
            {"type":"response.failed","response":{"error":{"code":400,"message":"maximum context length exceeded"}}}
            """)
            Issue.record("expected contextSizeExceeded error")
        } catch let error as LanguageModelError {
            guard case .contextSizeExceeded = error else {
                Issue.record("expected contextSizeExceeded, got \(error)")
            }
        }
    }
}

private extension XAIServerToolSegment {
    var outcomeCitationCount: Int {
        switch content {
        case .webSearch(let search): search.outcome?.citations.count ?? 0
        case .xSearch(let search): search.outcome?.citations.count ?? 0
        default: 0
        }
    }
}