// Wire bridging: xAI Responses API output items → XAIServerToolSegment.

import Foundation

enum XAIServerToolWire {
    struct OrderedEvent: Sendable {
        enum Kind: Sendable {
            case customSegment(XAIServerToolSegment)
            case appendText(String)
        }
        var kind: Kind
    }

    static func orderedEvents(
        from outputItems: [JSONNode],
        topLevelCitations: [XAIServerToolSegment.Citation]
    ) -> [OrderedEvent] {
        var events: [OrderedEvent] = []
        var segmentsByID: [String: XAIServerToolSegment] = [:]
        var searchSegmentIDs: [String] = []

        func emit(_ segment: XAIServerToolSegment) {
            segmentsByID[segment.id] = segment
            events.append(.init(kind: .customSegment(segment)))
        }

        func trackSearchSegment(id: String) {
            if !searchSegmentIDs.contains(id) {
                searchSegmentIDs.append(id)
            }
        }

        func distributeCitations(_ citations: [XAIServerToolSegment.Citation]) {
            let grouped = groupCitationsBySegment(
                citations,
                segmentsByID: segmentsByID,
                searchSegmentIDs: searchSegmentIDs
            )
            for (id, cites) in grouped {
                upsertSearch(id: id) { content in
                    mergeCitations(into: content, citations: cites)
                }
            }
        }

        func upsertSearch(id: String, transform: (XAIServerToolSegment.Content) -> XAIServerToolSegment.Content) {
            let existing = segmentsByID[id]
            let base = existing?.content ?? .webSearch(.init(query: ""))
            let updated = XAIServerToolSegment(id: id, content: transform(base))
            if existing != nil, let idx = events.lastIndex(where: {
                if case .customSegment(let s) = $0.kind { return s.id == id }
                return false
            }) {
                events[idx] = .init(kind: .customSegment(updated))
            } else {
                events.append(.init(kind: .customSegment(updated)))
            }
            segmentsByID[id] = updated
        }

        for item in outputItems {
            guard case .string(let type) = item["type"] else { continue }
            switch type {
            case "web_search_call", "x_search_call", "custom_tool_call":
                if let segment = serverToolSegment(from: item) {
                    emit(segment)
                    if isSearchSegment(segment) {
                        trackSearchSegment(id: segment.id)
                    }
                } else {
                    emit(unrecognized(item, type: type))
                }

            case "message":
                let text = messageText(from: item)
                if !text.isEmpty {
                    events.append(.init(kind: .appendText(text)))
                }
                var cites = annotations(from: item)
                cites.append(contentsOf: parseInlineCitationLinks(from: text))
                distributeCitations(cites)

            default:
                break
            }
        }

        distributeCitations(topLevelCitations)

        return events
    }

    /// Maps one Responses API output item to a server-tool segment when recognized.
    static func serverToolSegment(from item: JSONNode) -> XAIServerToolSegment? {
        guard case .string(let type) = item["type"] else { return nil }
        let id = stringValue(item["id"]) ?? UUID().uuidString
        let status = stringValue(item["status"])
        switch type {
        case "web_search_call":
            if let fetch = pageFetch(from: item, status: status) {
                return fetch
            }
            if let query = stringValue(item["action"]?["query"]) {
                let hits = searchHits(from: item)
                let outcome = searchOutcome(status: status, hits: hits)
                return .init(id: id, content: .webSearch(.init(query: query, status: status, outcome: outcome)))
            }
            return nil

        case "x_search_call":
            if let fetch = pageFetch(from: item, status: status) {
                return fetch
            }
            if let query = stringValue(item["action"]?["query"]) {
                let hits = searchHits(from: item)
                let outcome = searchOutcome(status: status, hits: hits)
                return .init(id: id, content: .xSearch(.init(query: query, status: status, outcome: outcome)))
            }
            return nil

        case "custom_tool_call":
            let name = stringValue(item["name"]) ?? ""
            let inputJSON = stringValue(item["input"]) ?? "{}"
            return customToolSegment(id: id, name: name, inputJSON: inputJSON, status: status)

        default:
            return nil
        }
    }

    static func isSearchSegment(_ segment: XAIServerToolSegment) -> Bool {
        switch segment.content {
        case .webSearch, .xSearch: true
        default: false
        }
    }

