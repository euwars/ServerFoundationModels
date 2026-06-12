// SystemLanguageModel — the platform's local on-device model.
//
// On Apple platforms this bridges to Apple's FoundationModels on-device model
// through the LanguageModelExecutor contract: the same LinuxFoundation session
// code drives Apple's model with no API difference. On Linux the model reports
// `.unavailable` (the on-device model is Apple-OS-bound); use
// ChatCompletionsLanguageModel against a local server instead.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public final class SystemLanguageModel: Sendable, LanguageModel {
    public static let `default` = SystemLanguageModel()

    public init() {}

    @frozen public enum Availability: Equatable, Sendable {
        case available
        case unavailable(UnavailableReason)

        public enum UnavailableReason: Equatable, Sendable {
            case deviceNotEligible
            case appleIntelligenceNotEnabled
            case modelNotReady
        }
    }

    public var availability: Availability {
        #if canImport(FoundationModels)
        switch FoundationModels.SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.modelNotReady)
            }
        @unknown default:
            return .unavailable(.modelNotReady)
        }
        #else
        return .unavailable(.deviceNotEligible)
        #endif
    }

    public var isAvailable: Bool {
        availability == .available
    }

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: [.toolCalling, .guidedGeneration])
    }

    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration()
    }

    // MARK: Executor

    public struct Executor: LanguageModelExecutor {
        public struct Configuration: Hashable, Sendable {
            public init() {}
        }

        public init(configuration: Configuration) throws {}

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: SystemLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            #if canImport(FoundationModels)
            try await bridgeRespond(to: request, streamingInto: channel)
            #else
            throw LanguageModelTransportError(
                statusCode: 0,
                message: "SystemLanguageModel is unavailable on this platform; use ChatCompletionsLanguageModel with a local model server"
            )
            #endif
        }
    }
}

#if canImport(FoundationModels)

// MARK: - Bridge to Apple's on-device model

extension SystemLanguageModel.Executor {

    fileprivate func bridgeRespond(
        to request: LanguageModelExecutorGenerationRequest,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        // The trailing prompt entry becomes the respond() argument; everything
        // before it is reconstructed as Apple-framework transcript history.
        var entries = Array(request.transcript)
        guard case .prompt(let promptEntry) = entries.popLast() else {
            throw LanguageModelTransportError(statusCode: 0, message: "request transcript must end with a prompt")
        }
        let promptText = promptEntry.segments.joinedText

        let recorder = BridgedToolRecorder()
        let fmTools = request.executableTools.map { tool in
            BridgedTool(erased: tool, recorder: recorder)
        }

        let fmSession = FoundationModels.LanguageModelSession(
            model: .default,
            tools: fmTools,
            transcript: FoundationModels.Transcript(entries: convertEntries(entries, tools: fmTools))
        )

        let fmOptions = FoundationModels.GenerationOptions(
            temperature: request.generationOptions.temperature,
            maximumResponseTokens: request.generationOptions.maximumResponseTokens
        )
        var fmContextOptions = FoundationModels.ContextOptions()
        switch request.contextOptions.reasoningLevel {
        case .light: fmContextOptions.reasoningLevel = .light
        case .moderate: fmContextOptions.reasoningLevel = .moderate
        case .deep: fmContextOptions.reasoningLevel = .deep
        case .custom(let value): fmContextOptions.reasoningLevel = .custom(value)
        case nil: break
        }

        if let schema = request.schema {
            let fmSchema = try convertSchema(schema)
            let response = try await fmSession.respond(to: promptText, schema: fmSchema, options: fmOptions)
            for call in await recorder.calls {
                await channel.send(RecordedToolExecution(
                    id: call.id, toolName: call.toolName,
                    argumentsJSON: call.argumentsJSON, outputText: call.output
                ))
            }
            await channel.send(.response(action: .appendText(response.content.jsonString, tokenCount: 0)))
            await channel.send(.response(action: .updateUsage(
                input: convertUsage(response.usage).input,
                output: convertUsage(response.usage).output
            )))
        } else {
            let stream = fmSession.streamResponse(
                to: promptText, options: fmOptions, contextOptions: fmContextOptions
            )
            var previous = ""
            var lastUsage: FoundationModels.LanguageModelSession.Usage?
            for try await snapshot in stream {
                let cumulative = snapshot.content
                if cumulative.hasPrefix(previous) {
                    await channel.send(.response(action: .appendText(String(cumulative.dropFirst(previous.count)), tokenCount: 0)))
                } else {
                    await channel.send(.response(action: .replaceTextSegment(cumulative, tokenCount: 0)))
                }
                previous = cumulative
                lastUsage = snapshot.usage
            }
            if let lastUsage {
                let converted = convertUsage(lastUsage)
                await channel.send(.response(action: .updateUsage(input: converted.input, output: converted.output)))
            }
            // Tool executions happened natively inside Apple's session; relay
            // them so the LinuxFoundation transcript records them faithfully.
            for call in await recorder.calls {
                await channel.send(RecordedToolExecution(
                    id: call.id, toolName: call.toolName,
                    argumentsJSON: call.argumentsJSON, outputText: call.output
                ))
            }
        }
    }

}

