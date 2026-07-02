// xAI Responses API wire types and HTTP transport.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct XAIResponsesRequest: Sendable {
    var model: String
    var reasoning: XAIReasoningEffort?
    var instructions: String?
    var inputItems: [JSONNode]
    var prebuiltInputJSON: Data?
    var tools: [JSONNode]
    var store: Bool = true
    var textFormat: JSONNode?
    var previousResponseId: String?
    var temperature: Double?
    var maxOutputTokens: Int?
    var promptCacheKey: String?
    var stream: Bool = true
    var include: [String] = []

    func bodyJSON() throws -> Data {
        Data(serialize().utf8)
    }

    func serialize() -> String {
        var members: [JSONNode.Member] = [
            .init(key: "model", value: .string(model)),
            .init(key: "store", value: .bool(store)),
        ]

        if let reasoning {
            members.append(.init(key: "reasoning", value: .object([
                .init(key: "effort", value: .string(reasoning.rawValue)),
            ])))
        }
        if let instructions {
            members.append(.init(key: "instructions", value: .string(instructions)))
        }

        if let prebuiltInputJSON,
            let array = try? JSONSerialization.jsonObject(with: prebuiltInputJSON) as? [Any] {
            members.append(.init(key: "input", value: .array(array.map { anyToJSONNode($0) })))
        } else {
            members.append(.init(key: "input", value: .array(inputItems)))
        }

        if !tools.isEmpty {
            members.append(.init(key: "tools", value: .array(tools)))
        }
        if let textFormat {
            members.append(.init(key: "text", value: textFormat))
        }
        if let previousResponseId {
            members.append(.init(key: "previous_response_id", value: .string(previousResponseId)))
        }
        if let temperature {
            members.append(.init(key: "temperature", value: .number(temperature)))
        }
        if let maxOutputTokens {
            members.append(.init(key: "max_output_tokens", value: .integer(maxOutputTokens)))
        }
        if let promptCacheKey {
            members.append(.init(key: "prompt_cache_key", value: .string(promptCacheKey)))
        }
        if stream {
            members.append(.init(key: "stream", value: .bool(true)))
        }
        if !include.isEmpty {
            members.append(.init(key: "include", value: .array(include.map { .string($0) })))
        }

        return JSONNode.object(members).serialized
    }
}

// MARK: - Input item builders

enum XAIInputBuilder {
    static func userMessage(text: String) -> JSONNode {
        .object([
            .init(key: "type", value: .string("message")),
            .init(key: "role", value: .string("user")),
            .init(key: "content", value: .array([
                .object([
                    .init(key: "type", value: .string("input_text")),
                    .init(key: "text", value: .string(text)),
                ]),
            ])),
        ])
    }

    static func functionCallOutput(callId: String, output: String) -> JSONNode {
        .object([
            .init(key: "type", value: .string("function_call_output")),
            .init(key: "call_id", value: .string(callId)),
            .init(key: "output", value: .string(output)),
        ])
    }

    /// Builds Responses API input items from transcript entries.
    ///
    /// `includeAssistantTurns` controls prior-assistant replay. It must stay
    /// `false` for the threaded delta path (the server already holds those turns
    /// behind `previous_response_id`, so resending them would duplicate context).
    /// Fresh mode — used when a transcript is rehydrated with no live conversation
    /// state — sets it `true` so prior assistant text and server-tool segments are
    /// reconstructed as input rather than silently dropped.
    static func entries(
        from transcript: Transcript,
        range: Range<Int>? = nil,
        includeAssistantTurns: Bool = false
    ) -> [JSONNode] {
        let entries = Array(transcript.allEntries)
        let slice: ArraySlice<Transcript.Entry>
        if let range {
            slice = entries[range]
        } else {
            slice = entries[entries.startIndex...]
        }
        var items: [JSONNode] = []
        for entry in slice {
            items.append(contentsOf: inputItems(from: entry, includeAssistantTurns: includeAssistantTurns))
        }
        return items
    }

    static func assistantMessage(text: String) -> JSONNode {
        .object([
            .init(key: "type", value: .string("message")),
            .init(key: "role", value: .string("assistant")),
            .init(key: "content", value: .array([
                .object([
                    .init(key: "type", value: .string("output_text")),
                    .init(key: "text", value: .string(text)),
                ]),
            ])),
        ])
    }