    static func mergeCitations(
        into segment: XAIServerToolSegment,
        citations: [XAIServerToolSegment.Citation]
    ) -> XAIServerToolSegment {
        guard !citations.isEmpty else { return segment }
        return .init(id: segment.id, content: mergeCitations(into: segment.content, citations: citations))
    }

    static func distributeCitations(
        _ citations: [XAIServerToolSegment.Citation],
        segmentsByID: inout [String: XAIServerToolSegment],
        searchSegmentIDs: [String]
    ) -> [XAIServerToolSegment] {
        let grouped = groupCitationsBySegment(
            citations,
            segmentsByID: segmentsByID,
            searchSegmentIDs: searchSegmentIDs
        )
        var updated: [XAIServerToolSegment] = []
        for (id, cites) in grouped {
            guard let segment = segmentsByID[id] else { continue }
            let merged = mergeCitations(into: segment, citations: cites)
            segmentsByID[id] = merged
            updated.append(merged)
        }
        return updated
    }

    static func groupCitationsBySegment(
        _ citations: [XAIServerToolSegment.Citation],
        segmentsByID: [String: XAIServerToolSegment],
        searchSegmentIDs: [String]
    ) -> [String: [XAIServerToolSegment.Citation]] {
        var grouped: [String: [XAIServerToolSegment.Citation]] = [:]
        let fallback = searchSegmentIDs.last
        for citation in citations {
            let target = searchSegmentIDs.last(where: { id in
                segmentContainsURL(segmentsByID[id], url: citation.url)
            }) ?? fallback
            guard let target else { continue }
            grouped[target, default: []].append(citation)
        }
        return grouped
    }

