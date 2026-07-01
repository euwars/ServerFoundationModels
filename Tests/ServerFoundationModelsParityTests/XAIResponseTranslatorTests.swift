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
    }
}