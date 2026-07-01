// xAI server-side tool activity (web search, X search, page opens) surfaced
// in the transcript as custom segments — the Apple Beta 2 pattern for
// server-side LanguageModel providers.

import Foundation

/// One server-side tool round-trip from the xAI Responses API.
///
/// Segments appear when the model invokes a tool and are updated in place when
/// more detail arrives (e.g. citations merged after the assistant message).
///
/// ```swift
/// if case .custom(let custom) = segment,
///   let activity = custom as? XAIServerToolSegment
/// {
///   switch activity.content {
///   case .webSearch(let search):
///     showQuery(search.query)
///     if let hits = search.outcome?.hits { showHits(hits) }
///   default: break
///   }
/// }
/// ```
public struct XAIServerToolSegment: Transcript.CustomSegment, Equatable {
    public let id: String
    public let content: Content

    public enum Content: Sendable, Equatable, Codable {
        case webSearch(WebSearch)
        case xSearch(XSearch)
        case webFetch(WebFetch)
        /// A server tool or output item this package version doesn't model.
        /// Wire JSON is preserved for multi-turn inline replay.
        case unrecognized(UnrecognizedActivity)
    }

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }

    // MARK: - Web search

    public struct WebSearch: Sendable, Equatable, Codable {
        public var query: String
        /// xAI status, e.g. `completed` or `in_progress`.
        public var status: String?
        /// `nil` while the search is still in flight.
        public var outcome: Outcome?

        public init(query: String, status: String? = nil, outcome: Outcome? = nil) {
            self.query = query
            self.status = status
            self.outcome = outcome
        }

        public struct Outcome: Sendable, Equatable, Codable {
            public var hits: [Hit]
            public var citations: [Citation]

            public init(hits: [Hit] = [], citations: [Citation] = []) {
                self.hits = hits
                self.citations = citations
            }
        }

        public struct Hit: Sendable, Equatable, Codable {
            public var url: URL
            public var title: String?

            public init(url: URL, title: String? = nil) {
                self.url = url
                self.title = title
            }
        }
    }

    // MARK: - X search

    public struct XSearch: Sendable, Equatable, Codable {
        public var query: String
        public var status: String?
        public var outcome: WebSearch.Outcome?

        public init(query: String, status: String? = nil, outcome: WebSearch.Outcome? = nil) {
            self.query = query
            self.status = status
            self.outcome = outcome
        }
    }

    // MARK: - Page open (fetch)

    public struct WebFetch: Sendable, Equatable, Codable {
        public var url: URL
        public var status: String?

        public init(url: URL, status: String? = nil) {
            self.url = url
            self.status = status
        }
    }

    // MARK: - Citation

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

    // MARK: - Unrecognized

    public struct UnrecognizedActivity: Sendable, Equatable, Codable {
        public var itemType: String
        public var wireJSON: String

        public init(itemType: String, wireJSON: String) {
            self.itemType = itemType
            self.wireJSON = wireJSON
        }
    }

    public var toolName: String { content.wireToolName }

    public var description: String {
        switch content {
        case .webSearch(let search):
            let hits = search.outcome.map { $0.hits.map(\.url.absoluteString).joined(separator: ", ") } ?? ""
            if search.outcome == nil {
                return "[web_search \"\(search.query)\"] in progress"
            }
            return hits.isEmpty
                ? "[web_search \"\(search.query)\"] completed"
                : "[web_search \"\(search.query)\"] \(hits)"
        case .xSearch(let search):
            let hits = search.outcome.map { $0.hits.map(\.url.absoluteString).joined(separator: ", ") } ?? ""
            if search.outcome == nil {
                return "[x_search \"\(search.query)\"] in progress"
            }
            return hits.isEmpty
                ? "[x_search \"\(search.query)\"] completed"
                : "[x_search \"\(search.query)\"] \(hits)"
        case .webFetch(let fetch):
            return "[open_page \(fetch.url.absoluteString)]"
        case .unrecognized(let activity):
            return "[\(activity.itemType)] \(activity.wireJSON)"
        }
    }

    public var promptRepresentation: Prompt { Prompt(description) }
    public var instructionsRepresentation: Instructions { Instructions(description) }
}

extension XAIServerToolSegment.Content {
    var wireToolName: String {
        switch self {
        case .webSearch: "web_search"
        case .xSearch: "x_search"
        case .webFetch: "open_page"
        case .unrecognized(let activity): activity.itemType
        }
    }
}