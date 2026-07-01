// LanguageModelSession.DynamicProfile — per-request model/instructions/options
// selection, re-evaluated before every request (SDK 27).

import Foundation

extension LanguageModelSession {

    public protocol DynamicProfile {
        associatedtype Body: LanguageModelSession.DynamicProfile
        @LanguageModelSession.DynamicProfileBuilder var body: Body { get }
    }

    public struct Profile: LanguageModelSession.DynamicProfile {
        /// The instructions value, stored unresolved: instruction texts and
        /// tools are walked at profile-resolution time — once per request,
        /// inside the session's SessionPropertyValues binding — so
        /// `@SessionProperty`-driven instructions re-evaluate per request.
        let instructions: any DynamicInstructions

        var instructionsText: String {
            instructions.allInstructionTexts.joined(separator: "\n")
        }

        var instructionTools: [ErasedTool] {
            instructions.allInstructionTools
        }

        public init(@DynamicInstructionsBuilder _ dynamicInstructions: () -> some DynamicInstructions) {
            self.instructions = dynamicInstructions()
        }

        public var body: Never { fatalError("leaf DynamicProfile") }
        public typealias Body = Never
    }

    public struct ConditionalDynamicProfile<TrueContent: LanguageModelSession.DynamicProfile, FalseContent: LanguageModelSession.DynamicProfile>: LanguageModelSession.DynamicProfile {
        enum Branch {
            case trueContent(TrueContent)
            case falseContent(FalseContent)
        }
        let branch: Branch

        public var body: Never { fatalError("leaf DynamicProfile") }
        public typealias Body = Never
    }

    @resultBuilder
    public struct DynamicProfileBuilder {
        public static func buildBlock(_ content: Never) -> Never {
            switch content {}
        }

        public static func buildBlock<T: LanguageModelSession.DynamicProfile>(_ content: T) -> T {
            content
        }

        public static func buildEither<TrueContent, FalseContent>(
            first content: TrueContent
        ) -> ConditionalDynamicProfile<TrueContent, FalseContent> {
            ConditionalDynamicProfile(branch: .trueContent(content))
        }

        public static func buildEither<TrueContent, FalseContent>(
            second content: FalseContent
        ) -> ConditionalDynamicProfile<TrueContent, FalseContent> {
            ConditionalDynamicProfile(branch: .falseContent(content))
        }
    }

    public struct ModifiedDynamicProfile<Content: LanguageModelSession.DynamicProfile, Modifier: LanguageModelSession.DynamicProfileModifier>: LanguageModelSession.DynamicProfile {
        let content: Content
        let modifier: Modifier

        public var body: Never { fatalError("leaf DynamicProfile") }
        public typealias Body = Never
    }

    public protocol DynamicProfileModifier {
        associatedtype Body: LanguageModelSession.DynamicProfile
        @LanguageModelSession.DynamicProfileBuilder func body(content: Self.Content) -> Self.Body
        typealias Content = LanguageModelSession.DynamicProfileModifierContent<Self>
    }

    public struct DynamicProfileModifierContent<Modifier: LanguageModelSession.DynamicProfileModifier>: LanguageModelSession.DynamicProfile {
        let wrapped: any LanguageModelSession.DynamicProfile

        public var body: Never { fatalError("leaf DynamicProfile") }
        public typealias Body = Never
    }
}

extension Never: LanguageModelSession.DynamicProfile {}

extension LanguageModelSession.DynamicProfile {
    public typealias Profile = LanguageModelSession.Profile
    public typealias DynamicProfile = LanguageModelSession.DynamicProfile
}

extension LanguageModelSession.DynamicProfileModifier {
    public typealias Profile = LanguageModelSession.Profile
    public typealias DynamicProfile = LanguageModelSession.DynamicProfile
}

// MARK: - Built-in modifiers

