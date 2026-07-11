// R2-shaped parity tests: the session flows a real research pipeline depends
// on — multi-tool dynamic briefings, a two-phase investigate/extract turn
// (tools advertised but tool_choice "none" under a schema), history-carried
// session restarts, and nested model calls from inside a tool. Each of these
// works on Apple's framework; a regression here is a parity gap that unit
// tests of individual pieces don't catch (the dynamicInstructions-tools drop
// shipped a full pipeline run with zero tool calls while 204 tests passed).

import Foundation
import Testing
import ServerFoundationModels
import ServerFoundationModelsUtilities

private struct PipelineProbeTool: Tool {
    let recorder: BehaviorRecorder

    let name = "verifyClaim"
    let description = "Verifies one claim against sources."

    @Generable
    struct Arguments {
        var claim: String
    }

    func call(arguments: Arguments) async throws -> String {
        recorder.record(arguments.claim)
        return "evidence for \(arguments.claim)"
    }
}

/// A tool that runs its own model session before answering — the page
/// distiller pattern: fetch → side-session distills → tool output.
private struct NestingTool: Tool {
    let recorder: BehaviorRecorder
    let innerModel: ScriptedModel

    let name = "distillPage"
    let description = "Reads a page through a distiller model."

    @Generable
    struct Arguments {
        var url: String
    }

    func call(arguments: Arguments) async throws -> String {
        let side = LanguageModelSession(model: innerModel)
        let distilled = try await side.respond(to: "distill \(arguments.url)")
        recorder.record(distilled.content)
        return distilled.content
    }
}

private struct PillarBriefing: DynamicInstructions {
    let recorder: BehaviorRecorder

    var body: some DynamicInstructions {
        Instructions { "You are a research analyst on the deal pillar." }
        PipelineProbeTool(recorder: recorder)
    }
}

// MARK: - Wire shape of the extraction phase

@Test func extractionPhaseAdvertisesToolsButForbidsCallingThem() async throws {
    let server = try CaptureServer()
    defer { server.stop() }

    let model = ChatCompletionsLanguageModel(
        name: "wire-model",
        url: URL(string: "http://127.0.0.1:\(server.port)")!
    )
    let session = LanguageModelSession(
        model: model,
        dynamicInstructions: PillarBriefing(recorder: BehaviorRecorder())
    )
    _ = try await session.respond(
        to: "Report your findings as structured output.",
        generating: CraftIdea.self,
        options: GenerationOptions(
            samplingMode: .greedy,
            maximumResponseTokens: 16_384,
            toolCallingMode: .disallowed
        )
    )

    let body = try #require(server.lastBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

    // Tools declared in the DynamicInstructions body reach the wire…
    let tools = try #require(json["tools"] as? [[String: Any]], "briefing-declared tools must be advertised")
    let function = try #require(tools.first?["function"] as? [String: Any])
    #expect(function["name"] as? String == "verifyClaim")
    // …but the extraction phase forbids calling them, alongside the schema.
    #expect(json["tool_choice"] as? String == "none")
    #expect(json["response_format"] != nil)
    // The briefing prose is the system message.
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.first?["role"] as? String == "system")
    #expect(messageText(messages.first)?.contains("research analyst") == true)
}

// MARK: - History-carried restart

