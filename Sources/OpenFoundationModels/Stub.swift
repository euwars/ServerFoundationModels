// OpenFoundationModels — API skeleton.
//
// This is the deliberately UNIMPLEMENTED skeleton of the FoundationModels
// (SDK 27) API surface touched by the parity test suite. Every behavior throws
// `UnimplementedError` or returns inert values, so the parity tests compile
// and FAIL — the red phase. Implementation replaces this file piece by piece,
// driven by the shared scenarios in TestScenarios/ParityScenarios.swift and
// the ground-truth interface in reference/FoundationModels-macOS27.swiftinterface.

import Foundation

public struct UnimplementedError: Error, CustomStringConvertible {
    public let api: String
    public var description: String { "OpenFoundationModels: '\(api)' is not implemented yet" }
    init(_ api: String) { self.api = api }
}

// MARK: - Content conversion protocols

public protocol ConvertibleFromGeneratedContent: SendableMetatype {
    init(_ content: GeneratedContent) throws
}

public protocol PromptRepresentable {
    var promptRepresentation: Prompt { get }
}

public protocol InstructionsRepresentable {
    var instructionsRepresentation: Instructions { get }
}

public protocol ConvertibleToGeneratedContent: InstructionsRepresentable, PromptRepresentable {
    var generatedContent: GeneratedContent { get }
}

public protocol Generable: ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent {
    associatedtype PartiallyGenerated: ConvertibleFromGeneratedContent = Self
    static var generationSchema: GenerationSchema { get }
}

extension ConvertibleToGeneratedContent {
    public var promptRepresentation: Prompt { Prompt() }
    public var instructionsRepresentation: Instructions { Instructions() }
}

// MARK: - GeneratedContent

public struct GeneratedContent: Sendable, Equatable, CustomDebugStringConvertible {
    public var isComplete: Bool { false }

    public init(json: String) throws {
        throw UnimplementedError("GeneratedContent.init(json:)")
    }

    public init(properties: KeyValuePairs<String, any ConvertibleToGeneratedContent>) {}

    public init(_ value: some ConvertibleToGeneratedContent) {}

    public var jsonString: String { "" }

    public func value<Value>(
        _ type: Value.Type = Value.self,
        forProperty property: String
    ) throws -> Value where Value: ConvertibleFromGeneratedContent {
        throw UnimplementedError("GeneratedContent.value(_:forProperty:)")
    }

    public func value<Value>(
        _ type: Value.Type = Value.self
    ) throws -> Value where Value: ConvertibleFromGeneratedContent {
        throw UnimplementedError("GeneratedContent.value(_:)")
    }

    public var debugDescription: String { "GeneratedContent(unimplemented)" }
}

extension GeneratedContent: Generable {
    public static var generationSchema: GenerationSchema {
        GenerationSchema()
    }
    public var generatedContent: GeneratedContent { self }
}

// MARK: - Standard type conformances

extension String: Generable {
    public init(_ content: GeneratedContent) throws {
        throw UnimplementedError("String.init(_: GeneratedContent)")
    }
    public static var generationSchema: GenerationSchema { GenerationSchema() }
    public var generatedContent: GeneratedContent { GeneratedContent(self) }
}

extension Int: Generable {
    public init(_ content: GeneratedContent) throws {
        throw UnimplementedError("Int.init(_: GeneratedContent)")
    }
    public static var generationSchema: GenerationSchema { GenerationSchema() }
    public var generatedContent: GeneratedContent { GeneratedContent(self) }
}

extension Array: ConvertibleFromGeneratedContent where Element: ConvertibleFromGeneratedContent {
    public init(_ content: GeneratedContent) throws {
        throw UnimplementedError("Array.init(_: GeneratedContent)")
    }
}

extension Array: PromptRepresentable where Element: ConvertibleToGeneratedContent {}
extension Array: InstructionsRepresentable where Element: ConvertibleToGeneratedContent {}
extension Array: ConvertibleToGeneratedContent where Element: ConvertibleToGeneratedContent {
    public var generatedContent: GeneratedContent { GeneratedContent(properties: [:]) }
}
extension Array: Generable where Element: Generable {
    public static var generationSchema: GenerationSchema { GenerationSchema() }
}

// MARK: - Schemas

public struct GenerationSchema: Sendable, CustomDebugStringConvertible {
    init() {}

    public init(root: DynamicGenerationSchema, dependencies: [DynamicGenerationSchema]) throws {}