struct PrimitiveProfileModifier: LanguageModelSession.DynamicProfileModifier {
    enum Kind {
        case model(perform: ErasedPerform, isSystemDefault: Bool)
        case temperature(Double?)
        case samplingMode(GenerationOptions.SamplingMode?)
        case maximumResponseTokens(Int?)
        case reasoningLevel(ContextOptions.ReasoningLevel?)
        case historyTransform(([Transcript.Entry]) -> [Transcript.Entry])
        case inputFilter(([Transcript.Entry]) -> [Transcript.Entry])
        case toolCallingMode(GenerationOptions.ToolCallingMode?)
        case transcriptErrorHandlingPolicy(TranscriptErrorHandlingPolicy?)
        case onPrompt((Transcript.Prompt) async throws -> Void)
        case onResponse((Transcript.Response) async throws -> Void)
        case onToolCall((Transcript.ToolCall) async throws -> Void)
        case onToolOutput((Transcript.ToolOutput) async throws -> Void)
        case onToolCallOutputPair((Transcript.ToolCall, Transcript.ToolOutput) async throws -> Void)
        case onActivate(() async -> Void)
        case onDeactivate(() async -> Void)
    }
    let kind: Kind

    func body(content: Content) -> Never { fatalError("primitive modifier") }
    typealias Body = Never
}

typealias ErasedPerform = @Sendable (
    LanguageModelExecutorGenerationRequest,
    LanguageModelExecutorGenerationChannel
) async throws -> Void

func erasePerform<Model: LanguageModel>(_ model: Model) -> ErasedPerform {
    let configuration = model.executorConfiguration
    return { request, channel in
        // Executors are cached process-wide by configuration: profile bodies
        // re-evaluate per request, and `.model(...)` must reuse the executor
        // (and its connection pool) rather than constructing a new one.
        let executor = try SharedExecutorRegistry.shared.executor(
            for: configuration, as: Model.Executor.self
        )
        try await executor.respond(to: request, model: model, streamingInto: channel)
    }
}

extension LanguageModelSession.DynamicProfile {
    public func modifier<Modifier: LanguageModelSession.DynamicProfileModifier>(
        _ modifier: Modifier
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(content: self, modifier: modifier)
    }

    public func model(_ model: some LanguageModel) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self,
            modifier: PrimitiveProfileModifier(kind: .model(perform: erasePerform(model), isSystemDefault: false))
        )
    }

    public func temperature(_ temperature: Double?) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .temperature(temperature))
        )
    }

    public func samplingMode(_ samplingMode: GenerationOptions.SamplingMode?) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .samplingMode(samplingMode))
        )
    }

    public func maximumResponseTokens(_ maximumResponseTokens: Int?) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .maximumResponseTokens(maximumResponseTokens))
        )
    }

    public func reasoningLevel(_ reasoningLevel: ContextOptions.ReasoningLevel?) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .reasoningLevel(reasoningLevel))
        )
    }

    public func historyTransform(
        _ transform: @escaping ([Transcript.Entry]) -> [Transcript.Entry]
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .historyTransform(transform))
        )
    }

    public func inputFilter(
        _ filter: @escaping ([Transcript.Entry]) -> [Transcript.Entry]
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .inputFilter(filter))
        )
    }

    public func toolCalling(_ toolCallingMode: GenerationOptions.ToolCallingMode?) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .toolCallingMode(toolCallingMode))
        )
    }

    public func toolCallingMode(_ toolCallingMode: GenerationOptions.ToolCallingMode?) -> some LanguageModelSession.DynamicProfile {
        toolCalling(toolCallingMode)
    }

    public func transcriptErrorHandlingPolicy(
        _ transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy?
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self,
            modifier: PrimitiveProfileModifier(kind: .transcriptErrorHandlingPolicy(transcriptErrorHandlingPolicy))
        )
    }

    public func onPrompt(
        perform action: @escaping (Transcript.Prompt) async throws -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .onPrompt(action))
        )
    }

    public func onPrompt(
        perform action: @escaping () async throws -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        onPrompt { _ in try await action() }
    }

    public func onResponse(
        perform action: @escaping (Transcript.Response) async throws -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .onResponse(action))
        )
    }

    public func onResponse(
        perform action: @escaping () async throws -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        onResponse { _ in try await action() }
    }

    public func onToolCall(
        perform action: @escaping (Transcript.ToolCall) async throws -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .onToolCall(action))
        )
    }

    public func onToolCall(
        perform action: @escaping () async throws -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        onToolCall { _ in try await action() }
    }

    public func onToolOutput(
        perform action: @escaping (Transcript.ToolOutput) async throws -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .onToolOutput(action))
        )
    }

    public func onToolOutput(
        perform action: @escaping () async throws -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        onToolOutput { _ in try await action() }
    }

    public func onToolOutput(
        perform action: @escaping (Transcript.ToolCall, Transcript.ToolOutput) async throws -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self,
            modifier: PrimitiveProfileModifier(kind: .onToolCallOutputPair(action))
        )
    }

    public func onActivate(
        perform action: @escaping () async -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .onActivate(action))
        )
    }

    public func onDeactivate(
        perform action: @escaping () async -> Void
    ) -> some LanguageModelSession.DynamicProfile {
        LanguageModelSession.ModifiedDynamicProfile(
            content: self, modifier: PrimitiveProfileModifier(kind: .onDeactivate(action))
        )
    }
}

