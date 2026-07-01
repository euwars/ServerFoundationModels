// xAI Responses API SSE → incremental channel events (server-tool segments, text).

import Foundation

enum XAIResponseStream {
    enum ChannelAction: Sendable {
        case updateCustomSegment(XAIServerToolSegment)
        case appendText(String)
        case toolCall(id: String, name: String, arguments: String)
        case usage(LanguageModelExecutorGenerationChannel.Usage)
    }

    struct Accumulator: Sendable {
        private(set) var responseId: String?
        private(set) var text = ""
        private(set) var outputItems: [JSONNode] = []
        private(set) var toolCalls: [(id: String, name: String, arguments: String)] = []
        private(set) var usage: LanguageModelExecutorGenerationChannel.Usage?
        private(set) var isTerminal = false

        private var outputIndexByItemID: [String: Int] = [:]
        private var searchSegmentIDs: [String] = []
        private var segmentsByID: [String: XAIServerToolSegment] = [:]
        private var functionCallArgs: [String: (id: String, name: String, arguments: String)] = [:]
        private var topLevelCitations: [XAIServerToolSegment.Citation] = []

        mutating func ingest(payload: String) throws -> [ChannelAction] {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "[DONE]" {
                isTerminal = true
                return finalizePending()
            }

            let event = try JSONNode.parse(trimmed)
            guard case .string(let type) = event["type"] else { return [] }

            switch type {
            case "error":
                let message = XAIServerToolWire.stringValue(event["message"])
                    ?? XAIServerToolWire.stringValue(event["error"]?["message"])
                    ?? "xAI stream error"
                throw LanguageModelTransportError(statusCode: 0, message: message)

            case "response.created", "response.in_progress":
                if let id = XAIServerToolWire.stringValue(event["response"]?["id"]) {
                    responseId = id
                }
                return []

            case "response.output_item.added", "response.output_item.done":
                return ingestOutputItem(event)

            case "response.web_search_call.in_progress",
                "response.web_search_call.searching",
                "response.web_search_call.completed",
                "response.x_search_call.in_progress",
                "response.x_search_call.searching",
                "response.x_search_call.completed":
                return ingestToolStatus(event, status: type.split(separator: ".").last.map(String.init))

            case "response.output_text.delta":
                guard let delta = XAIServerToolWire.stringValue(event["delta"]), !delta.isEmpty else {
                    return []
                }
                text += delta
                return [.appendText(delta)]

            case "response.output_text.annotation.added":
                guard let annotation = event["annotation"],
                    let citation = XAIServerToolWire.parseCitation(from: annotation)
                else { return [] }
                return distribute([citation])

            case "response.function_call_arguments.delta":
                guard let itemID = XAIServerToolWire.itemID(from: event),
                    let delta = XAIServerToolWire.stringValue(event["delta"])
                else { return [] }
                var entry = functionCallArgs[itemID] ?? (id: itemID, name: "", arguments: "")
                entry.arguments += delta
                functionCallArgs[itemID] = entry
                return []

            case "response.function_call_arguments.done":
                guard let itemID = XAIServerToolWire.itemID(from: event) else { return [] }
                let name = XAIServerToolWire.stringValue(event["name"]) ?? ""
                let arguments = XAIServerToolWire.stringValue(event["arguments"]) ?? "{}"
                functionCallArgs[itemID] = (id: itemID, name: name, arguments: arguments)
                return []

            case "response.completed":
                isTerminal = true
                if let response = event["response"] {
                    responseId = XAIServerToolWire.stringValue(response["id"]) ?? responseId
                    topLevelCitations = XAIServerToolWire.parseTopLevelCitations(from: response)
                    usage = XAIResponseTranslator.parseUsage(from: response["usage"])
                    if case .array(let items) = response["output"], !items.isEmpty {
                        replaceOutputItems(items)
                    }
                }
                return finalizePending()

            case "response.failed", "response.incomplete":
                isTerminal = true
                let message = XAIServerToolWire.stringValue(event["response"]?["error"]?["message"])
                    ?? type
                throw LanguageModelTransportError(statusCode: 0, message: message)

            default:
                return []
            }
        }

        func finish() -> XAIResponseTranslator.Parsed {
            let orderedEvents = XAIServerToolWire.orderedEvents(
                from: outputItems,
                topLevelCitations: topLevelCitations
            )
            return .init(
                responseId: responseId,
                text: text,
                rawOutput: buildRawOutput(),
                toolCalls: toolCalls,
                usage: usage,
                orderedEvents: orderedEvents
            )
        }

        private mutating func ingestOutputItem(_ event: JSONNode) -> [ChannelAction] {
            guard let item = event["item"],
                let index = XAIServerToolWire.outputIndex(from: event)
            else { return [] }
            setOutputItem(item, at: index)
            return emitSegmentActions(for: item)
        }

