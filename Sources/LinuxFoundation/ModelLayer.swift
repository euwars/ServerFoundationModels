// The SDK 27 model/executor contract: LanguageModel, LanguageModelExecutor,
// LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel,
// LanguageModelCapabilities, GenerationOptions, Tool.
//
// Third-party model packages conform to LanguageModel + LanguageModelExecutor
// exactly as they do against Apple's framework.

import Foundation

// MARK: - Options

public struct GenerationOptions: Sendable, Equatable {
    public struct SamplingMode: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case greedy
        }
        let kind: Kind

        public static var greedy: SamplingMode { SamplingMode(kind: .greedy) }
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
    public var name: String { String(describing: Self.self) }
    public var includesSchemaInInstructions: Bool { true }
}

extension Tool where Arguments: Generable {
    public var parameters: GenerationSchema { Arguments.generationSchema }
}

// MARK: - Capabilities

public struct LanguageModelCapabilities: Sendable {
    public init() {}
}

// MARK: - LanguageModel / Executor

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

// MARK: - Generation request

public struct LanguageModelExecutorGenerationRequest: Sendable {
    public var id: UUID
    public var transcript: Transcript
    public var enabledToolDefinitions: [Transcript.ToolDefinition]
    public var schema: GenerationSchema?
    public var generationOptions: GenerationOptions

    public init(
        id: UUID = UUID(),
        transcript: Transcript,
        enabledTools: [Transcript.ToolDefinition] = [],
        schema: GenerationSchema? = nil,
        generationOptions: GenerationOptions = GenerationOptions()
    ) {
        self.id = id
        self.transcript = transcript
        self.enabledToolDefinitions = enabledTools
        self.schema = schema
        self.generationOptions = generationOptions
    }
}

// MARK: - Generation channel

/// The stream executors write generation events into. The session consumes
/// the channel while the executor produces.
public struct LanguageModelExecutorGenerationChannel: Sendable {
    enum Event: Sendable {
        /// An incremental piece of response text.
        case textDelta(String)
        /// A complete tool invocation requested by the model.
        case toolCall(id: String, toolName: String, argumentsJSON: String)
    }

    let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func send(_ event: Event) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

// MARK: - Errors

public enum LanguageModelError: Error, CustomStringConvertible {
    case executorCreationFailed(underlying: any Error)
    case toolNotFound(String)
    case requestFailed(statusCode: Int, message: String)

    public var description: String {
        switch self {
        case .executorCreationFailed(let underlying):
            return "failed to create language model executor: \(underlying)"
        case .toolNotFound(let name):
            return "the model called tool '\(name)', which is not registered with the session"
        case .requestFailed(let statusCode, let message):
            return "language model request failed (HTTP \(statusCode)): \(message)"
        }
    }
}
