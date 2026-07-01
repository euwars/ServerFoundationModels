import Foundation
import ServerFoundationModels

enum XAILiveProbeFailure: Error, CustomStringConvertible {
    case missingAPIKey
    case verificationFailed

    var description: String {
        switch self {
        case .missingAPIKey: "XAI_API_KEY is required"
        case .verificationFailed: "RESULT: FAIL"
        }
    }
}

@main
struct XAILiveProbe {
    static func main() async throws {
        guard let key = ProcessInfo.processInfo.environment["XAI_API_KEY"], !key.isEmpty else {
            throw XAILiveProbeFailure.missingAPIKey
        }

        let state = XAIConversationState()
        let model = XAILanguageModel(
            name: .grok4_3,
            auth: .apiKey(key),
            conversationState: state,
            timeout: 120
        )
        let session = LanguageModelSession(
            model: model,
            instructions: "Reply in one short sentence. No markdown."
        )

        print("=== xAI live probe: grok-4.3-latest chaining + prompt cache ===")

        let first = try await session.respond(to: "What is 2+2? Answer with just the number.")
        print("turn1 text: \(first.content.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("turn1 usage: input=\(first.usage.input.totalTokenCount) cached=\(first.usage.input.cachedTokenCount) output=\(first.usage.output.totalTokenCount)")

        let modeBeforeTurn2 = state.threadingMode(model: .grok4_3)
        print("mode before turn2: \(describe(modeBeforeTurn2))")

        let second = try await session.respond(to: "Now multiply that result by 3. Answer with just the number.")
        print("turn2 text: \(second.content.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("turn2 usage: input=\(second.usage.input.totalTokenCount) cached=\(second.usage.input.cachedTokenCount) output=\(second.usage.output.totalTokenCount)")

        let secondHasTwelve = second.content.contains("12")
        let secondCached = second.usage.input.cachedTokenCount > 0
        let secondThreaded = if case .threaded = modeBeforeTurn2 { true } else { false }
        print("turn2 chaining math ok (4×3=12): \(secondHasTwelve)")
        print("turn2 prompt cache hit (cached_tokens > 0): \(secondCached)")
        print("turn2 used previous_response_id: \(secondThreaded)")

        let third = try await session.respond(to: "Add 10 to your last answer. Reply with just the number.")
        print("turn3 text: \(third.content.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("turn3 usage: input=\(third.usage.input.totalTokenCount) cached=\(third.usage.input.cachedTokenCount) output=\(third.usage.output.totalTokenCount)")

        let thirdHasTwentyTwo = third.content.contains("22")
        let thirdCached = third.usage.input.cachedTokenCount > 0
        print("turn3 chaining math ok (12+10=22): \(thirdHasTwentyTwo)")
        print("turn3 prompt cache hit (cached_tokens > 0): \(thirdCached)")

        let ok = secondHasTwelve && secondCached && secondThreaded
            && thirdHasTwentyTwo && thirdCached
        if ok {
            print("RESULT: PASS — grok-4.3 chaining and prompt caching verified")
        } else {
            print("RESULT: FAIL")
            throw XAILiveProbeFailure.verificationFailed
        }
    }

    static func describe(_ mode: XAIConversationState.ThreadingMode) -> String {
        switch mode {
        case .fresh: "fresh"
        case .threaded(let id): "threaded(\(id))"
        case .inline: "inline"
        }
    }
}