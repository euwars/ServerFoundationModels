// Shared live-validation scenario and strict segment inventory checks for xAI
// server-side tools (used by XAIServerToolsProbe and live integration tests).

import Foundation

public enum XAIServerToolsValidationScenario {
    /// Matches xAI docs overview quick-start: web_search + x_search together.
    /// https://docs.x.ai/developers/tools/overview
    public static let serverTools: Set<XAIServerTool> = [.webSearch, .xSearch]

    public static let timeout: TimeInterval = 240

    public static let instructions = """
        You are a concise research assistant.
        Use web_search for web facts, x_search for X/Twitter discourse, and open_page when given a URL.
        Cite sources with inline citations. No markdown except citation links.
        """

    /// Step 1 — xAI web-search doc example.
    /// https://docs.x.ai/developers/tools/web-search
    public static let webSearchPrompt = "What is xAI?"

    /// Step 2 — xAI x-search doc example.
    /// https://docs.x.ai/developers/tools/x-search
    public static let xSearchPrompt = "What are people saying about xAI on X?"

    /// Step 3 — PP open-page probe variant; forces browse/open_page output items.
    /// https://docs.x.ai/developers/tools/tool-usage-details (browse_page / open_page)
    public static let openPagePrompt = """
        Visit https://www.swift.org/about/ and summarize the opening paragraph in one sentence. Cite the URL.
        """

    public static let prompts: [String] = [webSearchPrompt, xSearchPrompt, openPagePrompt]
}

public struct XAIServerToolSegmentInventory: Sendable, Equatable {
    public var webSearchCount: Int
    public var xSearchCount: Int
    public var webFetchCount: Int
    public var citationCount: Int
    public var hasResponseText: Bool

    public init(
        webSearchCount: Int = 0,
        xSearchCount: Int = 0,
        webFetchCount: Int = 0,
        citationCount: Int = 0,
        hasResponseText: Bool = false
    ) {
        self.webSearchCount = webSearchCount
        self.xSearchCount = xSearchCount
        self.webFetchCount = webFetchCount
        self.citationCount = citationCount
        self.hasResponseText = hasResponseText
    }

    /// Live pass requires at least one custom segment of each tool kind plus
    /// citations and assistant text. Citations are sourced from xAI
    /// `response.citations` (all citations) and `output_text.annotations`
    /// (inline url_citation metadata) merged onto search segments.
    public var isStrictPass: Bool {
        webSearchCount >= 1
            && xSearchCount >= 1
            && webFetchCount >= 1
            && citationCount >= 1
            && hasResponseText
    }

    public var failureSummary: String? {
        guard !isStrictPass else { return nil }
        return "missing: \(missingSegmentKinds.joined(separator: ", "))"
    }

    /// Human-readable list of required segment kinds still absent.
    public var missingSegmentKinds: [String] {
        var missing: [String] = []
        if webSearchCount < 1 { missing.append("webSearch segment") }
        if xSearchCount < 1 { missing.append("xSearch segment") }
        if webFetchCount < 1 { missing.append("webFetch/open_page segment") }
        if citationCount < 1 { missing.append("citation (response.citations or inline annotation)") }
        if !hasResponseText { missing.append("response text segment") }
        return missing
    }
}

public enum XAIServerToolSegmentCollector {
    public static func segments(in transcript: Transcript) -> [XAIServerToolSegment] {
        var collected: [XAIServerToolSegment] = []
        for entry in transcript {
            guard case .response(let response) = entry else { continue }
            for segment in response.segments {
                if case .custom(let custom) = segment, let activity = custom as? XAIServerToolSegment {
                    collected.append(activity)
                }
            }
        }
        return collected
    }

    public static func inventory(
        transcript: Transcript,
        responseText: String = ""
    ) -> XAIServerToolSegmentInventory {
        let segments = segments(in: transcript)
        let hasText = transcript.contains { entry in
            guard case .response(let response) = entry else { return false }
            return response.segments.contains { segment in
                if case .text(let text) = segment {
                    return !text.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return false
            }
        } || !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var inventory = XAIServerToolSegmentInventory(hasResponseText: hasText)
        var uniqueCitationURLs = Set<String>()
        for segment in segments {
            switch segment.content {
            case .webSearch(let search):
                inventory.webSearchCount += 1
                collectCitations(from: search.outcome, into: &uniqueCitationURLs)
            case .xSearch(let search):
                inventory.xSearchCount += 1
                collectCitations(from: search.outcome, into: &uniqueCitationURLs)
            case .webFetch:
                inventory.webFetchCount += 1
            case .unrecognized:
                break
            }
        }
        inventory.citationCount = uniqueCitationURLs.count
        return inventory
    }

    private static func collectCitations(
        from outcome: XAIServerToolSegment.WebSearch.Outcome?,
        into urls: inout Set<String>
    ) {
        for citation in outcome?.citations ?? [] {
            urls.insert(citation.url.absoluteString)
        }
    }

    public static func describe(_ segment: XAIServerToolSegment) -> String {
        switch segment.content {
        case .webSearch(let search):
            let cites = search.outcome?.citations.count ?? 0
            let hits = search.outcome?.hits.count ?? 0
            return "webSearch query=\"\(search.query)\" status=\(search.status ?? "nil") citations=\(cites) hits=\(hits)"
        case .xSearch(let search):
            let cites = search.outcome?.citations.count ?? 0
            let hits = search.outcome?.hits.count ?? 0
            return "xSearch query=\"\(search.query)\" status=\(search.status ?? "nil") citations=\(cites) hits=\(hits)"
        case .webFetch(let fetch):
            return "open_page url=\(fetch.url.absoluteString) status=\(fetch.status ?? "nil")"
        case .unrecognized(let activity):
            return "unrecognized type=\(activity.itemType)"
        }
    }
}