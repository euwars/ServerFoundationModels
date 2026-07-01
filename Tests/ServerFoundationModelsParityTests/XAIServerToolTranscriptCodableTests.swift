import Foundation
import ServerFoundationModels
import Testing

@Suite struct XAIServerToolTranscriptCodableTests {
    @Test func xaiServerToolSegmentRoundTripsThroughTranscriptJSON() throws {
        let segment = XAIServerToolSegment(
            id: "ws_codable",
            content: .webSearch(.init(
                query: "Swift concurrency",
                status: "completed",
                outcome: .init(
                    hits: [.init(url: URL(string: "https://swift.org")!)],
                    citations: [.init(url: URL(string: "https://swift.org")!, title: "1")]
                )
            ))
        )
        let transcript = Transcript(entries: [
            .response(.init(segments: [.custom(segment)])),
        ])

        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)

        guard case .response(let response) = decoded.first,
            case .custom(let custom) = response.segments.first,
            let activity = custom as? XAIServerToolSegment,
            case .webSearch(let search) = activity.content,
            let outcome = search.outcome
        else {
            Issue.record("expected round-tripped XAIServerToolSegment")
            return
        }

        #expect(activity.id == "ws_codable")
        #expect(search.query == "Swift concurrency")
        #expect(outcome.hits.count == 1)
        #expect(outcome.citations.count == 1)
    }
}