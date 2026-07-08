import Foundation
import Testing
@testable import ServerFoundationModels
import ServerFoundationModelsTimeline

@Suite struct TimelineReviewTests {
    func req(_ start: Double, _ total: Double, session: String = "team", gate: Double = 0, ok: Bool = true) -> ModelRequestTiming {
        ModelRequestTiming(
            model: "m", session: session, start: .seconds(start), gateWait: .seconds(gate),
            connect: .seconds(total * 0.1), firstToken: .seconds(total * 0.6), total: .seconds(total),
            succeeded: ok, promptExcerpt: "", responseExcerpt: "", inputTokens: 1000, outputTokens: 50
        )
    }
    func tool(_ start: Double, _ dur: Double, output: String) -> ToolRunTiming {
        ToolRunTiming(tool: "fetchWebpage", session: "team", start: .seconds(start), duration: .seconds(dur), input: "https://x", output: output)
    }

    @Test func flagsIdleGapAndDeadEndTools() {
        // Two requests with a 20s idle gap; a blocked-host tool run in between.
        let requests = [req(0, 5), req(25, 5)]
        let tools = [tool(6, 3, output: "www.crunchbase.com blocks automated access — do not retry")]
        let items = TimelineReview.analyze(requests: requests, tools: tools, marks: [])
        #expect(items.contains { $0.title.contains("Idle gaps") })
        #expect(items.contains { $0.title.contains("Wasted tool runs") })
        // Ranked by impact: the 20s idle gap outweighs the 3s dead end.
        #expect(items.first?.title.contains("Idle gaps") == true)
    }

    @Test func flagsFrontLoadAndStraggler() {
        // 40s of single-threaded work before the "pillars started" mark, then
        // a market session that runs 30s longer than its siblings.
        let requests = [
            req(0, 40, session: "identity"),
            req(41, 10, session: "team"), req(41, 10, session: "deal"),
            req(41, 40, session: "market"),
        ]
        let marks = [TimelineMark(label: "pillars started", at: .seconds(41))]
        let items = TimelineReview.analyze(requests: requests, tools: [], marks: marks)
        #expect(items.contains { $0.title.contains("front-load") })
        #expect(items.contains { $0.title.contains("Straggler") && $0.detail.contains("market") })
    }

    @Test func cleanRunHasNoFindings() {
        // Densely packed, no gaps, no dead ends, balanced sessions.
        let requests = [req(0, 5, session: "a"), req(0, 5, session: "b"), req(5, 5, session: "a"), req(5, 5, session: "b")]
        let items = TimelineReview.analyze(requests: requests, tools: [], marks: [])
        #expect(items.allSatisfy { !$0.title.contains("Idle") && !$0.title.contains("front-load") })
    }
}
