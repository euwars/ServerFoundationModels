import Foundation
@testable import ServerFoundationModels
import Testing

@Suite struct XAIResponseTranslatorTests {
    @Test func parsesTextUsageAndToolCalls() throws {
        let json = """
        {
          "id": "resp_123",
          "output": [
            {
              "type": "message",
              "content": [{"type": "output_text", "text": "Hello from Grok"}]
            },
            {
              "type": "function_call",
              "id": "call_1",
              "name": "fetchWeather",
              "arguments": "{\\"city\\":\\"SF\\"}"
            }
          ],
          "usage": {
            "input_tokens": 100,
            "output_tokens": 20,
            "input_tokens_details": {"cached_tokens": 80}
          }
        }
        """
        let parsed = try XAIResponseTranslator.parse(body: Data(json.utf8))
        #expect(parsed.responseId == "resp_123")
        #expect(parsed.text == "Hello from Grok")
        #expect(parsed.toolCalls.count == 1)
        #expect(parsed.toolCalls[0].name == "fetchWeather")
        #expect(parsed.usage?.input.cachedTokenCount == 80)
        #expect(parsed.usage?.input.totalTokenCount == 100)
        // The channel receives text via orderedEvents' appendText (there is no
        // separate parsed.text emission), so the message text appears here.
        #expect(parsed.orderedEvents.count == 1)
        if case .appendText(let text) = parsed.orderedEvents.first?.kind {
            #expect(text == "Hello from Grok")
        } else {
            Issue.record("expected an appendText ordered event for the message text")
        }
    }

    @Test func emitDeliversCustomSegmentsBeforeText() async throws {
        let json = """
        {
          "id": "resp_456",
          "output": [
            {
              "type": "web_search_call",
              "id": "ws_a",
              "status": "in_progress",
              "action": {"type": "search", "query": "latest news"}
            },
            {
              "type": "message",
              "content": [{"type": "output_text", "text": "Here is the summary."}]
            }
          ]
        }
        """
        let parsed = try XAIResponseTranslator.parse(body: Data(json.utf8))
        let channel = LanguageModelExecutorGenerationChannel()
        let task = Task {
            await XAIResponseTranslator.emit(parsed, into: channel)
            channel.finish()
        }

        var customSegments: [XAIServerToolSegment] = []
        var text = ""
        for await event in channel.stream {
            guard case .response(let response) = event.storage else { continue }
            switch response.action.storage {
            case .updateCustomSegment(let segment):
                if let xai = segment as? XAIServerToolSegment {
                    customSegments.append(xai)
                }
            case .appendText(let fragment):
                text += fragment.content
            default:
                break
            }
        }
        await task.value

        #expect(customSegments.count == 1)
        #expect(customSegments[0].toolName == "web_search")
        if case .webSearch(let search) = customSegments[0].content {
            #expect(search.query == "latest news")
            #expect(search.outcome == nil)
        } else {
            Issue.record("expected webSearch content")
        }
        #expect(text == "Here is the summary.")
    }

    @Test func prefersCallIdOverItemId() throws {
        let json = """
        {
          "id": "resp_fc",
          "output": [
            {
              "type": "function_call",
              "id": "fc_1",
              "call_id": "call_1",
              "name": "fetchWeather",
              "arguments": "{}"
            }
          ]
        }
        """
        let parsed = try XAIResponseTranslator.parse(body: Data(json.utf8))
        #expect(parsed.toolCalls.count == 1)
        #expect(parsed.toolCalls[0].id == "call_1")
    }
}