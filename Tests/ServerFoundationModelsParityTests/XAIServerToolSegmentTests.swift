import Foundation
import ServerFoundationModels
import Testing

@Suite struct XAIServerToolSegmentTests {
    @Test func segmentsExposeToolName() {
        #expect(
            XAIServerToolSegment(id: "s", content: .webSearch(.init(query: "q"))).toolName == "web_search"
        )
        #expect(
            XAIServerToolSegment(id: "s", content: .xSearch(.init(query: "q"))).toolName == "x_search"
        )
        #expect(
            XAIServerToolSegment(
                id: "s",
                content: .webFetch(.init(url: URL(string: "https://example.com")!))
            ).toolName == "open_page"
        )
    }

    @Test func descriptionReflectsSearchAndFetch() {
        let search = XAIServerToolSegment(
            id: "ws",
            content: .webSearch(
                .init(
                    query: "weather",
                    status: "completed",
                    outcome: .init(hits: [.init(url: URL(string: "https://weather.gov")!, title: "NWS")])
                )
            )
        )
        #expect(search.description.contains("weather"))
        #expect(search.description.contains("weather.gov"))

        let fetch = XAIServerToolSegment(
            id: "pg",
            content: .webFetch(.init(url: URL(string: "https://example.com/page")!))
        )
        #expect(fetch.description.contains("open_page"))
        #expect(fetch.description.contains("example.com/page"))
    }
}