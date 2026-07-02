import Foundation
import ServerFoundationModels
import Testing

@Suite struct XAIServerToolsValidationTests {
    @Test func strictPassRequiresEachSegmentKind() {
        #expect(XAIServerToolSegmentInventory(
            webSearchCount: 1, xSearchCount: 1, webFetchCount: 1, citationCount: 1, hasResponseText: true
        ).isStrictPass)

        let missingX = XAIServerToolSegmentInventory(
            webSearchCount: 1, xSearchCount: 0, webFetchCount: 1, citationCount: 1, hasResponseText: true
        )
        #expect(!missingX.isStrictPass)
        #expect(missingX.missingSegmentKinds.contains("xSearch segment"))

        let missingCitations = XAIServerToolSegmentInventory(
            webSearchCount: 1, xSearchCount: 1, webFetchCount: 1, citationCount: 0, hasResponseText: true
        )
        #expect(!missingCitations.isStrictPass)
        #expect(missingCitations.missingSegmentKinds.contains(
            "citation (response.citations or inline annotation)"
        ))
    }

    @Test func inventoryCountsUniqueCitationURLs() {
        let citeA = XAIServerToolSegment.Citation(url: URL(string: "https://x.ai/news")!)
        let citeB = XAIServerToolSegment.Citation(url: URL(string: "https://x.com/xai")!)
        let outcome = XAIServerToolSegment.WebSearch.Outcome(citations: [citeA, citeB])
        let transcript = Transcript(entries: [
            .response(.init(segments: [
                .custom(XAIServerToolSegment(
                    id: "ws",
                    content: .webSearch(.init(query: "xAI", status: "completed", outcome: outcome))
                )),
                .custom(XAIServerToolSegment(
                    id: "xs",
                    content: .xSearch(.init(query: "xAI on X", status: "completed", outcome: outcome))
                )),
                .text(.init(content: "answer")),
            ])),
        ])
        let inventory = XAIServerToolSegmentCollector.inventory(transcript: transcript)
        #expect(inventory.webSearchCount == 1)
        #expect(inventory.xSearchCount == 1)
        #expect(inventory.citationCount == 2)
        #expect(inventory.isStrictPass == false)
    }
}