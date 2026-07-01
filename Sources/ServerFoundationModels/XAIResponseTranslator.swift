// xAI Responses API JSON → LanguageModelExecutorGenerationChannel events.

import Foundation

enum XAIResponseTranslator {
    struct Parsed: Sendable {
        var responseId: String?
        var text: String
        var rawOutput: Data?
        var toolCalls: [(id: String, name: String, arguments: String)]
        var usage: LanguageModelExecutorGenerationChannel.Usage?
        var orderedEvents: [XAIServerToolWire.OrderedEvent]
    }

    static func parse(body: Data) throws -> Parsed {
        guard let text = String(data: body, encoding: .utf8),
            let root = try? JSONNode.parse(text) else {
            throw LanguageModelTransportError(statusCode: 0, message: "malformed xAI response JSON")
        }

        var outputItems: [JSONNode] = []
        var textParts: [String] = []
        var toolCalls: [(id: String, name: String, arguments: String)] = []

        if case .array(let items) = root["output"] {
            outputItems = items
            for item in items {
                guard case .string(let type) = item["type"] else { continue }
                switch type {
                case "message":
                    let messageText = XAIServerToolWire.messageText(from: item)
                    if !messageText.isEmpty { textParts.append(messageText) }
                case "function_call":
                    let id = stringValue(item["id"]) ?? stringValue(item["call_id"]) ?? UUID().uuidString
                    let name = stringValue(item["name"]) ?? ""
                    let arguments = stringValue(item["arguments"]) ?? "{}"
                    toolCalls.append((id: id, name: name, arguments: arguments))
                default:
                    break
                }
            }
        }

        let citations = XAIServerToolWire.parseTopLevelCitations(from: root)
        let orderedEvents = XAIServerToolWire.orderedEvents(
            from: outputItems,
            topLevelCitations: citations
        )

        let usage = parseUsage(root["usage"])
        return Parsed(
            responseId: stringValue(root["id"]),
            text: textParts.joined(separator: "\n\n"),
            rawOutput: extractRawOutputField(from: body),
            toolCalls: toolCalls,
            usage: usage,
            orderedEvents: orderedEvents
        )
    }

    static func emit(_ parsed: Parsed, into channel: LanguageModelExecutorGenerationChannel) async {
        for event in parsed.orderedEvents {
            switch event.kind {
            case .customSegment(let segment):
                await channel.send(.response(action: .updateCustomSegment(segment)))
            case .appendText(let text):
                await channel.send(.response(action: .appendText(text, tokenCount: 0)))
            }
        }
        for call in parsed.toolCalls {
            await channel.send(.toolCalls(action: .toolCall(
                id: call.id,
                name: call.name,
                action: .appendArguments(call.arguments, tokenCount: 0)
            )))
        }
        if let usage = parsed.usage {
            await channel.send(.response(action: .updateUsage(
                input: usage.input,
                output: usage.output
            )))
        }
    }

    private static func parseUsage(_ node: JSONNode?) -> LanguageModelExecutorGenerationChannel.Usage? {
        guard let node else { return nil }
        func intValue(_ child: JSONNode?) -> Int {
            if case .integer(let value) = child { return Int(value) }
            if case .number(let value) = child, let exact = Int(exactly: value) { return exact }
            return 0
        }
        let input = intValue(node["input_tokens"])
        let output = intValue(node["output_tokens"])
        let cached = intValue(node["input_tokens_details"]?["cached_tokens"])
        return .init(
            input: .init(totalTokenCount: input, cachedTokenCount: cached),
            output: .init(totalTokenCount: output, reasoningTokenCount: 0)
        )
    }

    private static func stringValue(_ node: JSONNode?) -> String? {
        if case .string(let value) = node { return value }
        return nil
    }
}