    public init(type: any Generable.Type, description: String? = nil, anyOf choices: [String]) {}

    public var debugDescription: String { "GenerationSchema(unimplemented)" }

    public struct Property: Sendable {
        public init<Value>(
            name: String,
            description: String? = nil,
            type: Value.Type,
            guides: [GenerationGuide<Value>] = []
        ) where Value: Generable {}
    }
}

public struct DynamicGenerationSchema: Sendable {
    public init(name: String, description: String? = nil, properties: [Property]) {}

    public init<Value>(type: Value.Type, guides: [GenerationGuide<Value>] = []) where Value: Generable {}

    public init(arrayOf itemSchema: DynamicGenerationSchema, minimumElements: Int? = nil, maximumElements: Int? = nil) {}

    public init(referenceTo name: String) {}

    public struct Property: Sendable {
        public init(
            name: String,
            description: String? = nil,
            schema: DynamicGenerationSchema,
            isOptional: Bool = false
        ) {}
    }
}

public struct GenerationGuide<Value>: Sendable {}

// MARK: - Options

public struct GenerationOptions: Sendable, Equatable {
    public struct SamplingMode: Sendable, Equatable {
        public static var greedy: SamplingMode { SamplingMode() }
    }

    public var samplingMode: SamplingMode?
    public var temperature: Double?
    public var maximumResponseTokens: Int?

    public init(
        samplingMode: SamplingMode? = nil,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil
    ) {
        self.samplingMode = samplingMode
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }
}

// MARK: - Prompt / Instructions

public struct Prompt: Sendable {
    init() {}
    public init(@PromptBuilder _ content: () throws -> Prompt) rethrows {
        self = try content()
    }
}

@resultBuilder
public struct PromptBuilder {
    public static func buildBlock(_ components: any PromptRepresentable...) -> Prompt {
        Prompt()
    }
}

extension String: PromptRepresentable {
    public var promptRepresentation: Prompt { Prompt() }
}

extension String: InstructionsRepresentable {
    public var instructionsRepresentation: Instructions { Instructions() }
}

public struct Instructions: Sendable {
    init() {}
    public init(@InstructionsBuilder _ content: () throws -> Instructions) rethrows {
        self = try content()
    }
}

@resultBuilder
public struct InstructionsBuilder {
    public static func buildBlock(_ components: any InstructionsRepresentable...) -> Instructions {
        Instructions()
    }
}

// MARK: - Transcript

public struct Transcript: Sendable, Equatable, RandomAccessCollection {
    public typealias Index = Int
    public typealias Element = Entry

    private var entries: [Entry]

    public init(entries: some Sequence<Entry> = []) {
        self.entries = Array(entries)
    }

    public var startIndex: Int { entries.startIndex }
    public var endIndex: Int { entries.endIndex }
    public subscript(position: Int) -> Entry { entries[position] }

    public enum Entry: Sendable, Equatable {
        case instructions(Transcript.Instructions)
        case prompt(Transcript.Prompt)
        case toolCalls(Transcript.ToolCalls)
        case toolOutput(Transcript.ToolOutput)
        case response(Transcript.Response)
        case reasoning(Transcript.Reasoning)
    }

    public enum Segment: Sendable, Equatable {
        case text(TextSegment)
        case structure(StructuredSegment)
    }

    public struct TextSegment: Sendable, Equatable {
        public var content: String
        public init(id: String = UUID().uuidString, content: String) {
            self.content = content
        }
    }

    public struct StructuredSegment: Sendable, Equatable {}

    public struct Instructions: Sendable, Equatable {
        public init(id: String = UUID().uuidString, segments: [Segment], toolDefinitions: [ToolDefinition] = []) {}
    }

    public struct Prompt: Sendable, Equatable {
        public init(id: String = UUID().uuidString, segments: [Segment], options: GenerationOptions = GenerationOptions(), responseFormat: ResponseFormat? = nil) {}
    }

    public struct Response: Sendable, Equatable {
        public init(id: String = UUID().uuidString, assetIDs: [String] = [], segments: [Segment]) {}
    }

    public struct ToolCalls: Sendable, Equatable {}
    public struct ToolOutput: Sendable, Equatable {}
    public struct Reasoning: Sendable, Equatable {}
    public struct ToolDefinition: Sendable, Equatable {
        public init(name: String, description: String, parameters: GenerationSchema) {}
        public static func == (lhs: ToolDefinition, rhs: ToolDefinition) -> Bool { true }
    }
    public struct ResponseFormat: Sendable, Equatable {}
}

