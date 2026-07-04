// WebCitationSegment — provider-agnostic web citations surfaced in the
// transcript as a custom segment. Used by ChatCompletionsLanguageModel to carry
// `url_citation` annotations (e.g. from OpenRouter's `openrouter:web_search`
// server tool) back to callers, mirroring how XAIServerToolSegment carries xAI
// search results.

import Foundation

public struct WebCitationSegment: Transcript.CustomSegment, Equatable {
    public let id: String
    public let content: Content

    public struct Content: Sendable, Equatable, Codable {
        public var citations: [Citation]
        public init(citations: [Citation] = []) { self.citations = citations }
    }

    public struct Citation: Sendable, Equatable, Codable {
        public var url: URL
        public var title: String?
        public var startIndex: Int?
        public var endIndex: Int?

        public init(url: URL, title: String? = nil, startIndex: Int? = nil, endIndex: Int? = nil) {
            self.url = url
            self.title = title
            self.startIndex = startIndex
            self.endIndex = endIndex
        }
    }

    public init(id: String, citations: [Citation]) {
        self.id = id
        self.content = Content(citations: citations)
    }

    public var description: String {
        let urls = content.citations.map(\.url.absoluteString).joined(separator: ", ")
        return "[web citations] \(urls)"
    }

    public var promptRepresentation: Prompt { Prompt(description) }
    public var instructionsRepresentation: Instructions { Instructions(description) }
}

/// Reads web citations out of a transcript, regardless of which model produced
/// them. Mirrors `XAIServerToolSegmentCollector`.
public enum WebCitationCollector {
    public static func segments(in transcript: Transcript) -> [WebCitationSegment] {
        var collected: [WebCitationSegment] = []
        for entry in transcript {
            guard case .response(let response) = entry else { continue }
            for segment in response.segments {
                if case .custom(let custom) = segment, let citation = custom as? WebCitationSegment {
                    collected.append(citation)
                }
            }
        }
        return collected
    }

    /// The de-duplicated citation URLs, in first-seen order.
    public static func urls(in transcript: Transcript) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for segment in segments(in: transcript) {
            for citation in segment.content.citations {
                let url = citation.url.absoluteString
                if seen.insert(url).inserted { out.append(url) }
            }
        }
        return out
    }
}
