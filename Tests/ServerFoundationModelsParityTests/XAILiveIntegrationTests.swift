import Foundation
@testable import ServerFoundationModels
import Testing

/// Live xAI integration — gated on `XAI_API_KEY`. Verifies grok-4.3 threading
/// (`previous_response_id`) and prompt-cache hits (`cached_tokens`).
@Suite(.serialized)
struct XAILiveIntegrationTests {
    private static func apiKey() -> String? {
        ProcessInfo.processInfo.environment["XAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    @Test(.enabled(if: Self.apiKey() != nil, "Set XAI_API_KEY to run live xAI tests"))
    func grok43ChainingAndCaching() async throws {
        let key = try #require(Self.apiKey())
        let state = XAIConversationState()
        let model = XAILanguageModel(
            name: .grok4_3,
            auth: .apiKey(key),
            conversationState: state,
            timeout: 120
        )

        // Turn 1 — fresh conversation, seeds prompt-cache prefix.
        let session = LanguageModelSession(
            model: model,
            instructions: "Reply in one short sentence. No markdown."
        )
        let first = try await session.respond(to: "What is 2+2? Answer with just the number.")
        #expect(!first.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let firstUsage = first.usage
        print("[xai-live] turn1 input=\(firstUsage.input.totalTokenCount) cached=\(firstUsage.input.cachedTokenCount) output=\(firstUsage.output.totalTokenCount)")

        // Turn 2 — should thread via previous_response_id; prefix should hit prompt cache.
        let second = try await session.respond(to: "Now multiply that result by 3. Answer with just the number.")
        #expect(!second.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let secondUsage = second.usage
        print("[xai-live] turn2 input=\(secondUsage.input.totalTokenCount) cached=\(secondUsage.input.cachedTokenCount) output=\(secondUsage.output.totalTokenCount) text=\(second.content.prefix(80))")

        // Turn1→4; chained turn2 should be 4×3=12.
        #expect(second.content.contains("12"), "expected chained 4×3=12, got: \(second.content)")

        #expect(
            secondUsage.input.cachedTokenCount > 0,
            "expected prompt_cache_key hit on turn 2, got cached=\(secondUsage.input.cachedTokenCount)"
        )

        let modeBeforeTurn2 = state.threadingMode(model: .grok4_3)
        if case .threaded = modeBeforeTurn2 { } else {
            Issue.record("expected threaded mode before turn 2, got \(modeBeforeTurn2)")
        }

        let third = try await session.respond(to: "Add 10 to your last answer. Reply with just the number.")
        let thirdUsage = third.usage
        print("[xai-live] turn3 input=\(thirdUsage.input.totalTokenCount) cached=\(thirdUsage.input.cachedTokenCount) output=\(thirdUsage.output.totalTokenCount) text=\(third.content.prefix(80))")

        #expect(third.content.contains("22"), "expected chained 12+10=22, got: \(third.content)")
        #expect(
            thirdUsage.input.cachedTokenCount > 0,
            "expected prompt cache on turn 3, got cached=\(thirdUsage.input.cachedTokenCount)"
        )
    }

    @Test(.enabled(if: Self.apiKey() != nil, "Set XAI_API_KEY to run live xAI tests"))
    func grok43ServerToolSegmentCoverage() async throws {
        let key = try #require(Self.apiKey())
        let state = XAIConversationState()
        let model = XAILanguageModel(
            name: .grok4_3,
            auth: .apiKey(key),
            conversationState: state,
            serverTools: XAIServerToolsValidationScenario.serverTools,
            timeout: XAIServerToolsValidationScenario.timeout
        )
        let session = LanguageModelSession(
            model: model,
            instructions: XAIServerToolsValidationScenario.instructions
        )

        var lastText = ""
        for prompt in XAIServerToolsValidationScenario.prompts {
            let response = try await session.respond(to: prompt)
            lastText = response.content
        }
        let inventory = XAIServerToolSegmentCollector.inventory(
            transcript: session.transcript,
            responseText: lastText
        )

        print("[xai-live] inventory: webSearch=\(inventory.webSearchCount) xSearch=\(inventory.xSearchCount) open_page=\(inventory.webFetchCount) citations=\(inventory.citationCount)")
        for segment in XAIServerToolSegmentCollector.segments(in: session.transcript) {
            print("[xai-live]  \(XAIServerToolSegmentCollector.describe(segment))")
        }

        let coverageSummary = inventory.failureSummary ?? "strict segment coverage failed"
        #expect(inventory.isStrictPass, "\(coverageSummary)")
    }
}