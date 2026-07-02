import Foundation
import ServerFoundationModels

enum XAIServerToolsProbeFailure: Error, CustomStringConvertible {
    case missingAPIKey
    case verificationFailed(String)

    var description: String {
        switch self {
        case .missingAPIKey: "XAI_API_KEY is required"
        case .verificationFailed(let reason): "RESULT: FAIL — \(reason)"
        }
    }
}

@main
struct XAIServerToolsProbe {
    static func main() async throws {
        guard let key = ProcessInfo.processInfo.environment["XAI_API_KEY"], !key.isEmpty else {
            throw XAIServerToolsProbeFailure.missingAPIKey
        }

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

        print("=== xAI server-tools probe: strict segment coverage ===")
        print("tools: \(XAIServerToolsValidationScenario.serverTools.map(\.wireType).sorted().joined(separator: ", "))")
        print("prompts: \(XAIServerToolsValidationScenario.prompts.count) steps (xAI docs + open-page)")

        var lastText = ""
        for (step, prompt) in XAIServerToolsValidationScenario.prompts.enumerated() {
            print("\n--- step \(step + 1) ---")
            print("prompt: \(prompt.prefix(120))")
            let response = try await session.respond(to: prompt)
            lastText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            print("response: \(lastText.prefix(300))")
            print("usage: input=\(response.usage.input.totalTokenCount) output=\(response.usage.output.totalTokenCount)")
        }

        print("\ntranscript response segment layout:")
        for entry in session.transcript {
            guard case .response(let response) = entry else { continue }
            for (i, segment) in response.segments.enumerated() {
                switch segment {
                case .text(let textSegment):
                    print("  [\(i)] text: \(textSegment.content.prefix(120))")
                case .custom(let custom):
                    if let activity = custom as? XAIServerToolSegment {
                        print("  [\(i)] custom \(activity.toolName): \(XAIServerToolSegmentCollector.describe(activity))")
                    } else {
                        print("  [\(i)] custom (other): \(custom.description.prefix(120))")
                    }
                case .structure, .attachment:
                    print("  [\(i)] other segment")
                }
            }
        }

        let segments = XAIServerToolSegmentCollector.segments(in: session.transcript)
        let inventory = XAIServerToolSegmentCollector.inventory(
            transcript: session.transcript,
            responseText: lastText
        )
        print("inventory: webSearch=\(inventory.webSearchCount) xSearch=\(inventory.xSearchCount) open_page=\(inventory.webFetchCount) citations=\(inventory.citationCount) text=\(inventory.hasResponseText)")
        for segment in segments {
            print("  - \(XAIServerToolSegmentCollector.describe(segment))")
        }

        guard inventory.isStrictPass else {
            throw XAIServerToolsProbeFailure.verificationFailed(
                "missing: \(inventory.missingSegmentKinds.joined(separator: ", "))"
            )
        }

        print("RESULT: PASS — webSearch, xSearch, open_page, citations, and text all present")
    }
}