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
        public enum Kind: Sendable, Equatable {
            case greedy
            case randomTopK(_ topK: Int, seed: UInt64?)
            case randomProbabilityThreshold(_ probabilityThreshold: Double, seed: UInt64?)
        }
        public let kind: Kind

        public static var greedy: SamplingMode { SamplingMode(kind: .greedy) }

        public static func random(top k: Int, seed: UInt64? = nil) -> SamplingMode {
            SamplingMode(kind: .randomTopK(k, seed: seed))
        }

        public static func random(probabilityThreshold: Double, seed: UInt64? = nil) -> SamplingMode {
            SamplingMode(kind: .randomProbabilityThreshold(probabilityThreshold, seed: seed))
        }
    }

    public struct ToolCallingMode: Sendable, Equatable {
        public enum Kind: Sendable, Equatable, Hashable {
            case allowed
            case required
            case disallowed
        }
        public var kind: Kind

        public static let allowed = ToolCallingMode(kind: .allowed)
        public static let required = ToolCallingMode(kind: .required)
        public static let disallowed = ToolCallingMode(kind: .disallowed)
    }

    public var samplingMode: SamplingMode?

    /// Deprecated SDK-26 spelling of `samplingMode`, kept for source
    /// compatibility. New code should use `samplingMode`.
    public var sampling: SamplingMode? {
        get { samplingMode }
        set { samplingMode = newValue }
    }

    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var toolCallingMode: ToolCallingMode?

    public init(
        samplingMode: SamplingMode? = nil,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil
    ) {
        self.samplingMode = samplingMode
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }

    public init(
        sampling: SamplingMode?,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil
    ) {
        self.samplingMode = sampling
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }

    public init(
        samplingMode: SamplingMode? = nil,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        toolCallingMode: ToolCallingMode?
    ) {
        self.samplingMode = samplingMode
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.toolCallingMode = toolCallingMode
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
    let capabilities: Set<Capability>

    public init(capabilities: [Capability]) {
        self.capabilities = Set(capabilities)
    }

    /// Unlabeled convenience matching Apple's shipping initializer
    /// (`LanguageModelCapabilities([.toolCalling, ...])`) — used by providers
    /// such as ClaudeForFoundationModels. The reference `.swiftinterface`
    /// only lists the labeled form, but the shipping SDK accepts both.
    public init(_ capabilities: [Capability]) {
        self.capabilities = Set(capabilities)
    }

    public func contains(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }

    public struct Capability: Sendable, Hashable {
        let raw: String

        public static var vision: Capability { Capability(raw: "vision") }
        public static var guidedGeneration: Capability { Capability(raw: "guidedGeneration") }
        public static var reasoning: Capability { Capability(raw: "reasoning") }
        public static var toolCalling: Capability { Capability(raw: "toolCalling") }
    }
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

    public var contextOptions: ContextOptions = ContextOptions()
    public var metadata: [String: any Sendable & Codable & Equatable] = [:]

    /// Callable tools, for executors that run the tool loop natively
    /// (e.g. the SystemLanguageModel bridge). Most executors emit
    /// `.toolCall` events instead and let the session execute.
    var executableTools: [ErasedTool] = []

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

    public init(
        id: UUID,
        transcript: Transcript,
        enabledTools: [Transcript.ToolDefinition],
        schema: GenerationSchema? = nil,
        generationOptions: GenerationOptions,
        contextOptions: ContextOptions,
        metadata: [String: any Sendable & Codable & Equatable]
    ) {
        self.id = id
        self.transcript = transcript
        self.enabledToolDefinitions = enabledTools
        self.schema = schema
        self.generationOptions = generationOptions
        self.contextOptions = contextOptions
        self.metadata = metadata
    }
}

// MARK: - Errors

public enum LanguageModelError: LocalizedError, CustomDebugStringConvertible {
    case contextSizeExceeded(ContextSizeExceeded)
    case rateLimited(RateLimited)
    case guardrailViolation(GuardrailViolation)
    case refusal(Refusal)
    case unsupportedCapability(UnsupportedCapability)
    case unsupportedTranscriptContent(UnsupportedTranscriptContent)
    case unsupportedGenerationGuide(UnsupportedGenerationGuide)
    case unsupportedLanguageOrLocale(UnsupportedLanguageOrLocale)
    case timeout(Timeout)