// MARK: Usage conversion

private func convertUsage(
    _ usage: FoundationModels.LanguageModelSession.Usage
) -> LanguageModelExecutorGenerationChannel.Usage {
    LanguageModelExecutorGenerationChannel.Usage(
        input: .init(
            totalTokenCount: usage.input.totalTokenCount,
            cachedTokenCount: usage.input.cachedTokenCount
        ),
        output: .init(
            totalTokenCount: usage.output.totalTokenCount,
            reasoningTokenCount: usage.output.reasoningTokenCount
        )
    )
}

// MARK: Transcript conversion

private func convertEntries(
        _ entries: [Transcript.Entry],
        tools: [BridgedTool]
    ) -> [FoundationModels.Transcript.Entry] {
        var converted: [FoundationModels.Transcript.Entry] = []
        for entry in entries {
            switch entry {
            case .instructions(let instructions):
                converted.append(.instructions(FoundationModels.Transcript.Instructions(
                    segments: [.text(.init(content: instructions.segments.joinedText))],
                    toolDefinitions: tools.map {
                        FoundationModels.Transcript.ToolDefinition(
                            name: $0.name, description: $0.description, parameters: $0.parameters
                        )
                    }
                )))
            case .prompt(let prompt):
                converted.append(.prompt(FoundationModels.Transcript.Prompt(
                    segments: [.text(.init(content: prompt.segments.joinedText))]
                )))
            case .response(let response):
                converted.append(.response(FoundationModels.Transcript.Response(
                    assetIDs: [],
                    segments: [.text(.init(content: response.segments.joinedText))]
                )))
            case .toolCalls(let toolCalls):
                let calls = toolCalls.calls.compactMap { call -> FoundationModels.Transcript.ToolCall? in
                    guard let arguments = try? FoundationModels.GeneratedContent(json: call.arguments.jsonString) else {
                        return nil
                    }
                    return FoundationModels.Transcript.ToolCall(id: call.id, toolName: call.toolName, arguments: arguments)
                }
                converted.append(.toolCalls(FoundationModels.Transcript.ToolCalls(calls)))
            case .toolOutput(let toolOutput):
                converted.append(.toolOutput(FoundationModels.Transcript.ToolOutput(
                    id: toolOutput.id,
                    toolName: toolOutput.toolName,
                    segments: [.text(.init(content: toolOutput.segments.joinedText))]
                )))
            case .reasoning:
                continue
            }
        }
        return converted
    }

// MARK: Schema conversion