    /// Reconstructs the input items for one prior assistant response, preserving
    /// segment order: server-tool activity replays as its Responses API output
    /// item, text/structured output as an assistant message.
    private static func responseItems(from response: Transcript.Response) -> [JSONNode] {
        var items: [JSONNode] = []
        for segment in response.segments {
            switch segment {
            case .text(let text):
                if !text.content.isEmpty { items.append(assistantMessage(text: text.content)) }
            case .structure(let structure):
                items.append(assistantMessage(text: structure.content.jsonString))
            case .custom(let custom):
                if let activity = custom as? XAIServerToolSegment,
                    let item = XAIServerToolWire.outputItem(from: activity) {
                    items.append(item)
                } else {
                    let description = custom.description
                    if !description.isEmpty { items.append(assistantMessage(text: description)) }
                }
            case .attachment:
                break
            }
        }
        return items
    }

    static func instructionsText(from transcript: Transcript) -> String? {
        var parts: [String] = []
        for entry in transcript {
            if case .instructions(let instructions) = entry {
                let text = instructions.segments.joinedText
                if !text.isEmpty { parts.append(text) }
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    static func latestUserPrompt(from transcript: Transcript) -> String? {
        for entry in transcript.reversed() {
            if case .prompt(let prompt) = entry {
                let text = prompt.segments.joinedText
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func inputItems(
        from entry: Transcript.Entry,
        includeAssistantTurns: Bool
    ) -> [JSONNode] {
        switch entry {
        case .instructions:
            return []
        case .prompt(let prompt):
            let text = prompt.segments.joinedText
            guard !text.isEmpty else { return [] }
            return [userMessage(text: text)]
        case .toolOutput(let output):
            let text = output.segments.joinedText
            return [functionCallOutput(callId: output.id, output: text)]
        case .response(let response):
            return includeAssistantTurns ? responseItems(from: response) : []
        case .toolCalls, .reasoning:
            return []
        }
    }

    static func buildInlineInput(
        chain: [XAIConversationState.StoredTurn],
        newUserPrompt: String
    ) throws -> Data {
        var inputItems: [[String: Any]] = []
        for ancestor in chain {
            inputItems.append([
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": ancestor.prompt]],
            ])
            if let raw = ancestor.rawOutput,
                let priorItems = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] {
                for item in priorItems {
                    let type = item["type"] as? String ?? ""
                    if type == "reasoning" && item["encrypted_content"] == nil { continue }
                    var sanitized = item
                    if type == "message" {
                        let content = sanitized["content"] as? [[String: Any]] ?? []
                        if content.isEmpty {
                            sanitized["content"] = [["type": "output_text", "text": " "]]
                        }
                    }
                    inputItems.append(sanitized)
                }
            } else {
                let text = ancestor.outputText.isEmpty ? " " : ancestor.outputText
                inputItems.append([
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": text]],
                ])
            }
        }
        inputItems.append([
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": newUserPrompt]],
        ])
        return try JSONSerialization.data(withJSONObject: inputItems)
    }
}

func anyToJSONNode(_ value: Any) -> JSONNode {
    switch value {
    case is NSNull:
        return .null
    case let n as NSNumber:
        let type = String(cString: n.objCType)
        if type == "c" || type == "B" { return .bool(n.boolValue) }
        if type == "f" || type == "d" { return .number(n.doubleValue) }
        return .integer(Int(n.int64Value))
    case let b as Bool:
        return .bool(b)
    case let i as Int:
        return .integer(i)
    case let d as Double:
        return .number(d)
    case let s as String:
        return .string(s)
    case let arr as [Any]:
        return .array(arr.map(anyToJSONNode))
    case let dict as [String: Any]:
        return .object(dict.keys.sorted().map { key in
            JSONNode.Member(key: key, value: anyToJSONNode(dict[key]!))
        })
    default:
        return .string(String(describing: value))
    }
}

func extractRawOutputField(from body: Data) -> Data? {
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let outputArray = obj["output"] as? [Any]
    else { return nil }
    return try? JSONSerialization.data(withJSONObject: outputArray)
}