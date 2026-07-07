// LanguageModelSession — orchestrates prompts, the tool-call loop, transcript
// management, and streaming. Mirrors FoundationModels.LanguageModelSession
// (SDK 27), generic over any LanguageModel via the executor contract.

import Foundation
import Synchronization

/// @unchecked Sendable invariant: all mutable state lives in `state` and is
/// accessed only through `Mutex.withLock`. `Transcript` and `Usage` are
/// returned by copy; executor I/O runs in caller `async` contexts.
public final class LanguageModelSession: @unchecked Sendable {

    /// Mutable session fields guarded by a single `Mutex`.
    private struct LockedSessionState {
        var transcript: Transcript
        var isResponding = false
        var usage = Usage()
        var errorPolicy: TranscriptErrorHandlingPolicy?
    }

    // MARK: State

    private let state: Mutex<LockedSessionState>
    private let profileLock = NSLock()
    private var _lastResolvedProfile: ResolvedProfile?
    private var _profileActivated = false
    private var prewarmHint: @Sendable (Transcript) -> Void = { _ in }

    /// An optional caller-set label identifying this session's role (e.g.
    /// "team pillar", "identity"). Stamped onto every request's metadata so
    /// timelines and logs can attribute a request — and its tool calls — to
    /// the session that made it, instead of blurring all sessions on one model.
    public var timelineLabel: String?

    /// Hard cap on executor rounds per turn; only runaway tool loops hit it.
    static let maximumToolRounds = 64

    private let tools: [ErasedTool]
    private let toolDefinitions: [Transcript.ToolDefinition]
    private let perform: @Sendable (
        LanguageModelExecutorGenerationRequest,
        LanguageModelExecutorGenerationChannel
    ) async throws -> Void

    /// Set for profile-based sessions; re-evaluated before every request.
    var profileResolver: (() -> ResolvedProfile)?

    /// Session-scoped property storage, readable from tools and dynamic
    /// instructions via @SessionProperty.
    public let properties = SessionPropertyValues()

    var errorPolicy: TranscriptErrorHandlingPolicy? {
        get { state.withLock { $0.errorPolicy } }
        set { state.withLock { $0.errorPolicy = newValue } }
    }

    /// The conversation so far. Settable (SDK 27) — but only while the session
    /// is not responding; mutating it mid-response is a programmer error, since
    /// the in-flight turn is appending to the same transcript.
    public var transcript: Transcript {
        get { state.withLock { $0.transcript } }
        set {
            state.withLock {
                precondition(
                    !$0.isResponding,
                    "LanguageModelSession.transcript may only be set while isResponding == false"
                )
                $0.transcript = newValue
            }
        }
    }

    public var isResponding: Bool {
        state.withLock { $0.isResponding }
    }

    /// Cumulative token usage across all requests on this session.
    public var usage: Usage {
        state.withLock { $0.usage }
    }

    // MARK: Initializers

    public convenience init(
        model: some LanguageModel,
        tools: [any Tool] = [],
        instructions: Instructions? = nil
    ) {
        self.init(erasing: model, tools: tools, instructionsText: instructions?.text, transcript: nil)
    }

    @_disfavoredOverload
    public convenience init(
        model: some LanguageModel,
        tools: [any Tool] = [],
        instructions: String? = nil
    ) {
        self.init(erasing: model, tools: tools, instructionsText: instructions, transcript: nil)
    }

    public convenience init(
        model: some LanguageModel,
        tools: [any Tool] = [],
        @InstructionsBuilder instructions: () throws -> Instructions
    ) rethrows {
        self.init(erasing: model, tools: tools, instructionsText: try instructions().text, transcript: nil)
    }

    public convenience init(
        model: some LanguageModel,
        tools: [any Tool] = [],
        transcript: Transcript
    ) {
        self.init(erasing: model, tools: tools, instructionsText: nil, transcript: transcript)
    }

    public convenience init(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        instructions: Instructions? = nil
    ) {
        self.init(erasing: model, tools: tools, instructionsText: instructions?.text, transcript: nil)
    }

    @_disfavoredOverload
    public convenience init(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        instructions: String? = nil
    ) {
        self.init(erasing: model, tools: tools, instructionsText: instructions, transcript: nil)
    }

    public convenience init(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        @InstructionsBuilder instructions: () throws -> Instructions
    ) rethrows {
        self.init(erasing: model, tools: tools, instructionsText: try instructions().text, transcript: nil)
    }

    public convenience init(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        transcript: Transcript
    ) {
        self.init(erasing: model, tools: tools, instructionsText: nil, transcript: transcript)
    }

    public convenience init<Failure>(
        model: any LanguageModel,
        tools: [any Tool] = [],
        @InstructionsBuilder instructions: () throws(Failure) -> Instructions
    ) throws(Failure) where Failure: Swift.Error {
        let text = try instructions().text
        self.init(erasingAny: model, tools: tools, instructionsText: text)
    }

    private convenience init(erasingAny model: any LanguageModel, tools: [any Tool], instructionsText: String?) {
        func open<M: LanguageModel>(_ model: M) -> (
            perform: @Sendable (LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel) async throws -> Void,
            prewarm: @Sendable (Transcript) -> Void
        ) {
            (erasePerform(model), erasePrewarm(model))
        }
        self.init(erasing: SystemLanguageModel.default, tools: tools, instructionsText: instructionsText, transcript: nil)
        let dispatch = open(model)
        self.profileResolver = { [properties] in
            var resolved = SessionPropertyValues.$current.withValue(properties) {
                ResolvedProfile()
            }
            resolved.perform = dispatch.perform
            resolved.instructionsText = instructionsText
            return resolved
        }
        self.prewarmHint = dispatch.prewarm
    }

    /// A session driven by standalone dynamic instructions.
    public convenience init(
        model: some LanguageModel = SystemLanguageModel.default,
        dynamicInstructions: sending some DynamicInstructions,
        history: some Collection<Transcript.Entry> = []
    ) {
        self.init(
            erasing: model,
            tools: [],
            instructionsText: nil,
            transcript: Transcript(entries: Array(history))
        )
        let erased = AnyDynamicInstructions(dynamicInstructions)
        self.properties.rootDynamicInstructions = erased
        self.profileResolver = {
            var resolved = ResolvedProfile()
            let text = erased.allInstructionTexts.joined(separator: "\n")
            resolved.instructionsText = text.isEmpty ? nil : text
            // Tools declared in the body register with the session — same as
            // instruction texts, re-resolved every round. Dropping them here
            // once shipped sessions whose models silently never saw a tool.
            resolved.tools = erased.allInstructionTools
            return resolved
        }
    }