private func convertSchema(_ schema: GenerationSchema) throws -> FoundationModels.GenerationSchema {
        var references: Set<String> = []
        schema.root.collectReferences(into: &references)

        // Apple resolves `referenceTo` names against the root schema as well as
        // dependencies; including the root again raises duplicateType.
        var rootName: String?
        if case .object(let name, _, _) = schema.root { rootName = name }

        var dependencies: [FoundationModels.DynamicGenerationSchema] = []
        for name in references.sorted() where name != rootName {
            if let definition = schema.root.findObject(named: name) {
                dependencies.append(convertNode(definition))
            }
        }
        return try FoundationModels.GenerationSchema(
            root: convertNode(schema.root),
            dependencies: dependencies
        )
    }

private func convertNode(_ node: SchemaNode) -> FoundationModels.DynamicGenerationSchema {
        switch node {
        case .string(let description, let enumChoices, _):
            if let enumChoices {
                return FoundationModels.DynamicGenerationSchema(
                    name: "choice", description: description, anyOf: enumChoices
                )
            }
            return FoundationModels.DynamicGenerationSchema(type: String.self)
        case .integer(_, let minimum, let maximum):
            var guides: [FoundationModels.GenerationGuide<Int>] = []
            if let minimum { guides.append(.minimum(minimum)) }
            if let maximum { guides.append(.maximum(maximum)) }
            return FoundationModels.DynamicGenerationSchema(type: Int.self, guides: guides)
        case .number(_, let minimum, let maximum):
            var guides: [FoundationModels.GenerationGuide<Double>] = []
            if let minimum { guides.append(.minimum(minimum)) }
            if let maximum { guides.append(.maximum(maximum)) }
            return FoundationModels.DynamicGenerationSchema(type: Double.self, guides: guides)
        case .boolean:
            return FoundationModels.DynamicGenerationSchema(type: Bool.self)
        case .object(let name, let description, let properties):
            return FoundationModels.DynamicGenerationSchema(
                name: name,
                description: description,
                properties: properties.map { property in
                    FoundationModels.DynamicGenerationSchema.Property(
                        name: property.name,
                        description: property.description,
                        schema: convertNode(property.node),
                        isOptional: property.isOptional
                    )
                }
            )
        case .array(_, let item, let minimumElements, let maximumElements):
            return FoundationModels.DynamicGenerationSchema(
                arrayOf: convertNode(item),
                minimumElements: minimumElements,
                maximumElements: maximumElements
            )
    case .reference(let name):
        return FoundationModels.DynamicGenerationSchema(referenceTo: name)
    case .raw:
        return FoundationModels.DynamicGenerationSchema(name: "value", properties: [])
    }
}

// MARK: - Tool bridging

/// Captures tool executions performed natively inside Apple's session so the
/// executor can relay them through the generation channel afterwards.
private actor BridgedToolRecorder {
    struct Call {
        let id: String
        let toolName: String
        let argumentsJSON: String
        let output: String
    }

    private(set) var calls: [Call] = []

    func record(_ call: Call) {
        calls.append(call)
    }
}

/// Wraps a LinuxFoundation tool as an Apple-framework tool: Apple's model
/// calls it natively, the real LinuxFoundation tool closure executes, and the
/// invocation is recorded for transcript reconstruction.
private struct BridgedTool: FoundationModels.Tool {
    typealias Arguments = FoundationModels.GeneratedContent
    typealias Output = String

    let erased: ErasedTool
    let recorder: BridgedToolRecorder

    var name: String { erased.name }
    var description: String { erased.description }

    var parameters: FoundationModels.GenerationSchema {
        if let schema = try? FoundationModels.GenerationSchema(
            root: convertNode(erased.parameters.root), dependencies: []
        ) {
            return schema
        }
        let empty = FoundationModels.DynamicGenerationSchema(name: "arguments", properties: [])
        return try! FoundationModels.GenerationSchema(root: empty, dependencies: [])
    }

    func call(arguments: FoundationModels.GeneratedContent) async throws -> String {
        let argumentsJSON = arguments.jsonString
        let output = try await erased.call(try GeneratedContent(json: argumentsJSON))
        await recorder.record(.init(
            id: UUID().uuidString,
            toolName: erased.name,
            argumentsJSON: argumentsJSON,
            output: output
        ))
        return output
    }
}

#endif