@Test func carriedHistoryPreservesToolOutputsAcrossSessions() async throws {
    let recorder = BehaviorRecorder()
    let firstScript = ScriptBox(rounds: [
        ScriptedRound(toolCalls: [
            ScriptedToolCall(id: "c1", name: "verifyClaim", argumentsJSON: #"{"claim":"runway"}"#)
        ]),
        ScriptedRound(textFragments: ["noted"]),
    ])
    let first = LanguageModelSession(
        model: ScriptedModel(script: firstScript),
        dynamicInstructions: PillarBriefing(recorder: recorder)
    )
    _ = try await first.respond(to: "research the runway claim")

    // The R2 restart: carry everything except instructions (the briefing
    // re-supplies them), hand the transcript to a fresh session.
    let carried = first.transcript.filter { entry in
        if case .instructions = entry { false } else { true }
    }
    let secondScript = ScriptBox(rounds: [ScriptedRound(textFragments: ["resumed"])])
    let second = LanguageModelSession(
        model: ScriptedModel(script: secondScript),
        dynamicInstructions: PillarBriefing(recorder: recorder),
        history: Transcript(entries: carried)
    )
    let response = try await second.respond(to: "continue the research")
    #expect(response.content == "resumed")

    // The fresh session's first request must still show the earlier tool
    // round — a restart that loses evidence once flipped a verdict.
    let request = try #require(secondScript.recordedRequests.first)
    let toolOutputs = request.transcript.compactMap { entry -> String? in
        if case .toolOutput(let output) = entry {
            return output.segments.compactMap { segment -> String? in
                if case .text(let text) = segment { return text.content }
                return nil
            }.joined()
        }
        return nil
    }
    #expect(toolOutputs == ["evidence for runway"])
}

// MARK: - Nested model call from inside a tool

@Test func toolsMayRunTheirOwnModelSessionsMidLoop() async throws {
    let recorder = BehaviorRecorder()
    let innerScript = ScriptBox(rounds: [ScriptedRound(textFragments: ["distilled: entity mismatch"])])
    let outerScript = ScriptBox(rounds: [
        ScriptedRound(toolCalls: [
            ScriptedToolCall(id: "c1", name: "distillPage", argumentsJSON: #"{"url":"https://example.com/terms"}"#)
        ]),
        ScriptedRound(textFragments: ["reported"]),
    ])

    struct NestingBriefing: DynamicInstructions {
        let tool: NestingTool
        var body: some DynamicInstructions {
            Instructions { "Fetch pages through the distiller." }
            tool
        }
    }
    let session = LanguageModelSession(
        model: ScriptedModel(script: outerScript),
        dynamicInstructions: NestingBriefing(
            tool: NestingTool(recorder: recorder, innerModel: ScriptedModel(script: innerScript))
        )
    )

    let response = try await session.respond(to: "check the legal pages")
    #expect(response.content == "reported")
    #expect(recorder.all == ["distilled: entity mismatch"])
    #expect(innerScript.recordedRequests.count == 1)
}

// MARK: - Schema prompt suppression flows through

@Test func includeSchemaInPromptFalseReachesTheExecutor() async throws {
    let script = ScriptBox(rounds: [
        ScriptedRound(textFragments: [#"{"title": "Crane", "category": "origami project"}"#])
    ])
    let session = LanguageModelSession(
        model: ScriptedModel(script: script),
        dynamicInstructions: PillarBriefing(recorder: BehaviorRecorder())
    )
    _ = try await session.respond(
        to: "Report findings.",
        generating: CraftIdea.self,
        includeSchemaInPrompt: false
    )
    let request = try #require(script.recordedRequests.first)
    #expect(request.contextOptions.includeSchemaInPrompt == false)
    #expect(request.schema != nil)
}

// MARK: - Batched tool calls run in parallel

private struct SleepyTool: Tool {
    let name = "sleepyProbe"
    let description = "Sleeps 200ms, then answers with its argument."

    @Generable
    struct Arguments {
        var tag: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await Task.sleep(for: .milliseconds(200))
        return "slept \(arguments.tag)"
    }
}

private struct SleepyBriefing: DynamicInstructions {
    var body: some DynamicInstructions {
        Instructions { "Batch your probes." }
        SleepyTool()
    }
}

@Test func batchedToolCallsInOneRoundRunConcurrently() async throws {
    let script = ScriptBox(rounds: [
        ScriptedRound(toolCalls: [
            ScriptedToolCall(id: "c1", name: "sleepyProbe", argumentsJSON: #"{"tag":"first"}"#),
            ScriptedToolCall(id: "c2", name: "sleepyProbe", argumentsJSON: #"{"tag":"second"}"#),
            ScriptedToolCall(id: "c3", name: "sleepyProbe", argumentsJSON: #"{"tag":"third"}"#),
        ]),
        ScriptedRound(textFragments: ["all probed"]),
    ])
    let session = LanguageModelSession(
        model: ScriptedModel(script: script),
        dynamicInstructions: SleepyBriefing()
    )

    let clock = ContinuousClock()
    let start = clock.now
    let response = try await session.respond(to: "probe everything")
    let elapsed = clock.now - start

    #expect(response.content == "all probed")
    // Three 200ms tools sequentially = 600ms+; concurrently ≈ 200ms.
    #expect(elapsed < .milliseconds(450), "batched tool calls must not serialize (took \(elapsed))")
    // Outputs land in call order regardless of completion order.
    let outputs = session.transcript.compactMap { entry -> String? in
        guard case .toolOutput(let output) = entry else { return nil }
        return output.segments.compactMap { segment -> String? in
            if case .text(let text) = segment { return text.content }
            return nil
        }.joined()
    }
    #expect(outputs == ["slept first", "slept second", "slept third"])
}

@Test func hallucinatedToolNameRecoversInsteadOfCrashing() async throws {
    // The model calls a tool that isn't registered, then answers normally.
    let script = ScriptBox(rounds: [
        ScriptedRound(toolCalls: [
            ScriptedToolCall(id: "c1", name: "notARealTool", argumentsJSON: #"{"x":1}"#)
        ]),
        ScriptedRound(textFragments: ["recovered"]),
    ])
    struct Briefing: DynamicInstructions {
        var body: some DynamicInstructions {
            Instructions { "Use the probe." }
            PipelineProbeTool(recorder: BehaviorRecorder())
        }
    }
    let session = LanguageModelSession(model: ScriptedModel(script: script), dynamicInstructions: Briefing())
    // Must NOT throw — the unknown tool is fed back and the loop continues.
    let response = try await session.respond(to: "go")
    #expect(response.content == "recovered")
    // The transcript carries the recovery message as the tool output.
    let outputs = session.transcript.compactMap { e -> String? in
        if case .toolOutput(let o) = e {
            return o.segments.compactMap { if case .text(let t) = $0 { return t.content }; return nil }.joined()
        }
        return nil
    }
    #expect(outputs.contains { $0.contains("no tool named 'notARealTool'") && $0.contains("verifyClaim") })
}
