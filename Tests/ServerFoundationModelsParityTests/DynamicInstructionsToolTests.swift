// Regression: tools declared inside a DynamicInstructions body must register
// with the session — a resolver that collects only instruction texts ships
// sessions whose models silently never see a tool.

import Foundation
import Testing
import ServerFoundationModels

private struct ProbeTool: Tool {
    let recorder: BehaviorRecorder

    let name = "probe"
    let description = "Records that it was called and returns a fixed value."

    @Generable
    struct Arguments {
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        recorder.record(arguments.query)
        return "probe result for \(arguments.query)"
    }
}

private struct ProbeBriefing: DynamicInstructions {
    let recorder: BehaviorRecorder

    var body: some DynamicInstructions {
        Instructions { "You verify things with the probe tool." }
        ProbeTool(recorder: recorder)
    }
}

@Test func dynamicInstructionsBodyToolsReachTheModelAndExecute() async throws {
    let recorder = BehaviorRecorder()
    let script = ScriptBox(rounds: [
        ScriptedRound(toolCalls: [
            ScriptedToolCall(id: "c1", name: "probe", argumentsJSON: #"{"query":"runway"}"#)
        ]),
        ScriptedRound(textFragments: ["verified"]),
    ])
    let session = LanguageModelSession(
        model: ScriptedModel(script: script),
        dynamicInstructions: ProbeBriefing(recorder: recorder)
    )

    let response = try await session.respond(to: "check the runway claim")

    // The request advertised the body-declared tool…
    let first = script.recordedRequests.first
    #expect(first?.enabledToolDefinitions.map(\.name) == ["probe"])
    // …the session executed it when the model called it…
    #expect(recorder.all == ["runway"])
    // …and the loop completed on the follow-up round.
    #expect(response.content == "verified")
}