    static func parseInlineCitationLinks(from text: String) -> [XAIServerToolSegment.Citation] {
        guard !text.isEmpty else { return [] }
        let pattern = #"\[\[([^\]]*)\]\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var citations: [XAIServerToolSegment.Citation] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 3,
                let titleRange = Range(match.range(at: 1), in: text),
                let urlRange = Range(match.range(at: 2), in: text),
                let url = URL(string: String(text[urlRange]))
            else { return }
            let title = String(text[titleRange])
            let start = text.distance(from: text.startIndex, to: titleRange.lowerBound)
            let end = text.distance(from: text.startIndex, to: urlRange.upperBound)
            citations.append(.init(
                url: url,
                title: title.isEmpty ? nil : title,
                startIndex: start,
                endIndex: end
            ))
        }
        return citations
    }

    /// Reconstructs a Responses API output item from a server-tool segment so a
    /// rehydrated transcript (decoded from JSON, no live conversation state) can
    /// replay prior server-tool activity as fresh-mode input. Lossy by nature —
    /// only the fields the segment preserves are restored. Each xAI server tool is
    /// a single self-contained output item, so there are no call/result halves to
    /// pair; returns `nil` only when an unrecognized item's stored JSON is unusable.
    static func outputItem(from segment: XAIServerToolSegment) -> JSONNode? {
        switch segment.content {
        case .webSearch(let search):
            return .object([
                .init(key: "type", value: .string("web_search_call")),
                .init(key: "id", value: .string(segment.id)),
                .init(key: "status", value: .string(search.status ?? "completed")),
                .init(key: "action", value: .object([
                    .init(key: "type", value: .string("search")),
                    .init(key: "query", value: .string(search.query)),
                ])),
            ])
        case .xSearch(let search):
            return .object([
                .init(key: "type", value: .string("custom_tool_call")),
                .init(key: "id", value: .string(segment.id)),
                .init(key: "name", value: .string("x_semantic_search")),
                .init(key: "status", value: .string(search.status ?? "completed")),
                .init(key: "input", value: .string(jsonObjectString(["query": search.query]))),
            ])
        case .webFetch(let fetch):
            return .object([
                .init(key: "type", value: .string("web_search_call")),
                .init(key: "id", value: .string(segment.id)),
                .init(key: "status", value: .string(fetch.status ?? "completed")),
                .init(key: "action", value: .object([
                    .init(key: "type", value: .string("open_page")),
                    .init(key: "url", value: .string(fetch.url.absoluteString)),
                ])),
            ])
        case .unrecognized(let activity):
            return try? JSONNode.parse(activity.wireJSON)
        }
    }

    /// Serializes a flat `[String: String]` as a compact JSON object string, with
    /// values escaped by the JSON encoder (no manual quote splicing).
    private static func jsonObjectString(_ fields: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private static func segmentContainsURL(
        _ segment: XAIServerToolSegment?,
        url: URL
    ) -> Bool {
        guard let segment else { return false }
        let target = url.absoluteString
        switch segment.content {
        case .webSearch(let search):
            return search.outcome?.hits.contains { $0.url.absoluteString == target } == true
        case .xSearch(let search):
            return search.outcome?.hits.contains { $0.url.absoluteString == target } == true
        default:
            return false
        }
    }

    private static func searchOutcome(
        status: String?,
        hits: [XAIServerToolSegment.WebSearch.Hit]
    ) -> XAIServerToolSegment.WebSearch.Outcome? {
        guard status == "completed" else { return nil }
        return .init(hits: hits)
    }

    private static let pageActionTypes: Set<String> = [
        "open_page", "browse_page", "open_page_with_find",
    ]

    private static func pageFetch(
        from item: JSONNode,
        status: String?
    ) -> XAIServerToolSegment? {
        guard let actionType = stringValue(item["action"]?["type"]),
            pageActionTypes.contains(actionType),
            let urlString = stringValue(item["action"]?["url"]),
            let url = URL(string: urlString)
        else { return nil }
        let id = stringValue(item["id"]) ?? UUID().uuidString
        return .init(id: id, content: .webFetch(.init(url: url, status: status)))
    }

    private static func searchHits(from item: JSONNode) -> [XAIServerToolSegment.WebSearch.Hit] {
        var hits = openPageHits(from: item)
        if case .array(let sources) = item["action"]?["sources"] {
            for source in sources {
                guard stringValue(source["type"]) == "url",
                    let urlString = stringValue(source["url"]),
                    let url = URL(string: urlString)
                else { continue }
                hits.append(.init(url: url))
            }
        }
        return mergeHits(hits)
    }

    private static func openPageHits(from item: JSONNode) -> [XAIServerToolSegment.WebSearch.Hit] {
        guard let actionType = stringValue(item["action"]?["type"]),
            pageActionTypes.contains(actionType),
            let urlString = stringValue(item["action"]?["url"]),
            let url = URL(string: urlString)
        else { return [] }
        return [.init(url: url)]
    }

    private static let xToolNames: Set<String> = [
        "x_user_search", "x_keyword_search", "x_semantic_search", "x_thread_fetch",
    ]

    private static let webSearchToolNames: Set<String> = [
        "web_search", "web_search_with_snippets",
    ]

    private static func customToolSegment(
        id: String,
        name: String,
        inputJSON: String,
        status: String?
    ) -> XAIServerToolSegment? {
        let input = (try? JSONNode.parse(inputJSON)) ?? .object([])
        if webSearchToolNames.contains(name) {
            let query = stringValue(input["query"]) ?? name
            let outcome = searchOutcome(status: status, hits: [])
            return .init(id: id, content: .webSearch(.init(query: query, status: status, outcome: outcome)))
        }
        if xToolNames.contains(name) {
            let query = stringValue(input["query"]) ?? stringValue(input["handle"]) ?? name
            let outcome = searchOutcome(status: status, hits: [])
            return .init(id: id, content: .xSearch(.init(query: query, status: status, outcome: outcome)))
        }
        if pageActionTypes.contains(name) {
            let urlString = stringValue(input["url"]) ?? stringValue(input["page_url"])
            guard let urlString, let url = URL(string: urlString) else { return nil }
            return .init(id: id, content: .webFetch(.init(url: url, status: status)))
        }
        return nil
    }

    private static func mergeHits(
        _ hits: [XAIServerToolSegment.WebSearch.Hit]
    ) -> [XAIServerToolSegment.WebSearch.Hit] {
        var seen = Set<String>()
        var merged: [XAIServerToolSegment.WebSearch.Hit] = []
        for hit in hits {
            let key = hit.url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(hit)
        }
        return merged
    }

    static func messageText(from item: JSONNode) -> String {
        var parts: [String] = []
        if case .array(let blocks) = item["content"] {
            for block in blocks {
                if case .string(let text) = block["text"], !text.isEmpty {
                    parts.append(text)
                }
            }
        }
        if case .string(let text) = item["text"], !text.isEmpty {
            parts.append(text)
        }
        return parts.joined(separator: "\n\n")
    }

    static func annotations(from item: JSONNode) -> [XAIServerToolSegment.Citation] {
        var citations: [XAIServerToolSegment.Citation] = []
        func collect(from blocks: [JSONNode]) {
            for block in blocks {
                if case .array(let annotations) = block["annotations"] {
                    citations.append(contentsOf: parseCitations(annotations))
                }
            }
        }
        if case .array(let blocks) = item["content"] {
            collect(from: blocks)
        }
        if case .array(let annotations) = item["annotations"] {
            citations.append(contentsOf: parseCitations(annotations))
        }
        return citations
    }

    static func parseTopLevelCitations(from root: JSONNode) -> [XAIServerToolSegment.Citation] {
        guard case .array(let nodes) = root["citations"] else { return [] }
        return nodes.compactMap { node -> XAIServerToolSegment.Citation? in
            if case .string(let urlString) = node, let url = URL(string: urlString) {
                return .init(url: url)
            }
            if let urlString = stringValue(node["url"]), let url = URL(string: urlString) {
                return .init(
                    url: url,
                    title: stringValue(node["title"]),
                    startIndex: intValue(node["start_index"]),
                    endIndex: intValue(node["end_index"])
                )
            }
            return nil
        }
    }

    static func parseCitation(from annotation: JSONNode) -> XAIServerToolSegment.Citation? {
        parseCitations([annotation]).first
    }

    private static func parseCitations(_ nodes: [JSONNode]) -> [XAIServerToolSegment.Citation] {
        nodes.compactMap { node in
            if let type = stringValue(node["type"]), type != "url_citation" {
                return nil
            }
            guard let urlString = stringValue(node["url"]), let url = URL(string: urlString) else {
                return nil
            }
            return .init(
                url: url,
                title: stringValue(node["title"]),
                startIndex: intValue(node["start_index"]),
                endIndex: intValue(node["end_index"])
            )
        }
    }

    private static func mergeCitations(
        into content: XAIServerToolSegment.Content,
        citations: [XAIServerToolSegment.Citation]
    ) -> XAIServerToolSegment.Content {
        switch content {
        case .webSearch(var search):
            var outcome = search.outcome ?? .init()
            outcome.citations = mergeUniqueCitations(outcome.citations + citations)
            search.outcome = outcome
            return .webSearch(search)
        case .xSearch(var search):
            var outcome = search.outcome ?? .init()
            outcome.citations = mergeUniqueCitations(outcome.citations + citations)
            search.outcome = outcome
            return .xSearch(search)
        default:
            return content
        }
    }

    private static func mergeUniqueCitations(
        _ citations: [XAIServerToolSegment.Citation]
    ) -> [XAIServerToolSegment.Citation] {
        var seen = Set<String>()
        var merged: [XAIServerToolSegment.Citation] = []
        for citation in citations {
            let key = citation.url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(citation)
        }
        return merged
    }

    private static func unrecognized(_ item: JSONNode, type: String) -> XAIServerToolSegment {
        let id = stringValue(item["id"]) ?? UUID().uuidString
        return .init(id: id, content: .unrecognized(.init(itemType: type, wireJSON: item.serialized)))
    }

    static func stringValue(_ node: JSONNode?) -> String? {
        if case .string(let value) = node { return value }
        return nil
    }

    static func intValue(_ node: JSONNode?) -> Int? {
        if case .integer(let value) = node { return value }
        if case .number(let value) = node, let exact = Int(exactly: value) { return exact }
        return nil
    }

    static func itemID(from event: JSONNode) -> String? {
        stringValue(event["item_id"]) ?? stringValue(event["item"]?["id"])
    }

    static func outputIndex(from event: JSONNode) -> Int? {
        intValue(event["output_index"])
    }

    static func settingObjectField(_ item: JSONNode, key: String, value: JSONNode) -> JSONNode {
        guard case .object(var members) = item else { return item }
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(.init(key: key, value: value))
        }
        return .object(members)
    }
}