// MARK: - Resolution

struct ResolvedProfile {
    var instructionsText: String?
    var tools: [ErasedTool] = []
    var perform: ErasedPerform?
    var temperature: Double?
    var samplingMode: GenerationOptions.SamplingMode?
    var maximumResponseTokens: Int?
    var toolCallingMode: GenerationOptions.ToolCallingMode?
    var reasoningLevel: ContextOptions.ReasoningLevel?
    var transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy?
    /// Persisted into the session transcript by `prepareTurn`.
    var historyTransform: (([Transcript.Entry]) -> [Transcript.Entry])?
    /// Applied only to the transcript copy sent with each request — never
    /// persisted, unlike `historyTransform`.
    var inputFilter: (([Transcript.Entry]) -> [Transcript.Entry])?
    var onPrompt: [(Transcript.Prompt) async throws -> Void] = []
    var onResponse: [(Transcript.Response) async throws -> Void] = []
    var onToolCall: [(Transcript.ToolCall) async throws -> Void] = []
    var onToolOutput: [(Transcript.ToolOutput) async throws -> Void] = []
    var onToolCallOutputPair: [(Transcript.ToolCall, Transcript.ToolOutput) async throws -> Void] = []
    var onActivate: [() async -> Void] = []
    var onDeactivate: [() async -> Void] = []
    /// True when this resolution passed through a custom modifier's
    /// `DynamicProfileModifierContent` placeholder — i.e. the modifier's
    /// body composed its wrapped content.
    var resolvedModifierContent = false
}

func resolveProfile(_ profile: some LanguageModelSession.DynamicProfile) -> ResolvedProfile {
    resolveAnyProfile(profile)
}

private func resolveAnyProfile(_ profile: any LanguageModelSession.DynamicProfile) -> ResolvedProfile {
    if let leaf = profile as? LanguageModelSession.Profile {
        var resolved = ResolvedProfile()
        resolved.instructionsText = leaf.instructionsText.isEmpty ? nil : leaf.instructionsText
        resolved.tools = leaf.instructionTools
        return resolved
    }
    if let resolvable = profile as? ResolvableDynamicProfile {
        return resolvable.resolveProfile()
    }
    return resolveAnyProfile(openProfileBody(profile))
}

private func openProfileBody<P: LanguageModelSession.DynamicProfile>(_ profile: P) -> any LanguageModelSession.DynamicProfile {
    profile.body
}

/// Composite nodes that resolve without going through `body`.
protocol ResolvableDynamicProfile {
    func resolveProfile() -> ResolvedProfile
}

extension LanguageModelSession.ConditionalDynamicProfile: ResolvableDynamicProfile {
    func resolveProfile() -> ResolvedProfile {
        switch branch {
        case .trueContent(let content): return resolveAnyProfile(content)
        case .falseContent(let content): return resolveAnyProfile(content)
        }
    }
}

extension LanguageModelSession.DynamicProfileModifierContent: ResolvableDynamicProfile {
    func resolveProfile() -> ResolvedProfile {
        var resolved = resolveAnyProfile(wrapped)
        resolved.resolvedModifierContent = true
        return resolved
    }
}