    public struct ContextSizeExceeded: Sendable {
        public var contextSize: Int
        public var tokenCount: Int
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        public init(contextSize: Int, tokenCount: Int, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.contextSize = contextSize
            self.tokenCount = tokenCount
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct RateLimited: Sendable {
        public var resetDate: Date?
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        public init(resetDate: Date?, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.resetDate = resetDate
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct GuardrailViolation: Sendable {
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        public init(debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct Refusal: Sendable {
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        /// The conversation up to and including the refusal. Continuing it is
        /// how `explanation` produces a model-authored reason for the refusal.
        public var transcriptEntries: [Transcript.Entry]
        /// Set by `init(explanation:...)` (SDK 27 beta 4): a caller-supplied
        /// explanation returned as-is, with no model round-trip.
        let storedExplanation: String?

        public init(
            debugDescription: String,
            metadata: [String: any Sendable] = [:],
            transcriptEntries: [Transcript.Entry] = []
        ) {
            self.debugDescription = debugDescription
            self.metadata = metadata
            self.transcriptEntries = transcriptEntries
            self.storedExplanation = nil
        }

        public init(
            explanation: String,
            debugDescription: String,
            metadata: [String: any Sendable] = [:]
        ) {
            self.debugDescription = debugDescription
            self.metadata = metadata
            self.transcriptEntries = []
            self.storedExplanation = explanation
        }

        /// A model-generated explanation of the refusal, produced by continuing
        /// the refusing conversation on the default on-device model — or the
        /// caller-supplied explanation, verbatim, when one was provided.
        public var explanation: LanguageModelSession.Response<String> {
            get async throws {
                if let storedExplanation {
                    return LanguageModelSession.Response(
                        content: storedExplanation,
                        rawContent: GeneratedContent(storedExplanation),
                        transcriptEntries: ArraySlice(transcriptEntries),
                        usage: LanguageModelSession.Usage()
                    )
                }
                let session = LanguageModelSession(
                    model: SystemLanguageModel.default,
                    transcript: Transcript(entries: transcriptEntries)
                )
                return try await session.respond(
                    to: "Briefly explain why the previous request was declined."
                )
            }
        }

        public var explanationStream: LanguageModelSession.ResponseStream<String> {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                transcript: Transcript(entries: transcriptEntries)
            )
            return session.streamResponse(
                to: "Briefly explain why the previous request was declined."
            )
        }
    }

    public struct UnsupportedCapability: Sendable {
        public var capability: LanguageModelCapabilities.Capability
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        public init(capability: LanguageModelCapabilities.Capability, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.capability = capability
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct UnsupportedTranscriptContent: Sendable {
        public var unsupportedContent: [Transcript.Entry]
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        public init(unsupportedContent: [Transcript.Entry], debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.unsupportedContent = unsupportedContent
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct UnsupportedGenerationGuide: Sendable {
        public var schemaName: String?
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        public init(schemaName: String?, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.schemaName = schemaName
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct UnsupportedLanguageOrLocale: Sendable {
        public var languageCode: Locale.LanguageCode
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        public init(languageCode: Locale.LanguageCode, debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.languageCode = languageCode
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public struct Timeout: Sendable {
        public var debugDescription: String
        public var metadata: [String: any Sendable]
        public init(debugDescription: String, metadata: [String: any Sendable] = [:]) {
            self.debugDescription = debugDescription
            self.metadata = metadata
        }
    }

    public var debugDescription: String {
        switch self {
        case .contextSizeExceeded(let payload): return payload.debugDescription
        case .rateLimited(let payload): return payload.debugDescription
        case .guardrailViolation(let payload): return payload.debugDescription
        case .refusal(let payload): return payload.debugDescription
        case .unsupportedCapability(let payload): return payload.debugDescription
        case .unsupportedTranscriptContent(let payload): return payload.debugDescription
        case .unsupportedGenerationGuide(let payload): return payload.debugDescription
        case .unsupportedLanguageOrLocale(let payload): return payload.debugDescription
        case .timeout(let payload): return payload.debugDescription
        }
    }

    public var errorDescription: String? { debugDescription }
}

/// ServerFoundationModels-specific transport/configuration failures (not part of
/// Apple's error taxonomy).
public struct LanguageModelTransportError: Error, CustomStringConvertible {
    public let statusCode: Int
    public let message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var description: String {
        "language model request failed (HTTP \(statusCode)): \(message)"
    }
}


// MARK: - AnyTool

/// A type-erased tool.
public struct AnyTool: Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = Prompt

    let erased: ErasedTool

    public init(_ tool: some Tool) {
        self.erased = ErasedTool(tool)
    }

    public var name: String { erased.name }
    public var description: String { erased.description }
    public var parameters: GenerationSchema { erased.parameters }

    public func call(arguments: GeneratedContent) async throws -> Prompt {
        Prompt(text: try await erased.call(arguments))
    }
}