// MARK: - Tool

public protocol Tool<Arguments, Output>: Sendable {
    associatedtype Output: PromptRepresentable
    associatedtype Arguments: ConvertibleFromGeneratedContent

    var name: String { get }
    var description: String { get }
    var parameters: GenerationSchema { get }
    var includesSchemaInInstructions: Bool { get }

    func call(arguments: Arguments) async throws -> Output
}

extension Tool {
    public var includesSchemaInInstructions: Bool { true }
}

extension Tool where Arguments: Generable {
    public var parameters: GenerationSchema { Arguments.generationSchema }
}

// MARK: - LanguageModel / executor layer (SDK 27 contract)

public struct LanguageModelCapabilities: Sendable {
    public init() {}
}

public protocol LanguageModel: Sendable {
    associatedtype Executor: LanguageModelExecutor where Self == Executor.Model
    var capabilities: LanguageModelCapabilities { get }
    var executorConfiguration: Executor.Configuration { get }
}

public protocol LanguageModelExecutor: Sendable {
    associatedtype Configuration: Hashable, Sendable
    associatedtype Model: LanguageModel

    init(configuration: Configuration) throws

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws

    func prewarm(model: Model, transcript: Transcript)
}

extension LanguageModelExecutor {
    public func prewarm(model: Model, transcript: Transcript) {}
}

public struct LanguageModelExecutorGenerationRequest: Sendable {
    public var id: UUID
    public var transcript: Transcript
    public var schema: GenerationSchema?
    public var generationOptions: GenerationOptions
}

public struct LanguageModelExecutorGenerationChannel: Sendable {
    public init() {}
}

// MARK: - Built-in models

public struct ChatCompletionsLanguageModel: Sendable, LanguageModel {
    public var name: String
    public var url: URL
    public var additionalHeaders: [String: String]
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

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities() }

    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(modelName: name, url: url, additionalHeaders: additionalHeaders)
    }

    public struct Executor: LanguageModelExecutor {
        public struct Configuration: Hashable, Sendable {
            var modelName: String
            var url: URL
            var additionalHeaders: [String: String]
        }

        public init(configuration: Configuration) throws {}

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ChatCompletionsLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            throw UnimplementedError("ChatCompletionsLanguageModel.Executor.respond")
        }
    }
}

// MARK: - Session

public final class LanguageModelSession {
    public private(set) var transcript: Transcript
    public var isResponding: Bool { false }

    @_disfavoredOverload
    public convenience init(
        model: some LanguageModel,
        tools: [any Tool] = [],
        instructions: String? = nil
    ) {
        self.init(transcript: Transcript())
    }

    public convenience init(
        model: some LanguageModel,
        tools: [any Tool] = [],
        instructions: Instructions? = nil
    ) {
        self.init(transcript: Transcript())
    }

    public convenience init(
        model: some LanguageModel,
        tools: [any Tool] = [],
        transcript: Transcript
    ) {
        self.init(transcript: transcript)
    }

    private init(transcript: Transcript) {
        self.transcript = transcript
    }

    public func prewarm(promptPrefix: Prompt? = nil) {}

    public func respond(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<String> {
        throw UnimplementedError("LanguageModelSession.respond(to:options:)")
    }

    public func respond(
        to prompt: String,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<GeneratedContent> {
        throw UnimplementedError("LanguageModelSession.respond(to:schema:includeSchemaInPrompt:options:)")
    }

    public func streamResponse(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) -> ResponseStream<String> {
        ResponseStream()
    }

    public struct Response<Content> {
        public let content: Content
        public let rawContent: GeneratedContent
        public let transcriptEntries: ArraySlice<Transcript.Entry>
    }

    public struct ResponseStream<Content>: AsyncSequence where Content: Generable {
        public struct Snapshot {
            public var content: Content.PartiallyGenerated
            public var rawContent: GeneratedContent
        }

        public typealias Element = Snapshot

        public struct AsyncIterator: AsyncIteratorProtocol {
            public mutating func next() async throws -> Snapshot? {
                throw UnimplementedError("LanguageModelSession.ResponseStream")
            }
        }

        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }

        public func collect() async throws -> Response<Content> {
            throw UnimplementedError("LanguageModelSession.ResponseStream.collect()")
        }
    }
}