    /// A session whose model, instructions, and option overrides come from a
    /// dynamic profile, re-evaluated before every request.
    public convenience init(
        profile: sending some DynamicProfile,
        history: some Collection<Transcript.Entry> = []
    ) {
        self.init(erasing: SystemLanguageModel.default, tools: [], instructionsText: nil, transcript: Transcript(entries: Array(history)))
        self.profileResolver = { resolveProfile(profile) }
    }

    private init<Model: LanguageModel>(
        erasing model: Model,
        tools: [any Tool],
        instructionsText: String?,
        transcript: Transcript?
    ) {
        // One executor per unique configuration, created lazily and reused —
        // matching the framework's documented caching contract. The registry
        // is shared process-wide so re-evaluated profiles and multiple
        // sessions never construct duplicate executors for one configuration.
        self.perform = erasePerform(model)
        self.prewarmHint = erasePrewarm(model)

        self.tools = tools.map { ErasedTool($0) }
        self.toolDefinitions = self.tools.map {
            Transcript.ToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters)
        }

        var initialTranscript = transcript ?? Transcript()
        if let instructionsText {
            initialTranscript.append(.instructions(Transcript.Instructions(
                segments: [.text(.init(content: instructionsText))],
                toolDefinitions: toolDefinitions
            )))
        }
        self.state = Mutex(LockedSessionState(transcript: initialTranscript))
    }

    public func prewarm(promptPrefix: Prompt? = nil) {
        var prewarmTranscript = transcript
        if let promptPrefix {
            prewarmTranscript.append(.prompt(Transcript.Prompt(
                segments: [.text(.init(content: promptPrefix.text))]
            )))
        }
        let hint = prewarmHint
        Task.detached { hint(prewarmTranscript) }
    }

    // MARK: Respond — plain text

    public func respond(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<String> {
        try await respond(to: prompt, options: options, contextOptions: ContextOptions(), metadata: [:])
    }

    public func streamResponse(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) -> ResponseStream<String> {
        streamResponse(to: prompt, options: options, contextOptions: ContextOptions(), metadata: [:])
    }

    public func streamResponse(
        to prompt: Prompt,
        options: GenerationOptions = GenerationOptions()
    ) -> ResponseStream<String> {
        streamResponse(to: prompt.text, options: options, contextOptions: ContextOptions(), metadata: [:])
    }

    public func respond(
        to prompt: String,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) async throws -> Response<String> {
        let promptEntry = Transcript.Entry.prompt(Transcript.Prompt(
            metadata: metadata,
            segments: [.text(.init(content: prompt))],
            options: options,
            contextOptions: contextOptions
        ))
        return try await withTurn(appending: promptEntry) { preCount in
            let result = try await generateLoop(
                schema: nil, options: options,
                contextOptions: contextOptions, metadata: metadata,
                onCumulativeText: nil
            )

            let responseEntry = Transcript.Response(
                metadata: result.usage.metadata,
                segments: transcriptResponseSegments(from: result)
            )
            appendEntry(.response(responseEntry))
            try await notifyResponse(responseEntry)
            return Response(
                content: result.text,
                rawContent: result.text.generatedContent,
                transcriptEntries: turnEntries(from: promptEntry.id, fallbackPreCount: preCount),
                usage: result.usage
            )
        }
    }

    // MARK: Respond — structured

    public func respond(
        to prompt: String,
        schema: GenerationSchema,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) async throws -> Response<GeneratedContent> {
        try await respondStructured(
            to: prompt, schema: schema,
            includeSchemaInPrompt: contextOptions.includeSchemaInPrompt ?? true,
            options: options, contextOptions: contextOptions, metadata: metadata
        )
    }

    public func respond(
        to prompt: String,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<GeneratedContent> {
        try await respondStructured(
            to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt,
            options: options, contextOptions: ContextOptions(), metadata: [:]
        )
    }

    private func respondStructured(
        to prompt: String,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool? = nil,
        options: GenerationOptions,
        contextOptions: ContextOptions,
        metadata: [String: any Sendable & Codable & Equatable]
    ) async throws -> Response<GeneratedContent> {
        var contextOptions = contextOptions
        contextOptions.includeSchemaInPrompt = contextOptions.includeSchemaInPrompt ?? includeSchemaInPrompt
        let promptEntry = Transcript.Entry.prompt(Transcript.Prompt(
            metadata: metadata,
            segments: [.text(.init(content: prompt))],
            options: options,
            responseFormat: Transcript.ResponseFormat(schema: schema),
            contextOptions: contextOptions
        ))
        return try await withTurn(appending: promptEntry) { preCount in
            let result = try await generateLoop(
                schema: schema, options: options,
                contextOptions: contextOptions, metadata: metadata,
                onCumulativeText: nil
            )
            let content = try GeneratedContent(json: Self.stripCodeFences(from: result.finalRoundText))

            let responseEntry = Transcript.Response(
                metadata: result.usage.metadata,
                segments: transcriptResponseSegments(
                    from: result,
                    replacingTextWith: .structure(.init(content: content))
                )
            )
            appendEntry(.response(responseEntry))
            try await notifyResponse(responseEntry)
            return Response(
                content: content,
                rawContent: content,
                transcriptEntries: turnEntries(from: promptEntry.id, fallbackPreCount: preCount),
                usage: result.usage
            )
        }
    }

    // MARK: Respond — typed Generable

    public func respond<Content>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) async throws -> Response<Content> where Content: Generable {
        try await respondTyped(
            to: prompt, generating: type,
            options: options, contextOptions: contextOptions, metadata: metadata
        )
    }

    public func respond<Content>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<Content> where Content: Generable {
        try await respondTyped(
            to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt,
            options: options, contextOptions: ContextOptions(), metadata: [:]
        )
    }

    private func respondTyped<Content>(
        to prompt: String,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool? = nil,
        options: GenerationOptions,
        contextOptions: ContextOptions,
        metadata: [String: any Sendable & Codable & Equatable]
    ) async throws -> Response<Content> where Content: Generable {
        var contextOptions = contextOptions
        contextOptions.includeSchemaInPrompt = contextOptions.includeSchemaInPrompt ?? includeSchemaInPrompt
        let schema = Content.generationSchema
        let promptEntry = Transcript.Entry.prompt(Transcript.Prompt(
            metadata: metadata,
            segments: [.text(.init(content: prompt))],
            options: options,
            responseFormat: Transcript.ResponseFormat(schema: schema),
            contextOptions: contextOptions
        ))
        return try await withTurn(appending: promptEntry) { preCount in
            let result = try await generateLoop(
                schema: schema, options: options,
                contextOptions: contextOptions, metadata: metadata,
                onCumulativeText: nil
            )
            let raw: GeneratedContent
            let content: Content
            do {
                raw = try GeneratedContent(json: Self.stripCodeFences(from: result.finalRoundText))
                content = try Content(raw)
            } catch {
                throw GenerationError.decodingFailure(.init(
                    debugDescription: "failed to decode \(Content.self) from response (\(error)); response text: '\(result.finalRoundText.prefix(2000))'"
                ))
            }

            let responseEntry = Transcript.Response(
                metadata: result.usage.metadata,
                segments: transcriptResponseSegments(
                    from: result,
                    replacingTextWith: .structure(.init(content: raw))
                )
            )
            appendEntry(.response(responseEntry))
            try await notifyResponse(responseEntry)
            return Response(
                content: content,
                rawContent: raw,
                transcriptEntries: turnEntries(from: promptEntry.id, fallbackPreCount: preCount),
                usage: result.usage
            )
        }
    }

    // MARK: Streaming

    public func streamResponse(
        to prompt: String,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) -> ResponseStream<String> {
        // Snapshots are cumulative, so coalescing to the newest one is safe
        // and bounds buffering for slow consumers (each snapshot carries the
        // full content so far). The terminal snapshot is always the last
        // element buffered before finish, so `collect()` still observes it.
        let (stream, continuation) = AsyncThrowingStream<ResponseStream<String>.Snapshot, any Swift.Error>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        let promptEntry = Transcript.Entry.prompt(Transcript.Prompt(
            metadata: metadata,
            segments: [.text(.init(content: prompt))],
            options: options,
            contextOptions: contextOptions
        ))

        let generation = Task {
            do {
                try await withTurn(appending: promptEntry) { preCount in
                    let result = try await generateLoop(
                        schema: nil, options: options,
                        contextOptions: contextOptions, metadata: metadata
                    ) { cumulative, _ in
                        continuation.yield(ResponseStream<String>.Snapshot(
                            content: cumulative,
                            rawContent: cumulative.generatedContent
                        ))
                    }

                    let responseEntry = Transcript.Response(
                        metadata: result.usage.metadata,
                        segments: transcriptResponseSegments(from: result)
                    )
                    appendEntry(.response(responseEntry))
                    try await notifyResponse(responseEntry)
                    continuation.yield(ResponseStream<String>.Snapshot(
                        content: result.text,
                        rawContent: result.text.generatedContent,
                        transcriptEntries: turnEntries(from: promptEntry.id, fallbackPreCount: preCount),
                        usage: result.usage
                    ))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { reason in
            if case .cancelled = reason { generation.cancel() }
        }
        return ResponseStream(stream: stream)
    }

    // MARK: Streaming — typed Generable

    public func streamResponse<Content>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) -> ResponseStream<Content> where Content: Generable {
        streamTyped(to: prompt, generating: type, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func streamResponse<Content>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) -> ResponseStream<Content> where Content: Generable {
        streamTyped(
            to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt,
            options: options, contextOptions: ContextOptions(), metadata: [:]
        )
    }

    private func streamTyped<Content>(
        to prompt: String,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool? = nil,
        options: GenerationOptions,
        contextOptions: ContextOptions,
        metadata: [String: any Sendable & Codable & Equatable]
    ) -> ResponseStream<Content> where Content: Generable {
        // Coalescable cumulative snapshots: see the plain streaming path.
        let (stream, continuation) = AsyncThrowingStream<ResponseStream<Content>.Snapshot, any Swift.Error>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        var contextOptions = contextOptions
        contextOptions.includeSchemaInPrompt = contextOptions.includeSchemaInPrompt ?? includeSchemaInPrompt
        let effectiveContextOptions = contextOptions
        let schema = Content.generationSchema
        let promptEntry = Transcript.Entry.prompt(Transcript.Prompt(
            metadata: metadata,
            segments: [.text(.init(content: prompt))],
            options: options,
            responseFormat: Transcript.ResponseFormat(schema: schema),
            contextOptions: effectiveContextOptions
        ))

        let generation = Task {
            do {
                try await withTurn(appending: promptEntry) { preCount in
                    let result = try await generateLoop(
                        schema: schema, options: options,
                        contextOptions: effectiveContextOptions, metadata: metadata
                    ) { _, roundText in
                        guard let partialRaw = GeneratedContent.partial(json: Self.stripCodeFences(from: roundText)),
                            let partial = try? Content.PartiallyGenerated(partialRaw)
                        else { return }
                        continuation.yield(ResponseStream<Content>.Snapshot(
                            content: partial,
                            rawContent: partialRaw
                        ))
                    }

                    let raw: GeneratedContent
                    let final: Content.PartiallyGenerated
                    do {
                        raw = try GeneratedContent(json: Self.stripCodeFences(from: result.finalRoundText))
                        final = try Content.PartiallyGenerated(raw)
                    } catch {
                        throw GenerationError.decodingFailure(.init(
                            debugDescription: "failed to decode \(Content.self) from streamed response (\(error))"
                        ))
                    }
                    let responseEntry = Transcript.Response(
                        metadata: result.usage.metadata,
                        segments: transcriptResponseSegments(
                            from: result,
                            replacingTextWith: .structure(.init(content: raw))
                        )
                    )
                    appendEntry(.response(responseEntry))
                    try await notifyResponse(responseEntry)
                    continuation.yield(ResponseStream<Content>.Snapshot(
                        content: final,
                        rawContent: raw,
                        transcriptEntries: turnEntries(from: promptEntry.id, fallbackPreCount: preCount),
                        usage: result.usage
                    ))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { reason in
            if case .cancelled = reason { generation.cancel() }
        }
        return ResponseStream(stream: stream)
    }

    public func streamResponse<Content>(
        to prompt: Prompt,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) -> ResponseStream<Content> where Content: Generable {
        streamResponse(to: prompt.text, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    public func streamResponse<Content>(
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) rethrows -> ResponseStream<Content> where Content: Generable {
        streamResponse(to: try prompt().text, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    // MARK: Prompt-typed and builder overloads (full SDK 27 matrix)

    public func respond(
        to prompt: Prompt,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) async throws -> Response<String> {
        try await respond(to: prompt.text, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func respond(
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:],
        @PromptBuilder prompt: () throws -> Prompt
    ) async throws -> Response<String> {
        try await respond(to: try prompt().text, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func respond(
        to prompt: Prompt,
        schema: GenerationSchema,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) async throws -> Response<GeneratedContent> {
        try await respond(to: prompt.text, schema: schema, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func respond(
        schema: GenerationSchema,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:],
        @PromptBuilder prompt: () throws -> Prompt
    ) async throws -> Response<GeneratedContent> {
        try await respond(to: try prompt().text, schema: schema, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func respond<Content>(
        to prompt: Prompt,
        generating type: Content.Type = Content.self,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) async throws -> Response<Content> where Content: Generable {
        try await respond(to: prompt.text, generating: type, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func respond<Content>(
        generating type: Content.Type = Content.self,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:],
        @PromptBuilder prompt: () throws -> Prompt
    ) async throws -> Response<Content> where Content: Generable {
        try await respond(to: try prompt().text, generating: type, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func streamResponse(
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:],
        @PromptBuilder prompt: () throws -> Prompt
    ) rethrows -> ResponseStream<String> {
        streamResponse(to: try prompt().text, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func streamResponse(
        to prompt: String,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) -> ResponseStream<GeneratedContent> {
        streamStructured(
            to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt,
            options: options, contextOptions: ContextOptions(), metadata: [:]
        )
    }

    public func streamResponse(
        to prompt: String,
        schema: GenerationSchema,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) -> ResponseStream<GeneratedContent> {
        streamStructured(to: prompt, schema: schema, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func streamResponse(
        to prompt: Prompt,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) -> ResponseStream<GeneratedContent> {
        streamStructured(
            to: prompt.text, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt,
            options: options, contextOptions: ContextOptions(), metadata: [:]
        )
    }

    public func streamResponse(
        to prompt: Prompt,
        schema: GenerationSchema,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) -> ResponseStream<GeneratedContent> {
        streamStructured(to: prompt.text, schema: schema, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func streamResponse(
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) rethrows -> ResponseStream<GeneratedContent> {
        streamStructured(
            to: try prompt().text, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt,
            options: options, contextOptions: ContextOptions(), metadata: [:]
        )
    }

    public func streamResponse(
        schema: GenerationSchema,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:],
        @PromptBuilder prompt: () throws -> Prompt
    ) rethrows -> ResponseStream<GeneratedContent> {
        streamStructured(to: try prompt().text, schema: schema, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    /// GeneratedContent-typed streaming over an explicit schema.
    private func streamStructured(
        to prompt: String,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool? = nil,
        options: GenerationOptions,
        contextOptions: ContextOptions,
        metadata: [String: any Sendable & Codable & Equatable]
    ) -> ResponseStream<GeneratedContent> {
        // Coalescable cumulative snapshots: see the plain streaming path.
        let (stream, continuation) = AsyncThrowingStream<ResponseStream<GeneratedContent>.Snapshot, any Swift.Error>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        var contextOptions = contextOptions
        contextOptions.includeSchemaInPrompt = contextOptions.includeSchemaInPrompt ?? includeSchemaInPrompt
        let effectiveContextOptions = contextOptions
        let promptEntry = Transcript.Entry.prompt(Transcript.Prompt(
            metadata: metadata,
            segments: [.text(.init(content: prompt))],
            options: options,
            responseFormat: Transcript.ResponseFormat(schema: schema),
            contextOptions: effectiveContextOptions
        ))
        let generation = Task {
            do {
                try await withTurn(appending: promptEntry) { preCount in
                    let result = try await generateLoop(
                        schema: schema, options: options,
                        contextOptions: effectiveContextOptions, metadata: metadata
                    ) { _, roundText in
                        if let partial = GeneratedContent.partial(json: Self.stripCodeFences(from: roundText)) {
                            continuation.yield(ResponseStream<GeneratedContent>.Snapshot(
                                content: partial, rawContent: partial
                            ))
                        }
                    }
                    let raw = try GeneratedContent(json: Self.stripCodeFences(from: result.finalRoundText))
                    let responseEntry = Transcript.Response(
                        metadata: result.usage.metadata,
                        segments: transcriptResponseSegments(
                            from: result,
                            replacingTextWith: .structure(.init(content: raw))
                        )
                    )
                    appendEntry(.response(responseEntry))
                    try await notifyResponse(responseEntry)
                    continuation.yield(ResponseStream<GeneratedContent>.Snapshot(
                        content: raw, rawContent: raw,
                        transcriptEntries: turnEntries(from: promptEntry.id, fallbackPreCount: preCount),
                        usage: result.usage
                    ))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { reason in
            if case .cancelled = reason { generation.cancel() }
        }
        return ResponseStream(stream: stream)
    }

    public func streamResponse<Content>(
        to prompt: Prompt,
        generating type: Content.Type = Content.self,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) -> ResponseStream<Content> where Content: Generable {
        streamTyped(to: prompt.text, generating: type, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func streamResponse<Content>(
        generating type: Content.Type = Content.self,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:],
        @PromptBuilder prompt: () throws -> Prompt
    ) rethrows -> ResponseStream<Content> where Content: Generable {
        streamTyped(to: try prompt().text, generating: type, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    // MARK: Prompt-typed and builder overloads

    public func respond(
        to prompt: Prompt,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<String> {
        try await respond(to: prompt.text, options: options)
    }

    public func respond(
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) async throws -> Response<String> {
        try await respond(to: try prompt().text, options: options)
    }

    public func respond(
        to prompt: Prompt,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<GeneratedContent> {
        try await respond(to: prompt.text, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    public func respond(
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) async throws -> Response<GeneratedContent> {
        try await respond(to: try prompt().text, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    public func respond<Content>(
        to prompt: Prompt,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<Content> where Content: Generable {
        try await respond(to: prompt.text, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    public func respond<Content>(
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) async throws -> Response<Content> where Content: Generable {
        try await respond(to: try prompt().text, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    public func streamResponse(
        to prompt: Prompt,
        options: GenerationOptions = GenerationOptions(),
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) -> ResponseStream<String> {
        streamResponse(to: prompt.text, options: options, contextOptions: contextOptions, metadata: metadata)
    }

    public func streamResponse(
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) rethrows -> ResponseStream<String> {
        streamResponse(to: try prompt().text, options: options)
    }

    // MARK: Generation loop

    /// Runs executor requests until the model produces a final response,
    /// executing tool calls between rounds and recording them in the transcript.
    struct LoopResult {
        /// Text across all rounds of the turn (tool-call preambles included),
        /// joined with newlines.
        var text: String
        /// Text of the final round only — what structured paths decode.
        var finalRoundText: String
        /// Ordered response segments from the final round (custom server-tool
        /// activity interleaved with text), when the executor emitted them.
        var responseSegments: [Transcript.Segment]
        var usage: Usage
    }

    /// Builds transcript response segments, preferring the executor's ordered
    /// segment list and optionally replacing trailing text with structured content.
    private func transcriptResponseSegments(
        from result: LoopResult,
        replacingTextWith replacement: Transcript.Segment? = nil
    ) -> [Transcript.Segment] {
        var segments = result.responseSegments
        if let replacement {
            if let lastText = segments.indices.last, case .text = segments[lastText] {
                segments[lastText] = replacement
            } else {
                segments.append(replacement)
            }
            return segments
        }
        if !segments.isEmpty { return segments }
        if !result.finalRoundText.isEmpty {
            return [.text(.init(content: result.finalRoundText))]
        }
        return []
    }

    /// Resolves the dynamic profile for a new prompt, persisting its history
    /// transform and refreshed instructions entry into the stored transcript —
    /// matching the framework: the transcript IS the post-profile state.
    /// The returned transcript is what the request must send: it additionally
    /// has the profile's input filter applied, which is never persisted.
    private func prepareTurn(options: GenerationOptions, firstRound: Bool = true) async throws -> (ResolvedProfile?, GenerationOptions, Transcript) {
        var allEntries = transcript.allEntries
        let instructionEntries = allEntries.filter { if case .instructions = $0 { return true }; return false }
        allEntries.removeAll { if case .instructions = $0 { return true }; return false }

        // History modifiers read and write the conversational history through
        // the session's `history` property during resolution; the session
        // adopts whatever they leave behind.
        properties.history = allEntries[...]
        guard let profileResolver else {
            profileLock.withLock { _lastResolvedProfile = nil }
            return (nil, options, transcript)
        }
        let resolved = SessionPropertyValues.$current.withValue(properties) { profileResolver() }

        // Profile activation contract: the first resolution invokes
        // `onActivate` handlers. Without a stable profile identity key,
        // later re-resolutions are treated as the same profile (no
        // deactivate/activate cycle). Handlers run outside the lock.
        var activateHandlers: [() async -> Void] = []
        profileLock.withLock {
            _lastResolvedProfile = resolved
            if !_profileActivated {
                _profileActivated = true
                activateHandlers = resolved.onActivate
            }
        }
        for action in activateHandlers { await action() }

        // onPrompt callbacks run with the session's properties bound so
        // history modifiers (e.g. rolling windows) can rewrite `history`;
        // the session then adopts whatever they leave behind.
        if firstRound, case .prompt(let promptEntry)? = allEntries.last {
            try await SessionPropertyValues.$current.withValue(properties) {
                for action in resolved.onPrompt { try await action(promptEntry) }
            }
        }
        var entries = Array(properties.history)

        if let transform = resolved.historyTransform {
            entries = transform(entries)
            switch entries.last {
            case .prompt, .toolOutput:
                break
            default:
                throw SessionControlError(reason: .invalidTranscript(
                    description: "Transcript must end with a .prompt or .toolOutput entry."
                ))
            }
        }

        let activeTools = tools + resolved.tools
        if let instructionsText = resolved.instructionsText {
            entries.insert(.instructions(Transcript.Instructions(
                segments: [.text(.init(content: instructionsText))],
                toolDefinitions: activeTools.map {
                    Transcript.ToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters)
                }
            )), at: 0)
        } else {
            entries.insert(contentsOf: instructionEntries, at: 0)
        }
        replaceTranscript(Transcript(entries: entries))

        // The input filter shapes only the transcript copy sent with this
        // request — unlike the history transform, it is never persisted.
        var requestEntries = entries
        if let filter = resolved.inputFilter {
            let requestInstructions = requestEntries.filter {
                if case .instructions = $0 { return true }; return false
            }
            var filtered = requestEntries.filter {
                if case .instructions = $0 { return false }; return true
            }
            filtered = filter(filtered)
            switch filtered.last {
            case .prompt, .toolOutput:
                break
            default:
                throw SessionControlError(reason: .invalidTranscript(
                    description: "Transcript must end with a .prompt or .toolOutput entry."
                ))
            }
            requestEntries = requestInstructions + filtered
        }

        var effectiveOptions = options
        if effectiveOptions.temperature == nil { effectiveOptions.temperature = resolved.temperature }
        if effectiveOptions.samplingMode == nil { effectiveOptions.samplingMode = resolved.samplingMode }
        if effectiveOptions.maximumResponseTokens == nil {
            effectiveOptions.maximumResponseTokens = resolved.maximumResponseTokens
        }
        if effectiveOptions.toolCallingMode == nil {
            effectiveOptions.toolCallingMode = resolved.toolCallingMode
        }
        if let policy = resolved.transcriptErrorHandlingPolicy {
            errorPolicy = policy
        }
        return (resolved, effectiveOptions, Transcript(entries: requestEntries))
    }

    private func generateLoop(
        schema: GenerationSchema?,
        options: GenerationOptions,
        contextOptions: ContextOptions = ContextOptions(),
        metadata: [String: any Sendable & Codable & Equatable] = [:],
        onCumulativeText: (@Sendable (_ cumulativeText: String, _ roundText: String) -> Void)?
    ) async throws -> LoopResult {
        var turnUsage = Usage()
        var firstRound = true
        // Text from earlier rounds of this turn (tool-call preambles); the
        // cumulative stream is `completedRoundsText` + the current round's
        // text so streamed snapshots never regress when a new round starts.
        var completedRoundsText = ""
        var rounds = 0

        func joinedRounds(_ earlier: String, _ current: String) -> String {
            if earlier.isEmpty { return current }
            if current.isEmpty { return earlier }
            return earlier + "\n" + current
        }

        while true {
            rounds += 1
            if rounds > Self.maximumToolRounds {
                throw SessionControlError(reason: .toolLoopLimitReached(limit: Self.maximumToolRounds))
            }
            // The profile is dynamic: it re-resolves before every round, so a
            // tool that changes state mid-loop (e.g. activating a skill)
            // refreshes the instructions for the continuation request.
            let (resolved, effectiveOptions, requestTranscript) = try await prepareTurn(options: options, firstRound: firstRound)
            firstRound = false
            let activeTools = tools + (resolved?.tools ?? [])
            let activeToolDefinitions = activeTools.map {
                Transcript.ToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters)
            }

            let channel = LanguageModelExecutorGenerationChannel()
            var request = LanguageModelExecutorGenerationRequest(
                transcript: requestTranscript,
                enabledTools: activeToolDefinitions,
                schema: schema,
                generationOptions: effectiveOptions
            )
            request.contextOptions = ContextOptions(
                includeSchemaInPrompt: contextOptions.includeSchemaInPrompt,
                reasoningLevel: contextOptions.reasoningLevel ?? resolved?.reasoningLevel
            )
            request.metadata = metadata
            // Attribute the request to its session, without overriding a
            // label a caller set explicitly per request.
            if let timelineLabel, request.metadata["timeline.session"] == nil {
                request.metadata["timeline.session"] = timelineLabel
            }
            request.executableTools = activeTools

            let perform = resolved?.perform ?? self.perform
            let properties = self.properties
            let executorTask = Task {
                defer { channel.finish() }
                try await SessionPropertyValues.$current.withValue(properties) {
                    try await perform(request, channel)
                }
            }

            var text = ""
            var reasoning = ""
            var reasoningSignature: Data?
            var usage = Usage()
            var toolCallOrder: [String] = []
            var toolCallAccumulator: [String: (name: String, argumentsJSON: String)] = [:]
            var recordedCalls: [Transcript.ToolCall] = []
            var recordedOutputs: [Transcript.ToolOutput] = []
            var responseSegments: [Transcript.Segment] = []
            var customSegmentIndices: [String: Int] = [:]
            var attachmentSegmentIndices: [String: Int] = [:]
            var responseMetadata: [String: any Sendable & Codable & Equatable] = [:]

            func upsertCustomSegment(_ segment: any Transcript.CustomSegment) {
                if let index = customSegmentIndices[segment.id] {
                    responseSegments[index] = .custom(segment)
                } else {
                    customSegmentIndices[segment.id] = responseSegments.count
                    responseSegments.append(.custom(segment))
                }
            }

            func appendResponseText(_ fragment: String) {
                guard !fragment.isEmpty else { return }
                if case .text(var existing) = responseSegments.last {
                    existing.content += fragment
                    responseSegments[responseSegments.count - 1] = .text(existing)
                } else {
                    responseSegments.append(.text(.init(content: fragment)))
                }
            }

            func upsertAttachmentSegment(_ segment: Transcript.AttachmentSegment) {
                if let index = attachmentSegmentIndices[segment.id] {
                    responseSegments[index] = .attachment(segment)
                } else {
                    attachmentSegmentIndices[segment.id] = responseSegments.count
                    responseSegments.append(.attachment(segment))
                }
            }

            func removeAttachmentSegment(id: String) {
                guard let index = attachmentSegmentIndices[id] else { return }
                responseSegments.remove(at: index)
                attachmentSegmentIndices.removeValue(forKey: id)
                attachmentSegmentIndices = attachmentSegmentIndices.mapValues { $0 > index ? $0 - 1 : $0 }
                customSegmentIndices = customSegmentIndices.mapValues { $0 > index ? $0 - 1 : $0 }
            }

            // Streamed usage reports are running totals: the latest report
            // for the round wins; rounds add together for the turn.
            func accumulate(_ reported: LanguageModelExecutorGenerationChannel.Usage) {
                usage.input.totalTokenCount = reported.input.totalTokenCount
                usage.input.cachedTokenCount = reported.input.cachedTokenCount
                usage.output.totalTokenCount = reported.output.totalTokenCount
                usage.output.reasoningTokenCount = reported.output.reasoningTokenCount
            }

            for await event in channel.stream {
                switch event {
                case let response as LanguageModelExecutorGenerationChannel.Response:
                    switch response.action {
                    case .appendText(let fragment):
                        text += fragment.content
                        appendResponseText(fragment.content)
                        onCumulativeText?(joinedRounds(completedRoundsText, text), text)
                    case .replaceTextSegment(let replacement):
                        text = replacement.content
                        if case .text(var existing) = responseSegments.last {
                            existing.content = replacement.content
                            responseSegments[responseSegments.count - 1] = .text(existing)
                        } else {
                            responseSegments.append(.text(.init(content: replacement.content)))
                        }
                        onCumulativeText?(joinedRounds(completedRoundsText, text), text)
                    case .updateCustomSegment(let segment):
                        upsertCustomSegment(segment)
                    case .updateUsage(let reported):
                        accumulate(reported)
                    case .addAttachmentSegment(let segment):
                        upsertAttachmentSegment(segment)
                    case .removeAttachmentSegment(let id):
                        removeAttachmentSegment(id: id)
                    case .updateMetadata(let reported):
                        responseMetadata.merge(reported.values) { _, new in new }
                    }
                case let reasoningEvent as LanguageModelExecutorGenerationChannel.Reasoning:
                    switch reasoningEvent.action {
                    case .appendText(let fragment):
                        reasoning += fragment.content
                    case .replaceTextSegment(let replacement):
                        reasoning = replacement.content
                    case .updateUsage(let reported):
                        accumulate(reported)
                    case .updateSignature(let signature):
                        reasoningSignature = signature.signature
                    case .updateMetadata:
                        break
                    }
                case let toolEvent as LanguageModelExecutorGenerationChannel.ToolCalls:
                    switch toolEvent.action {
                    case .toolCall(let call):
                        var accumulated = toolCallAccumulator[call.id] ?? (name: call.name, argumentsJSON: "")
                        if toolCallAccumulator[call.id] == nil { toolCallOrder.append(call.id) }
                        if !call.name.isEmpty { accumulated.name = call.name }
                        if case .appendArguments(let fragment) = call.action {
                            accumulated.argumentsJSON += fragment.content
                        }
                        toolCallAccumulator[call.id] = accumulated
                    case .removeToolCall(let id):
                        toolCallAccumulator.removeValue(forKey: id)
                        toolCallOrder.removeAll { $0 == id }
                    case .updateUsage(let reported):
                        accumulate(reported)
                    case .updateMetadata:
                        break
                    }
                case let recorded as RecordedToolExecution:
                    let arguments = (try? GeneratedContent(json: recorded.argumentsJSON))
                        ?? GeneratedContent(properties: [:])
                    recordedCalls.append(Transcript.ToolCall(
                        id: recorded.id, toolName: recorded.toolName, arguments: arguments
                    ))
                    recordedOutputs.append(Transcript.ToolOutput(
                        id: recorded.id,
                        toolName: recorded.toolName,
                        segments: [.text(.init(content: recorded.outputText))]
                    ))
                default:
                    break
                }
            }
            let toolCalls = toolCallOrder.compactMap { id in
                toolCallAccumulator[id].map { (id: id, toolName: $0.name, argumentsJSON: $0.argumentsJSON) }
            }
            try await withTaskCancellationHandler {
                try await executorTask.value
            } onCancel: {
                executorTask.cancel()
            }
            try Task.checkCancellation()

            turnUsage.input.totalTokenCount += usage.input.totalTokenCount
            turnUsage.input.cachedTokenCount += usage.input.cachedTokenCount
            turnUsage.output.totalTokenCount += usage.output.totalTokenCount
            turnUsage.output.reasoningTokenCount += usage.output.reasoningTokenCount
            turnUsage.metadata.merge(responseMetadata) { _, new in new }
            recordUsage(usage)

            // The model's thinking is part of the durable record, ahead of
            // the response it led to.
            if !reasoning.isEmpty || reasoningSignature != nil {
                appendEntry(.reasoning(Transcript.Reasoning(
                    segments: reasoning.isEmpty ? [] : [.text(.init(content: reasoning))],
                    signature: reasoningSignature
                )))
            }

            // Tool executions the executor already performed natively are
            // recorded in the transcript without re-execution.
            if !recordedCalls.isEmpty {
                appendEntry(.toolCalls(Transcript.ToolCalls(calls: recordedCalls)))
                for output in recordedOutputs {
                    appendEntry(.toolOutput(output))
                }
                if let resolved {
                    for call in recordedCalls {
                        for action in resolved.onToolCall { try await action(call) }
                    }
                    for output in recordedOutputs {
                        for action in resolved.onToolOutput { try await action(output) }
                    }
                    for (call, output) in zip(recordedCalls, recordedOutputs) {
                        for action in resolved.onToolCallOutputPair { try await action(call, output) }
                    }
                }
            }

            if toolCalls.isEmpty {
                return LoopResult(
                    text: joinedRounds(completedRoundsText, text),
                    finalRoundText: text,
                    responseSegments: responseSegments,
                    usage: turnUsage
                )
            }

            // Assistant text that preceded the tool calls is part of the
            // durable record: persist it ahead of the calls it led to.
            if !responseSegments.isEmpty || !text.isEmpty {
                let segments = !responseSegments.isEmpty
                    ? responseSegments
                    : [.text(.init(content: text))]
                appendEntry(.response(Transcript.Response(segments: segments)))
                completedRoundsText = joinedRounds(completedRoundsText, text)
            }

            let transcriptCalls = try toolCalls.map { call in
                Transcript.ToolCall(
                    id: call.id,
                    toolName: call.toolName,
                    arguments: try GeneratedContent(
                        json: call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON
                    )
                )
            }
            appendEntry(.toolCalls(Transcript.ToolCalls(calls: transcriptCalls)))

            // Resolve each call against the registered tools. An unknown name
            // is the model's mistake (hallucinated tool), not a fatal error —
            // it's fed back so the next round picks a real tool.
            let availableToolNames = activeTools.map(\.name)
            let resolvedCalls: [(call: Transcript.ToolCall, tool: ErasedTool?)] = transcriptCalls.map { call in
                (call, activeTools.first(where: { $0.name == call.toolName }))
            }
            // A round's tool calls run CONCURRENTLY — the framework contract
            // (tools guard their own shared state). Outputs and lifecycle
            // hooks are then applied in call order, so the transcript stays
            // deterministic. A failure cancels the round's remaining calls.
            let sessionLabel = timelineLabel ?? ""
            let outputs: [String] = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (index, entry) in resolvedCalls.enumerated() {
                    group.addTask {
                        let toolStarted = ContinuousClock().now
                        let input = String(entry.call.arguments.jsonString.prefix(400))
                        func recordRun(_ out: String) async {
                            await RequestTimeline.shared.record(ToolRunTiming(
                                tool: entry.call.toolName, session: sessionLabel,
                                start: RequestTimeline.shared.offset(of: toolStarted),
                                duration: ContinuousClock().now - toolStarted,
                                input: input, output: String(out.prefix(600))
                            ))
                        }
                        guard let tool = entry.tool else {
                            // Hallucinated tool name — recover instead of
                            // crashing the whole session.
                            let msg = "no tool named '\(entry.call.toolName)' is available in this session; available tools: \(availableToolNames.joined(separator: ", ")). Call one of these instead."
                            await recordRun(msg)
                            return (index, msg)
                        }
                        do {
                            let output: String
                            do {
                                output = try await SessionPropertyValues.$current.withValue(properties) {
                                    try await tool.call(entry.call.arguments)
                                }
                            } catch let decode as GeneratedContentError {
                                // Malformed ARGUMENTS are the model's mistake,
                                // not the tool's failure — feed the decode
                                // error back as tool output so the next round
                                // self-corrects instead of killing the turn.
                                output = "invalid arguments for \(entry.call.toolName): \(decode). Call it again with corrected arguments."
                            }
                            await recordRun(output)
                            return (index, output)
                        } catch {
                            await recordRun("threw: \(String(describing: error).prefix(300))")
                            throw ToolCallError(tool: tool.original, underlyingError: error)
                        }
                    }
                }
                var collected = [String?](repeating: nil, count: resolvedCalls.count)
                for try await (index, output) in group { collected[index] = output }
                return collected.compactMap { $0 }
            }
            for (entry, output) in zip(resolvedCalls, outputs) {
                let toolOutput = Transcript.ToolOutput(
                    id: entry.call.id,
                    toolName: entry.call.toolName,
                    segments: [.text(.init(content: output))]
                )
                appendEntry(.toolOutput(toolOutput))
                if let resolved {
                    for action in resolved.onToolCall { try await action(entry.call) }
                    for action in resolved.onToolOutput { try await action(toolOutput) }
                    for action in resolved.onToolCallOutputPair { try await action(entry.call, toolOutput) }
                }
            }
        }
    }

    /// Invokes the resolved profile's onResponse callbacks for a new entry.
    func notifyResponse(_ response: Transcript.Response) async throws {
        let resolved = profileLock.withLock { _lastResolvedProfile }
        guard let resolved else { return }
        for action in resolved.onResponse { try await action(response) }
    }

    // MARK: Helpers

    private func appendEntry(_ entry: Transcript.Entry) {
        state.withLock { $0.transcript.append(entry) }
    }

    private func recordUsage(_ usage: Usage) {
        state.withLock {
            $0.usage.input.totalTokenCount += usage.input.totalTokenCount
            $0.usage.input.cachedTokenCount += usage.input.cachedTokenCount
            $0.usage.output.totalTokenCount += usage.output.totalTokenCount
            $0.usage.output.reasoningTokenCount += usage.output.reasoningTokenCount
        }
    }

    private func setResponding(_ value: Bool) {
        state.withLock { $0.isResponding = value }
    }

    private func beginResponding() throws {
        try state.withLock {
            if $0.isResponding {
                throw GenerationError.concurrentRequests(.init(
                    debugDescription: "The session is already responding to a request."
                ))
            }
            $0.isResponding = true
        }
    }

    /// Runs one turn under the responding gate: acquires the gate (throwing
    /// `GenerationError.concurrentRequests` without touching any other
    /// request's state if it is already held), appends the prompt entry, and
    /// releases the gate exactly once. On failure the `.revertTranscript`
    /// policy removes the appended prompt entry and everything after it —
    /// located by identity, since history transforms may have changed the
    /// entry count arbitrarily.
    private func withTurn<T>(
        appending promptEntry: Transcript.Entry,
        _ body: (_ preCount: Int) async throws -> T
    ) async throws -> T {
        try beginResponding()
        // Registered only after the gate is acquired: a rejected concurrent
        // request can never clear the in-flight request's flag.
        defer { setResponding(false) }

        let preCount = transcript.count
        appendEntry(promptEntry)
        do {
            return try await body(preCount)
        } catch {
            if transcriptErrorHandlingPolicy == .revertTranscript {
                revertTranscript(removingFrom: promptEntry.id)
            }
            throw error
        }
    }

    /// The entries this turn contributed: the recorded prompt entry and
    /// everything after it. Falls back to a clamped suffix when a history
    /// transform replaced the prompt entry itself.
    private func turnEntries(from promptEntryID: String, fallbackPreCount: Int) -> ArraySlice<Transcript.Entry> {
        let entries = transcript.allEntries
        if let index = entries.firstIndex(where: { $0.id == promptEntryID }) {
            return entries[index...]
        }
        return entries[min(fallbackPreCount, entries.count)...]
    }

    private func replaceTranscript(_ transcript: Transcript) {
        state.withLock { $0.transcript = transcript }
    }

    /// Removes the entry with the given id and everything after it. A no-op
    /// when the entry is no longer present (e.g. a history transform already
    /// dropped it) — never truncates unrelated entries by position.
    private func revertTranscript(removingFrom entryID: String) {
        state.withLock {
            if let index = $0.transcript.allEntries.firstIndex(where: { $0.id == entryID }) {
                $0.transcript = Transcript(entries: $0.transcript.allEntries.prefix(index))
            }
        }
    }

    static func stripCodeFences(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if trimmed.contains("\n") {
            trimmed = String(trimmed.drop(while: { $0 != "\n" }).dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("```") {
                trimmed = String(trimmed.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
        var inner = String(trimmed.dropFirst(3))
        if inner.hasSuffix("```") {
            inner = String(inner.dropLast(3))
        }
        inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = inner.first, first.isLetter,
            let contentStart = inner.firstIndex(where: { $0 == "{" || $0 == "[" })
        {
            inner = String(inner[contentStart...])
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Response types

    public struct Response<Content> {
        public let content: Content
        public let rawContent: GeneratedContent
        public let transcriptEntries: ArraySlice<Transcript.Entry>
        public let usage: Usage
    }

    public struct Usage: Sendable {
        public struct Input: Sendable {
            public var totalTokenCount: Int
            public var cachedTokenCount: Int
            public init(totalTokenCount: Int = 0, cachedTokenCount: Int = 0) {
                self.totalTokenCount = totalTokenCount
                self.cachedTokenCount = cachedTokenCount
            }
        }
        public struct Output: Sendable {
            public var totalTokenCount: Int
            public var reasoningTokenCount: Int
            public init(totalTokenCount: Int = 0, reasoningTokenCount: Int = 0) {
                self.totalTokenCount = totalTokenCount
                self.reasoningTokenCount = reasoningTokenCount
            }
        }
        public var input: Input
        public var output: Output
        public var metadata: [String: any Sendable & Codable & Equatable]

        /// Combined input and output token count.
        public var totalTokenCount: Int {
            input.totalTokenCount + output.totalTokenCount
        }

        public init(input: Input, output: Output, metadata: [String: any Sendable & Codable & Equatable] = [:]) {
            self.input = input
            self.output = output
            self.metadata = metadata
        }

        init() {
            self.input = Input()
            self.output = Output()
            self.metadata = [:]
        }
    }

    public struct ResponseStream<Content>: AsyncSequence where Content: Generable {
        public struct Snapshot {
            public var content: Content.PartiallyGenerated
            public var rawContent: GeneratedContent
            public var transcriptEntries: ArraySlice<Transcript.Entry> = []
            public var usage: Usage = Usage()
        }

        public typealias Element = Snapshot

        let stream: AsyncThrowingStream<Snapshot, any Swift.Error>

        public struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: AsyncThrowingStream<Snapshot, any Swift.Error>.AsyncIterator

            public mutating func next() async throws -> Snapshot? {
                try await iterator.next()
            }

            public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> Snapshot? {
                try await iterator.next(isolation: actor)
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: stream.makeAsyncIterator())
        }

        /// Consumes the stream and returns the completed response.
        public func collect() async throws -> Response<Content> {
            var last: Snapshot?
            for try await snapshot in self {
                last = snapshot
            }
            guard let last else {
                throw GenerationError.decodingFailure(.init(
                    debugDescription: "the response stream finished without producing content"
                ))
            }
            return Response(
                content: try Content(last.rawContent),
                rawContent: last.rawContent,
                transcriptEntries: last.transcriptEntries,
                usage: last.usage
            )
        }
    }
}

// MARK: - Executor caching

/// Process-wide executor cache: one executor per (executor type,
/// configuration) pair, however many sessions or re-evaluated profile bodies
/// ask for it — `.model(...)` inside a dynamic profile must not construct a
/// new executor (and e.g. a new HTTP connection pool) on every request.
///
/// The cache never evicts entries, so distinct per-user configurations grow
/// without bound for the lifetime of the process.
///
/// @unchecked Sendable invariant: the executor cache is guarded by `NSLock`;
/// cached executors are `Sendable` language-model transports. (`Mutex` is avoided:
/// type-erased `Any` values trip region isolation under complete checking.)
final class SharedExecutorRegistry: @unchecked Sendable {
    static let shared = SharedExecutorRegistry()

    private struct Key: Hashable {
        let executorType: ObjectIdentifier
        let configuration: AnyHashable
    }

    private let lock = NSLock()
    private var executors: [Key: Any] = [:]

    func executor<Executor: LanguageModelExecutor>(
        for configuration: Executor.Configuration,
        as type: Executor.Type
    ) throws -> Executor {
        let key = Key(executorType: ObjectIdentifier(Executor.self), configuration: AnyHashable(configuration))
        lock.lock()
        if let cached = executors[key] as? Executor {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let constructed = try Executor(configuration: configuration)

        lock.lock()
        defer { lock.unlock() }
        if let cached = executors[key] as? Executor { return cached }
        executors[key] = constructed
        return constructed
    }
}

func erasePrewarm<Model: LanguageModel>(_ model: Model) -> @Sendable (Transcript) -> Void {
    let configuration = model.executorConfiguration
    return { transcript in
        guard let executor = try? SharedExecutorRegistry.shared.executor(
            for: configuration, as: Model.Executor.self
        ) else { return }
        executor.prewarm(model: model, transcript: transcript)
    }
}

private struct UnregisteredToolCall: LocalizedError {
    let toolName: String
    var errorDescription: String? { "the model called unregistered tool \(toolName)" }
}

private struct UnregisteredToolReference: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let registeredName: String
    var name: String { registeredName }
    var description: String { "Tool registered by name only for error reporting." }
    var parameters: GenerationSchema {
        try! GenerationSchema(
            root: DynamicGenerationSchema(name: "arguments", properties: []),
            dependencies: []
        )
    }

    init(name: String) {
        self.registeredName = name
    }

    func call(arguments: GeneratedContent) async throws -> String {
        throw UnregisteredToolCall(toolName: registeredName)
    }
}

// MARK: - Tool erasure

/// Opens `any Tool` existentials once at session construction so the
/// generation loop can decode arguments and invoke calls without generics.
struct ErasedTool: Sendable {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let original: any Tool
    let call: @Sendable (GeneratedContent) async throws -> String

    init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.parameters = tool.parameters
        self.original = tool
        self.call = { content in
            let arguments = try T.Arguments(content)
            let output = try await tool.call(arguments: arguments)
            return output.promptRepresentation.text
        }
    }
}
