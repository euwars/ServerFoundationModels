// Pure translation: framework request → xAI Responses API body.

import Foundation

enum XAIRequestBuilder {
    struct Built: Sendable {
        var request: XAIResponsesRequest
        var mode: XAIConversationState.ThreadingMode
        var userPrompt: String?
    }

    static func build(
        from request: LanguageModelExecutorGenerationRequest,
        model: XAIModel,
        serverTools: Set<XAIServerTool>,
        conversationState: XAIConversationState
    ) throws -> Built {
        let transcript = request.transcript
        let entryCount = transcript.count
        let mode = conversationState.threadingMode(model: model)
        let lastSent = conversationState.lastSentIndex()

        let reasoning = reasoningEffort(
            from: request.contextOptions.reasoningLevel,
            default: model.defaultReasoningEffort
        )
        let temperature = request.generationOptions.temperature
        let maxTokens = request.generationOptions.maximumResponseTokens ?? 65_536
        let tools = makeTools(
            clientTools: request.enabledToolDefinitions,
            serverTools: serverTools
        )
        let textFormat = makeTextFormat(schema: request.schema, model: model)

        var built = XAIResponsesRequest(
            model: model.id,
            reasoning: reasoning,
            instructions: nil,
            inputItems: [],
            tools: tools,
            textFormat: textFormat,
            temperature: temperature,
            maxOutputTokens: maxTokens,
            promptCacheKey: conversationState.promptCacheKey,
            include: makeInclude(serverTools: serverTools)
        )

        let userPrompt = XAIInputBuilder.latestUserPrompt(from: transcript)

        switch mode {
        case .threaded(let previousResponseId):
            built.previousResponseId = previousResponseId
            let deltaStart = min(lastSent, entryCount)
            built.inputItems = XAIInputBuilder.entries(
                from: transcript,
                range: deltaStart..<entryCount
            )
            if built.inputItems.isEmpty, let userPrompt {
                built.inputItems = [XAIInputBuilder.userMessage(text: userPrompt)]
            }
        case .inline:
            guard let userPrompt else {
                throw LanguageModelTransportError(statusCode: 0, message: "inline replay requires a user prompt")
            }
            built.instructions = XAIInputBuilder.instructionsText(from: transcript)
            built.prebuiltInputJSON = try XAIInputBuilder.buildInlineInput(
                chain: conversationState.storedTurnChain(),
                newUserPrompt: userPrompt
            )
        case .fresh:
            built.instructions = XAIInputBuilder.instructionsText(from: transcript)
            built.inputItems = XAIInputBuilder.entries(from: transcript)
            if built.inputItems.isEmpty, let userPrompt {
                built.inputItems = [XAIInputBuilder.userMessage(text: userPrompt)]
            }
        }

        return Built(request: built, mode: mode, userPrompt: userPrompt)
    }

    private static func reasoningEffort(
        from level: ContextOptions.ReasoningLevel?,
        default defaultEffort: XAIReasoningEffort
    ) -> XAIReasoningEffort? {
        guard let level else { return defaultEffort }
        switch level {
        case .light: return .low
        case .moderate: return .medium
        case .deep: return .high
        case .custom(let value):
            return XAIReasoningEffort(rawValue: value) ?? defaultEffort
        }
    }

    private static func makeInclude(serverTools: Set<XAIServerTool>) -> [String] {
        var include: [String] = []
        if serverTools.contains(.webSearch) {
            include.append("web_search_call.action.sources")
        }
        return include
    }

    private static func makeTools(
        clientTools: [Transcript.ToolDefinition],
        serverTools: Set<XAIServerTool>
    ) -> [JSONNode] {
        var tools: [JSONNode] = serverTools.sorted { $0.wireType < $1.wireType }.map { tool in
            .object([.init(key: "type", value: .string(tool.wireType))])
        }
        for definition in clientTools {
            tools.append(.object([
                .init(key: "type", value: .string("function")),
                .init(key: "name", value: .string(definition.name)),
                .init(key: "description", value: .string(definition.description)),
                .init(key: "parameters", value: definition.parameters.jsonSchemaDocument),
            ]))
        }
        return tools
    }

    private static func makeTextFormat(schema: GenerationSchema?, model: XAIModel) -> JSONNode? {
        guard let schema, model.supportsGuidedGeneration else { return nil }
        let strictSchema = XAISchemaHelpers.strictSchema(from: schema)
        return .object([
            .init(key: "format", value: .object([
                .init(key: "type", value: .string("json_schema")),
                .init(key: "name", value: .string("response")),
                .init(key: "strict", value: .bool(true)),
                .init(key: "schema", value: strictSchema),
            ])),
        ])
    }
}