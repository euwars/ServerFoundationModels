import Foundation
@testable import ServerFoundationModels
import Testing

@Suite struct XAIServerToolWireTests {
    @Test func orderedEventsPreserveOutputOrder() throws {
        let json = """
        {
          "id": "resp_search",
          "output": [
            {
              "type": "web_search_call",
              "id": "ws_1",
              "status": "completed",
              "action": {"type": "search", "query": "Swift concurrency"}
            },
            {
              "type": "web_search_call",
              "id": "ws_2",
              "status": "completed",
              "action": {"type": "open_page", "url": "https://swift.org"}
            },
            {
              "type": "message",
              "role": "assistant",
              "content": [
                {
                  "type": "output_text",
                  "text": "Swift has structured concurrency.",
                  "annotations": [
                    {"type": "url_citation", "url": "https://swift.org", "title": "Swift.org"}
                  ]
                }
              ]
            }
          ],
          "citations": ["https://swift.org"]
        }
        """
        let parsed = try XAIResponseTranslator.parse(body: Data(json.utf8))
        #expect(parsed.text == "Swift has structured concurrency.")
        #expect(parsed.orderedEvents.count == 3)

        guard case .customSegment(let first) = parsed.orderedEvents[0].kind,
            case .webSearch(let search) = first.content
        else {
            Issue.record("expected web search segment first")
            return
        }
        #expect(search.query == "Swift concurrency")
        #expect(search.outcome != nil)

        guard case .customSegment(let second) = parsed.orderedEvents[1].kind,
            case .webFetch(let fetch) = second.content
        else {
            Issue.record("expected web fetch segment second")
            return
        }
        #expect(fetch.url == URL(string: "https://swift.org"))

        guard case .appendText(let text) = parsed.orderedEvents[2].kind else {
            Issue.record("expected assistant text third")
            return
        }
        #expect(text == "Swift has structured concurrency.")

        guard case .customSegment(let mergedSearch) = parsed.orderedEvents[0].kind,
            case .webSearch(let merged) = mergedSearch.content,
            let outcome = merged.outcome
        else {
            Issue.record("expected completed search with citations")
            return
        }
        #expect(outcome.citations.count == 1)
        #expect(outcome.citations[0].url == URL(string: "https://swift.org"))
        #expect(outcome.citations[0].title == "Swift.org")
    }

    @Test func topLevelAllCitationsMergeIntoSearchSegment() throws {
        let json = """
        {
          "id": "resp_all_cites",
          "output": [
            {
              "type": "web_search_call",
              "id": "ws_1",
              "status": "completed",
              "action": {"type": "search", "query": "What is xAI?"}
            },
            {
              "type": "message",
              "content": [{"type": "output_text", "text": "xAI is an AI company."}]
            }
          ],
          "citations": [
            "https://x.com/i/user/1912644073896206336",
            "https://x.ai/news",
            "https://docs.x.ai/developers/release-notes"
          ]
        }
        """
        let parsed = try XAIResponseTranslator.parse(body: Data(json.utf8))
        guard case .customSegment(let segment) = parsed.orderedEvents[0].kind,
            case .webSearch(let search) = segment.content,
            let outcome = search.outcome
        else {
            Issue.record("expected web search segment with outcome")
            return
        }
        #expect(outcome.citations.count == 3)
        #expect(outcome.citations.contains { $0.url.absoluteString == "https://x.ai/news" })
    }

    @Test func inlineAnnotationsPreservePositionIndices() throws {
        let json = """
        {
          "id": "resp_inline",
          "output": [
            {
              "type": "web_search_call",
              "id": "ws_1",
              "status": "completed",
              "action": {"type": "search", "query": "What is xAI?"}
            },
            {
              "type": "message",
              "content": [
                {
                  "type": "output_text",
                  "text": "xAI is an AI company.[[1]](https://x.ai/company)",
                  "annotations": [
                    {
                      "type": "url_citation",
                      "url": "https://x.ai/company",
                      "start_index": 20,
                      "end_index": 47,
                      "title": "1"
                    }
                  ]
                }
              ]
            }
          ]
        }
        """
        let parsed = try XAIResponseTranslator.parse(body: Data(json.utf8))
        guard case .customSegment(let segment) = parsed.orderedEvents[0].kind,
            case .webSearch(let search) = segment.content,
            let citation = search.outcome?.citations.first
        else {
            Issue.record("expected inline citation on search segment")
            return
        }
        #expect(citation.url == URL(string: "https://x.ai/company"))
        #expect(citation.title == "1")
        #expect(citation.startIndex == 20)
        #expect(citation.endIndex == 47)
    }

    @Test func customToolCallMapsXSearch() throws {
        let json = """
        {
          "id": "resp_x",
          "output": [
            {
              "type": "custom_tool_call",
              "id": "ctc_1",
              "name": "x_semantic_search",
              "status": "completed",
              "input": "{\\"query\\":\\"xAI\\",\\"limit\\":\\"10\\"}"
            },
            {
              "type": "message",
              "content": [{"type": "output_text", "text": "People on X are excited."}]
            }
          ]
        }
        """
        let parsed = try XAIResponseTranslator.parse(body: Data(json.utf8))
        guard case .customSegment(let segment) = parsed.orderedEvents[0].kind,
            case .xSearch(let search) = segment.content
        else {
            Issue.record("expected xSearch custom_tool_call segment")
            return
        }
        #expect(search.query == "xAI")
        #expect(search.status == "completed")
    }
}