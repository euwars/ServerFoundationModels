import Foundation
@testable import ServerFoundationModels
import Testing

@Suite struct XAIInlineInputTests {
    @Test func inlineInputWalksChainFully() throws {
        let thinkOutput: [[String: Any]] = [
            ["type": "message", "role": "assistant", "id": "msg_think",
             "content": [["type": "output_text", "text": "{\"gaps\":[]}"]]],
        ]
        let resolveOutput: [[String: Any]] = [
            ["type": "web_search_call", "id": "ws_a", "status": "completed",
             "action": ["type": "search", "query": "foo"]],
            ["type": "message", "role": "assistant", "id": "msg_resolve",
             "content": [["type": "output_text", "text": "no results"]]],
        ]

        let think = XAIConversationState.StoredTurn(
            prompt: "synthesize signals",
            rawOutput: try JSONSerialization.data(withJSONObject: thinkOutput),
            outputText: "ignored",
            modelId: "grok-4.3-latest"
        )
        let resolve = XAIConversationState.StoredTurn(
            prompt: "close gaps via search",
            rawOutput: try JSONSerialization.data(withJSONObject: resolveOutput),
            outputText: "ignored",
            modelId: "grok-4.3-latest"
        )

        let inlineInput = try XAIInputBuilder.buildInlineInput(
            chain: [think, resolve],
            newUserPrompt: "produce scorecard"
        )
        let arr = try JSONSerialization.jsonObject(with: inlineInput) as? [[String: Any]]
        #expect(arr?.count == 6)

        let first = arr?[0]
        #expect(first?["role"] as? String == "user")
        let firstContent = (first?["content"] as? [[String: Any]])?.first
        #expect(firstContent?["text"] as? String == "synthesize signals")

        let last = arr?.last
        #expect(last?["role"] as? String == "user")
        let lastContent = (last?["content"] as? [[String: Any]])?.first
        #expect(lastContent?["text"] as? String == "produce scorecard")
    }

    @Test func emptyAssistantMessageGetsPlaceholderContent() throws {
        let output: [[String: Any]] = [
            ["type": "message", "role": "assistant", "id": "msg_empty", "content": []],
        ]
        let turn = XAIConversationState.StoredTurn(
            prompt: "ask",
            rawOutput: try JSONSerialization.data(withJSONObject: output),
            outputText: "",
            modelId: "grok-4.3-latest"
        )
        let inlineInput = try XAIInputBuilder.buildInlineInput(chain: [turn], newUserPrompt: "next")
        let arr = try JSONSerialization.jsonObject(with: inlineInput) as? [[String: Any]]
        let assistant = arr?.first { ($0["role"] as? String) == "assistant" }
        let content = assistant?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == " ")
    }

    @Test func reasoningWithoutEncryptedContentIsSkipped() throws {
        let output: [[String: Any]] = [
            ["type": "reasoning", "id": "r1"],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "ok"]]],
        ]
        let turn = XAIConversationState.StoredTurn(
            prompt: "ask",
            rawOutput: try JSONSerialization.data(withJSONObject: output),
            outputText: "ok",
            modelId: "grok-4.3-latest"
        )
        let inlineInput = try XAIInputBuilder.buildInlineInput(chain: [turn], newUserPrompt: "next")
        let arr = try JSONSerialization.jsonObject(with: inlineInput) as? [[String: Any]]
        let types = arr?.compactMap { $0["type"] as? String } ?? []
        #expect(!types.contains("reasoning"))
    }

    @Test func anyToJSONNodePreservesZeroOneAndBool() {
        let dict: [String: Any] = ["start_index": 0, "flag": true, "count": 1]
        let node = anyToJSONNode(dict)
        guard case .object(let members) = node else {
            Issue.record("expected object node")
            return
        }
        let byKey = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value) })
        if case .integer(let value) = byKey["start_index"] {
            #expect(value == 0)
        } else {
            Issue.record("start_index should be .integer(0)")
        }
        if case .bool(let value) = byKey["flag"] {
            #expect(value == true)
        } else {
            Issue.record("flag should be .boolean(true)")
        }
        if case .integer(let value) = byKey["count"] {
            #expect(value == 1)
        } else {
            Issue.record("count should be .integer(1)")
        }
    }
}