extension LanguageModelSession.ModifiedDynamicProfile: ResolvableDynamicProfile {
    func resolveProfile() -> ResolvedProfile {
        var resolved = resolveAnyProfile(content)
        if let primitive = modifier as? PrimitiveProfileModifier {
            switch primitive.kind {
            case .model(let perform, _): resolved.perform = perform
            case .temperature(let value): resolved.temperature = value
            case .samplingMode(let value): resolved.samplingMode = value
            case .maximumResponseTokens(let value): resolved.maximumResponseTokens = value
            case .reasoningLevel(let value): resolved.reasoningLevel = value
            case .historyTransform(let transform):
                let existing = resolved.historyTransform
                resolved.historyTransform = existing.map { first in { transform(first($0)) } } ?? transform
            case .inputFilter(let filter):
                let existing = resolved.inputFilter
                resolved.inputFilter = existing.map { first in { filter(first($0)) } } ?? filter
            case .toolCallingMode(let mode): resolved.toolCallingMode = mode
            case .transcriptErrorHandlingPolicy(let policy): resolved.transcriptErrorHandlingPolicy = policy
            case .onPrompt(let action): resolved.onPrompt.append(action)
            case .onResponse(let action): resolved.onResponse.append(action)
            case .onToolCall(let action): resolved.onToolCall.append(action)
            case .onToolOutput(let action): resolved.onToolOutput.append(action)
            case .onToolCallOutputPair(let action): resolved.onToolCallOutputPair.append(action)
            case .onActivate(let action): resolved.onActivate.append(action)
            case .onDeactivate(let action): resolved.onDeactivate.append(action)
            }
            return resolved
        }
        // Custom modifier: resolve its body around the content.
        let wrapped = LanguageModelSession.DynamicProfileModifierContent<Modifier>(wrapped: content)
        let bodyProfile = modifier.body(content: wrapped)
        var fromBody = resolveAnyProfile(bodyProfile)
        if fromBody.resolvedModifierContent {
            // The body composed `content`, so the wrapped resolution is
            // already folded in. Reset the marker for any enclosing modifier.
            fromBody.resolvedModifierContent = resolved.resolvedModifierContent
            return fromBody
        }
        // The body did NOT compose `content` (e.g. it returned a fresh
        // Profile): inherit every field the body left unset from the wrapped
        // content's resolution so tools, perform, options, and handlers are
        // not silently dropped.
        if fromBody.instructionsText == nil { fromBody.instructionsText = resolved.instructionsText }
        if fromBody.perform == nil { fromBody.perform = resolved.perform }
        if fromBody.temperature == nil { fromBody.temperature = resolved.temperature }
        if fromBody.samplingMode == nil { fromBody.samplingMode = resolved.samplingMode }
        if fromBody.maximumResponseTokens == nil { fromBody.maximumResponseTokens = resolved.maximumResponseTokens }
        if fromBody.toolCallingMode == nil { fromBody.toolCallingMode = resolved.toolCallingMode }
        if fromBody.reasoningLevel == nil { fromBody.reasoningLevel = resolved.reasoningLevel }
        if fromBody.transcriptErrorHandlingPolicy == nil {
            fromBody.transcriptErrorHandlingPolicy = resolved.transcriptErrorHandlingPolicy
        }
        if let contentTransform = resolved.historyTransform {
            let bodyTransform = fromBody.historyTransform
            fromBody.historyTransform = bodyTransform.map { second in { second(contentTransform($0)) } } ?? contentTransform
        }
        if let contentFilter = resolved.inputFilter {
            let bodyFilter = fromBody.inputFilter
            fromBody.inputFilter = bodyFilter.map { second in { second(contentFilter($0)) } } ?? contentFilter
        }
        fromBody.tools = resolved.tools + fromBody.tools
        fromBody.onPrompt = resolved.onPrompt + fromBody.onPrompt
        fromBody.onResponse = resolved.onResponse + fromBody.onResponse
        fromBody.onToolCall = resolved.onToolCall + fromBody.onToolCall
        fromBody.onToolOutput = resolved.onToolOutput + fromBody.onToolOutput
        fromBody.onToolCallOutputPair = resolved.onToolCallOutputPair + fromBody.onToolCallOutputPair
        fromBody.onActivate = resolved.onActivate + fromBody.onActivate
        fromBody.onDeactivate = resolved.onDeactivate + fromBody.onDeactivate
        fromBody.resolvedModifierContent = resolved.resolvedModifierContent
        return fromBody
    }
}

// MARK: - ContextOptions

public struct ContextOptions: Sendable, Equatable {
    public enum ReasoningLevel: Sendable, Equatable {
        case light
        case moderate
        case deep
        case custom(String)
    }

    public var includeSchemaInPrompt: Bool?
    public var reasoningLevel: ReasoningLevel?

    public init(includeSchemaInPrompt: Bool? = nil, reasoningLevel: ReasoningLevel? = nil) {
        self.includeSchemaInPrompt = includeSchemaInPrompt
        self.reasoningLevel = reasoningLevel
    }
}
