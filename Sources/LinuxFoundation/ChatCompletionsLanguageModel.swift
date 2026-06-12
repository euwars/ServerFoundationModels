// ChatCompletionsLanguageModel — a LanguageModel that talks to any
// OpenAI-compatible /chat/completions endpoint (Ollama, vLLM, llama-server,
// LM Studio, OpenRouter, ...). Modeled on Apple's implementation in
// apple/foundation-models-utilities (Apache 2.0).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ChatCompletionsLanguageModel: Sendable, LanguageModel {
    /// The model identifier sent in the `model` field of each request.
    public var name: String

    /// The base URL of the endpoint. `v1/chat/completions` is appended when
    /// the URL does not already include a `v1` path segment.
    public var url: URL

    /// Headers merged on top of the defaults (e.g. an `Authorization` header).
    public var additionalHeaders: [String: String]

    /// Whether the endpoint supports `response_format` for structured output.
    public var supportsGuidedGeneration: Bool

    public init(
        name: String,
        url: URL,
        additionalHeaders: [String: String] = [:],
        supportsGuidedGeneration: Bool = true
    ) {
        self.name = name
        self.url = url
        self.additionalHeaders = additionalHeaders
        self.supportsGuidedGeneration = supportsGuidedGeneration
    }

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities()
    }

    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(
            modelName: name,
            url: url,
            additionalHeaders: additionalHeaders,
            supportsGuidedGeneration: supportsGuidedGeneration
        )
    }

    // MARK: Executor

    public struct Executor: LanguageModelExecutor {
        public struct Configuration: Hashable, Sendable {
            var modelName: String
            var url: URL
            var additionalHeaders: [String: String]
            var supportsGuidedGeneration: Bool
        }

        let configuration: Configuration

        public init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ChatCompletionsLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let urlRequest = try makeURLRequest(for: request)
            let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var body = ""
                for try await line in bytes.lines {
                    body += line
                    if body.count > 4096 { break }
                }
                throw LanguageModelError.requestFailed(statusCode: http.statusCode, message: body)
            }

            // Accumulates streamed tool-call fragments by choice index.
            var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let chunk = try? JSONNode.parse(payload) else { continue }

                let delta = chunk["choices"]?[0]?["delta"]
                if case .string(let content) = delta?["content"], !content.isEmpty {
                    channel.send(.textDelta(content))
                }
                for reasoningKey in ["reasoning", "reasoning_content"] {
                    if case .string(let reasoning) = delta?[reasoningKey], !reasoning.isEmpty {
                        channel.send(.reasoningDelta(reasoning))
                    }
                }
                if let usage = chunk["usage"], case .object = usage {
                    func intValue(_ node: JSONNode?) -> Int {
                        if case .integer(let value) = node { return value }
                        return 0
                    }
                    channel.send(.usage(LanguageModelExecutorGenerationChannel.Usage(
                        input: .init(
                            totalTokenCount: intValue(usage["prompt_tokens"]),
                            cachedTokenCount: intValue(usage["prompt_tokens_details"]?["cached_tokens"])
                        ),
                        output: .init(
                            totalTokenCount: intValue(usage["completion_tokens"]),
                            reasoningTokenCount: intValue(usage["completion_tokens_details"]?["reasoning_tokens"])
                        )
                    )))
                }
                if case .array(let calls) = delta?["tool_calls"] {
                    for call in calls {
                        var index = 0
                        if case .integer(let i) = call["index"] { index = i }
                        var accumulated = toolCalls[index] ?? (id: "", name: "", arguments: "")
                        if case .string(let id) = call["id"], !id.isEmpty {
                            accumulated.id = id
                        }
                        if case .string(let name) = call["function"]?["name"], !name.isEmpty {
                            accumulated.name = name
                        }
                        if case .string(let fragment) = call["function"]?["arguments"] {
                            accumulated.arguments += fragment
                        }
                        toolCalls[index] = accumulated
                    }
                }
            }

            for index in toolCalls.keys.sorted() {
                let call = toolCalls[index]!
                channel.send(.toolCall(
                    id: call.id.isEmpty ? UUID().uuidString : call.id,
                    toolName: call.name,
                    argumentsJSON: call.arguments
                ))
            }
        }

        // MARK: Request construction

        func makeURLRequest(for request: LanguageModelExecutorGenerationRequest) throws -> URLRequest {
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            for (header, value) in configuration.additionalHeaders {
                urlRequest.setValue(value, forHTTPHeaderField: header)
            }
            let body = makeBody(for: request).serialized
            if ProcessInfo.processInfo.environment["LF_DEBUG"] != nil {
                FileHandle.standardError.write(Data("LF_DEBUG body: \(body)\n".utf8))
            }
            urlRequest.httpBody = Data(body.utf8)
            return urlRequest
        }

        var endpoint: URL {
            if configuration.url.pathComponents.contains("v1") {
                return configuration.url.appendingPathComponent("chat/completions")
            }
            return configuration.url.appendingPathComponent("v1/chat/completions")
        }

        func makeBody(for request: LanguageModelExecutorGenerationRequest) -> JSONNode {
            var members: [JSONNode.Member] = [
                .init(key: "model", value: .string(configuration.modelName)),
                .init(key: "stream", value: .bool(true)),
                .init(key: "stream_options", value: .object([
                    .init(key: "include_usage", value: .bool(true))
                ])),
                .init(key: "messages", value: .array(makeMessages(from: request.transcript))),
            ]

            if let reasoningLevel = request.contextOptions.reasoningLevel {
                let effort: String
                switch reasoningLevel {
                case .light: effort = "low"
                case .moderate: effort = "medium"
                case .deep: effort = "high"
                case .custom(let value): effort = value
                }
                members.append(.init(key: "reasoning_effort", value: .string(effort)))
            }

            let options = request.generationOptions
            if let temperature = options.temperature {
                members.append(.init(key: "temperature", value: .number(temperature)))
            }
            if let maximum = options.maximumResponseTokens {
                members.append(.init(key: "max_tokens", value: .integer(maximum)))
            }

            if !request.enabledToolDefinitions.isEmpty {
                let tools = request.enabledToolDefinitions.map { definition in
                    JSONNode.object([
                        .init(key: "type", value: .string("function")),
                        .init(key: "function", value: .object([
                            .init(key: "name", value: .string(definition.name)),
                            .init(key: "description", value: .string(definition.description)),
                            .init(key: "parameters", value: definition.parameters.jsonSchemaDocument),
                        ])),
                    ])
                }
                members.append(.init(key: "tools", value: .array(tools)))
            }

            if let schema = request.schema, configuration.supportsGuidedGeneration {
                members.append(.init(key: "response_format", value: .object([
                    .init(key: "type", value: .string("json_schema")),
                    .init(key: "json_schema", value: .object([
                        .init(key: "name", value: .string("response")),
                        .init(key: "strict", value: .bool(true)),
                        .init(key: "schema", value: schema.jsonSchemaDocument),
                    ])),
                ])))
            }

            return .object(members)
        }

        func makeMessages(from transcript: Transcript) -> [JSONNode] {
            var messages: [JSONNode] = []
            for entry in transcript {
                switch entry {
                case .instructions(let instructions):
                    messages.append(.object([
                        .init(key: "role", value: .string("system")),
                        .init(key: "content", value: .string(instructions.segments.joinedText)),
                    ]))
                case .prompt(let prompt):
                    messages.append(.object([
                        .init(key: "role", value: .string("user")),
                        .init(key: "content", value: .string(prompt.segments.joinedText)),
                    ]))
                case .response(let response):
                    messages.append(.object([
                        .init(key: "role", value: .string("assistant")),
                        .init(key: "content", value: .string(response.segments.joinedText)),
                    ]))
                case .toolCalls(let toolCalls):
                    let calls = toolCalls.calls.map { call in
                        JSONNode.object([
                            .init(key: "id", value: .string(call.id)),
                            .init(key: "type", value: .string("function")),
                            .init(key: "function", value: .object([
                                .init(key: "name", value: .string(call.toolName)),
                                .init(key: "arguments", value: .string(call.arguments.jsonString)),
                            ])),
                        ])
                    }
                    messages.append(.object([
                        .init(key: "role", value: .string("assistant")),
                        .init(key: "tool_calls", value: .array(calls)),
                    ]))
                case .toolOutput(let toolOutput):
                    messages.append(.object([
                        .init(key: "role", value: .string("tool")),
                        .init(key: "tool_call_id", value: .string(toolOutput.id)),
                        .init(key: "content", value: .string(toolOutput.segments.joinedText)),
                    ]))
                case .reasoning:
                    continue
                }
            }
            return messages
        }
    }
}

// MARK: - JSONNode traversal conveniences

extension JSONNode {
    subscript(key: String) -> JSONNode? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    subscript(index: Int) -> JSONNode? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }
}
