import Foundation
@testable import ServerFoundationModels
import Testing

@Suite struct XAIWireFormatTests {
    @Test func emptyToolsAreOmittedFromWire() {
        let request = XAIResponsesRequest(
            model: "grok-4.3-latest",
            instructions: nil,
            inputItems: [XAIInputBuilder.userMessage(text: "scorecard prompt")],
            tools: [],
            previousResponseId: "resp_abc",
            promptCacheKey: "cache-key"
        )
        let wire = request.serialize()
        #expect(!wire.contains("\"tools\""))
    }

    @Test func nonEmptyToolsAreEncoded() {
        let request = XAIResponsesRequest(
            model: "grok-4.3-latest",
            instructions: nil,
            inputItems: [XAIInputBuilder.userMessage(text: "resolve prompt")],
            tools: [
                .object([.init(key: "type", value: .string("web_search"))]),
                .object([.init(key: "type", value: .string("x_search"))]),
            ],
            previousResponseId: "resp_abc"
        )
        let wire = request.serialize()
        #expect(wire.contains("\"tools\""))
        #expect(wire.contains("\"web_search\""))
        #expect(wire.contains("\"x_search\""))
    }

    @Test func userMessageUsesInputTextBlocks() {
        let message = XAIInputBuilder.userMessage(text: "hello")
        let wire = message.serialized
        #expect(wire.contains("\"input_text\""))
        #expect(wire.contains("\"hello\""))
        #expect(!wire.contains("\"content\":\"hello\""))
    }

    @Test func threadedRequestOmitsInstructionsWhenSetExternally() {
        var request = XAIResponsesRequest(
            model: "grok-4.3-latest",
            instructions: "system prompt",
            inputItems: [XAIInputBuilder.userMessage(text: "follow-up")],
            tools: [],
            previousResponseId: "resp_parent"
        )
        request.instructions = nil
        let wire = request.serialize()
        #expect(!wire.contains("\"instructions\""))
        #expect(wire.contains("\"previous_response_id\""))
    }

    @Test func storeAndPromptCacheKeyPresent() {
        let request = XAIResponsesRequest(
            model: "grok-4.3-latest",
            inputItems: [XAIInputBuilder.userMessage(text: "hi")],
            tools: [],
            promptCacheKey: "convo-uuid"
        )
        let wire = request.serialize()
        #expect(wire.contains("\"store\":true"))
        #expect(wire.contains("\"prompt_cache_key\":\"convo-uuid\""))
    }

    @Test func perRequestReasoningLevelReachesWire() throws {
        func wire(_ level: ContextOptions.ReasoningLevel) throws -> String {
            let request = LanguageModelExecutorGenerationRequest(
                id: UUID(),
                transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "hi"))]))]),
                enabledTools: [],
                generationOptions: GenerationOptions(),
                contextOptions: ContextOptions(reasoningLevel: level),
                metadata: [:]
            )
            return try XAIRequestBuilder.build(
                from: request, model: .grok4_3, serverTools: [], conversationState: XAIConversationState()
            ).request.serialize()
        }
        // Apple's per-request reasoning control maps onto xAI's effort field.
        #expect(try wire(.deep).contains("\"effort\":\"high\""))
        #expect(try wire(.light).contains("\"effort\":\"low\""))
        #expect(try wire(.moderate).contains("\"effort\":\"medium\""))
        #expect(try wire(.custom("medium")).contains("\"effort\":\"medium\""))
    }

    @Test func omitsMaxOutputTokensWhenUnset() throws {
        let request = LanguageModelExecutorGenerationRequest(
            transcript: Transcript(entries: [
                .prompt(.init(segments: [.text(.init(content: "hi"))]))
            ])
        )
        let built = try XAIRequestBuilder.build(
            from: request,
            model: .grok4_3,
            serverTools: [],
            conversationState: XAIConversationState()
        )
        let wire = built.request.serialize()
        #expect(!wire.contains("max_output_tokens"))
    }
}