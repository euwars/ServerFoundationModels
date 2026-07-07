import Foundation
import ServerFoundationModelsTimeline
import Testing
import ServerFoundationModels

// The shared timeline accumulates across parallel tests — filter by names
// unique to each test instead of resetting.

@Test func chatCompletionsRequestsAreTimed() async throws {
    let server = try CaptureServer()
    defer { server.stop() }
    let model = ChatCompletionsLanguageModel(
        name: "timeline-wire-model",
        url: URL(string: "http://127.0.0.1:\(server.port)")!
    )
    let session = LanguageModelSession(model: model)
    _ = try await session.respond(to: "hello")

    let timings = await RequestTimeline.shared.snapshot().requests
        .filter { $0.model == "timeline-wire-model" }
    let timing = try #require(timings.first)
    #expect(timing.succeeded)
    #expect(timing.total > .zero)
    #expect(timing.firstToken >= timing.connect)
    #expect(timing.total >= timing.firstToken)
    #expect(timing.gateWait >= .zero)
}

private struct SlowProbe: Tool {
    let name = "timelineSlowProbe"
    let description = "Sleeps briefly, then answers."

    @Generable
    struct Arguments {
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await Task.sleep(for: .milliseconds(30))
        return "done"
    }
}

private struct SlowProbeBriefing: DynamicInstructions {
    var body: some DynamicInstructions {
        Instructions { "Use the probe." }
        SlowProbe()
    }
}

@Test func toolRunsAreTimed() async throws {
    let script = ScriptBox(rounds: [
        ScriptedRound(toolCalls: [
            ScriptedToolCall(id: "c1", name: "timelineSlowProbe", argumentsJSON: #"{"query":"x"}"#)
        ]),
        ScriptedRound(textFragments: ["answered"]),
    ])
    let session = LanguageModelSession(
        model: ScriptedModel(script: script),
        dynamicInstructions: SlowProbeBriefing()
    )
    _ = try await session.respond(to: "go")

    let runs = await RequestTimeline.shared.snapshot().toolRuns
        .filter { $0.tool == "timelineSlowProbe" }
    let run = try #require(runs.first)
    #expect(run.duration >= .milliseconds(25))
}

private struct ExcerptProbe: Tool {
    let name = "excerptProbe"
    let description = "Probe for excerpt capture."

    @Generable
    struct Arguments {
        var claim: String
    }

    struct Halt: Error {}
    func call(arguments: Arguments) async throws -> String { throw Halt() }
}

private struct ExcerptBriefing: DynamicInstructions {
    var body: some DynamicInstructions {
        Instructions { "Verify claims." }
        ExcerptProbe()
    }
}

@Test func toolCallRoundsAppearInTheResponseExcerpt() async throws {
    let sse = "data: " +
        #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"excerptProbe","arguments":"{\"claim\":\"runway\"}"}}]}}]}"# +
        "\n\ndata: [DONE]\n\n"
    let server = try CaptureServer(body: sse)
    defer { server.stop() }
    let session = LanguageModelSession(
        model: ChatCompletionsLanguageModel(
            name: "excerpt-wire-model",
            url: URL(string: "http://127.0.0.1:\(server.port)")!
        ),
        dynamicInstructions: ExcerptBriefing()
    )
    _ = try? await session.respond(to: "check the runway claim")

    let timings = await RequestTimeline.shared.snapshot().requests
        .filter { $0.model == "excerpt-wire-model" }
    let timing = try #require(timings.first)
    // The round's answer was a tool call, not text — the excerpt says so.
    #expect(timing.responseExcerpt.contains("→ excerptProbe"))
    #expect(timing.responseExcerpt.contains("runway"))
}

@Test func measuredToolRunsOutsideSessionsAreRecorded() async throws {
    let result = try await RequestTimeline.shared.measureToolRun(
        "mechanicalProbe", input: "https://example.com/terms", output: { $0 }
    ) {
        try await Task.sleep(for: .milliseconds(15))
        return "legal entity: Example Pvt Ltd"
    }
    #expect(result == "legal entity: Example Pvt Ltd")
    let runs = await RequestTimeline.shared.snapshot().toolRuns
        .filter { $0.tool == "mechanicalProbe" }
    let run = try #require(runs.first)
    #expect(run.duration >= .milliseconds(10))
    #expect(run.input == "https://example.com/terms")
    #expect(run.output.contains("Example Pvt Ltd"))
}

@Test func timelineReportProducesASelfContainedPage() async throws {
    _ = try await RequestTimeline.shared.measureToolRun(
        "reportProbe", input: "in", output: { $0 }
    ) { "out" }
    let html = try await ServerFoundationModelsTimeline.TimelineReport.html(label: "report-test-run")
    #expect(html.contains("report-test-run"))
    #expect(html.contains("reportProbe"))
    #expect(!html.contains("TIMELINE_DATA"))  // placeholder replaced with data
}