        private mutating func ingestToolStatus(_ event: JSONNode, status: String?) -> [ChannelAction] {
            guard let itemID = XAIServerToolWire.itemID(from: event),
                let index = outputIndexByItemID[itemID],
                index < outputItems.count
            else { return [] }
            var item = outputItems[index]
            if let status {
                item = XAIServerToolWire.settingObjectField(item, key: "status", value: .string(status))
                outputItems[index] = item
            }
            return emitSegmentActions(for: item)
        }

        private mutating func setOutputItem(_ item: JSONNode, at index: Int) {
            if index >= outputItems.count {
                outputItems.append(contentsOf: Array(repeating: JSONNode.null, count: index - outputItems.count + 1))
            }
            outputItems[index] = item
            if let id = XAIServerToolWire.stringValue(item["id"]) {
                outputIndexByItemID[id] = index
            }
        }

        private mutating func replaceOutputItems(_ items: [JSONNode]) {
            outputItems = items
            outputIndexByItemID.removeAll(keepingCapacity: true)
            for (index, item) in items.enumerated() {
                if let id = XAIServerToolWire.stringValue(item["id"]) {
                    outputIndexByItemID[id] = index
                }
            }
        }

        private mutating func emitSegmentActions(for item: JSONNode) -> [ChannelAction] {
            guard let segment = XAIServerToolWire.serverToolSegment(from: item) else { return [] }
            if XAIServerToolWire.isSearchSegment(segment), !searchSegmentIDs.contains(segment.id) {
                searchSegmentIDs.append(segment.id)
            }
            segmentsByID[segment.id] = segment
            return [.updateCustomSegment(segment)]
        }

        /// Distributes citations onto the search segments they belong to, using the
        /// same URL-matching (with last-segment fallback) as the batch parse path so
        /// incremental channel updates and the final transcript agree.
        private mutating func distribute(
            _ citations: [XAIServerToolSegment.Citation]
        ) -> [ChannelAction] {
            guard !citations.isEmpty else { return [] }
            let updated = XAIServerToolWire.distributeCitations(
                citations,
                segmentsByID: &segmentsByID,
                searchSegmentIDs: searchSegmentIDs
            )
            return updated.map { .updateCustomSegment($0) }
        }

        private mutating func finalizePending() -> [ChannelAction] {
            var actions: [ChannelAction] = []

            actions.append(contentsOf: distribute(topLevelCitations))

            for item in outputItems {
                guard case .string(let type) = item["type"], type == "message" else { continue }
                let messageText = XAIServerToolWire.messageText(from: item)
                if !messageText.isEmpty, messageText.count > text.count {
                    let delta = String(messageText.dropFirst(text.count))
                    text = messageText
                    actions.append(.appendText(delta))
                }
                var inlineCitations = XAIServerToolWire.annotations(from: item)
                inlineCitations.append(contentsOf: XAIServerToolWire.parseInlineCitationLinks(from: messageText))
                actions.append(contentsOf: distribute(inlineCitations))
            }

            // Client function calls carry their name on the `function_call` output
            // item, not on the `function_call_arguments.done` event, so build them
            // from the output items (matching the non-streaming translator). Fall
            // back to streamed argument deltas when the item omits `arguments`.
            var collected: [(id: String, name: String, arguments: String)] = []
            for item in outputItems {
                guard case .string(let type) = item["type"], type == "function_call" else { continue }
                let id = XAIServerToolWire.stringValue(item["id"])
                    ?? XAIServerToolWire.stringValue(item["call_id"])
                    ?? UUID().uuidString
                guard let name = XAIServerToolWire.stringValue(item["name"]), !name.isEmpty else { continue }
                let arguments = XAIServerToolWire.stringValue(item["arguments"])
                    ?? functionCallArgs[id]?.arguments
                    ?? "{}"
                collected.append((id: id, name: name, arguments: arguments))
            }
            toolCalls = collected
            for call in collected {
                actions.append(.toolCall(id: call.id, name: call.name, arguments: call.arguments))
            }

            if let usage {
                actions.append(.usage(usage))
            }

            return actions
        }

        private func buildRawOutput() -> Data? {
            guard !outputItems.isEmpty else { return nil }
            let payload = JSONNode.object([
                .init(key: "output", value: .array(outputItems)),
            ])
            return Data(payload.serialized.utf8)
        }
    }

    static func emit(_ action: ChannelAction, into channel: LanguageModelExecutorGenerationChannel) async {
        switch action {
        case .updateCustomSegment(let segment):
            await channel.send(.response(action: .updateCustomSegment(segment)))
        case .appendText(let text):
            await channel.send(.response(action: .appendText(text, tokenCount: 0)))
        case .toolCall(let id, let name, let arguments):
            await channel.send(.toolCalls(action: .toolCall(
                id: id,
                name: name,
                action: .appendArguments(arguments, tokenCount: 0)
            )))
        case .usage(let usage):
            await channel.send(.response(action: .updateUsage(
                input: usage.input,
                output: usage.output
            )))
        }
    }
}
