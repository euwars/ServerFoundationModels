// LanguageModelSession — orchestrates prompts, the tool-call loop, transcript
// management, and streaming. Mirrors FoundationModels.LanguageModelSession
// (SDK 27), generic over any LanguageModel via the executor contract.

import Foundation

public final class LanguageModelSession: @unchecked Sendable {

    // MARK: State

    private let lock = NSLock()
    private var _transcript: Transcript
    private var _isResponding = false
    private var _usage = Usage()
    private var _errorPolicy: TranscriptErrorHandlingPolicy?

    var errorPolicy: TranscriptErrorHandlingPolicy? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _errorPolicy
        }
        set {
            lock.lock()
            _errorPolicy = newValue
            lock.unlock()
        }
    }

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

    public var transcript: Transcript {
        lock.lock()
        defer { lock.unlock() }
        return _transcript
    }

    public var isResponding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isResponding
    }

    /// Cumulative token usage across all requests on this session.
    public var usage: Usage {
        lock.lock()
        defer { lock.unlock() }
        return _usage
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
            @Sendable (LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel) async throws -> Void
        ) {
            erasePerform(model)
        }
        self.init(erasing: SystemLanguageModel.default, tools: tools, instructionsText: instructionsText, transcript: nil)
        let perform = open(model)
        self.profileResolver = { [properties] in
            var resolved = SessionPropertyValues.$current.withValue(properties) {
                ResolvedProfile()
            }
            resolved.perform = perform
            resolved.instructionsText = instructionsText
            return resolved
        }
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
        self._transcript = initialTranscript
    }

    public func prewarm(promptPrefix: Prompt? = nil) {
        // Executor prewarming is a no-op for remote executors; on-device
        // executors warm caches here.
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
            segments: [.text(.init(content: prompt))],
            options: options
        ))
        return try await withTurn(appending: promptEntry) { preCount in
            let result = try await generateLoop(
                schema: nil, options: options,
                contextOptions: contextOptions, metadata: metadata,
                onCumulativeText: nil
            )

            let responseEntry = Transcript.Response(segments: [.text(.init(content: result.finalRoundText))])
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
        includeSchemaInPrompt: Bool,
        options: GenerationOptions,
        contextOptions: ContextOptions,
        metadata: [String: any Sendable & Codable & Equatable]
    ) async throws -> Response<GeneratedContent> {
        var contextOptions = contextOptions
        contextOptions.includeSchemaInPrompt = contextOptions.includeSchemaInPrompt ?? includeSchemaInPrompt
        let promptEntry = Transcript.Entry.prompt(Transcript.Prompt(
            segments: [.text(.init(content: prompt))],
            options: options,
            responseFormat: Transcript.ResponseFormat(schema: schema)
        ))
        return try await withTurn(appending: promptEntry) { preCount in
            let result = try await generateLoop(
                schema: schema, options: options,
                contextOptions: contextOptions, metadata: metadata,
                onCumulativeText: nil
            )
            let content = try GeneratedContent(json: Self.stripCodeFences(from: result.finalRoundText))

            let responseEntry = Transcript.Response(
                segments: [.structure(.init(content: content))]
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
            segments: [.text(.init(content: prompt))],
            options: options,
            responseFormat: Transcript.ResponseFormat(schema: schema)
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
                segments: [.structure(.init(content: raw))]
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
            segments: [.text(.init(content: prompt))],
            options: options
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

                    let responseEntry = Transcript.Response(segments: [.text(.init(content: result.finalRoundText))])
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
            segments: [.text(.init(content: prompt))],
            options: options,
            responseFormat: Transcript.ResponseFormat(schema: schema)
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
                        segments: [.structure(.init(content: raw))]
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
            segments: [.text(.init(content: prompt))],
            options: options,
            responseFormat: Transcript.ResponseFormat(schema: schema)
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
                    let responseEntry = Transcript.Response(segments: [.structure(.init(content: raw))])
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
        var usage: Usage
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
        guard let profileResolver else { return (nil, options, transcript) }
        let resolved = SessionPropertyValues.$current.withValue(properties) { profileResolver() }

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
                throw LanguageModelTransportError(
                    statusCode: 0,
                    message: "Transcript must end with a .prompt or .toolOutput entry."
                )
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
                throw LanguageModelTransportError(
                    statusCode: 0,
                    message: "Transcript must end with a .prompt or .toolOutput entry."
                )
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
                throw LanguageModelTransportError(
                    statusCode: 0,
                    message: "the tool-call loop exceeded \(Self.maximumToolRounds) rounds without producing a final response"
                )
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
            var usage = Usage()
            var toolCallOrder: [String] = []
            var toolCallAccumulator: [String: (name: String, argumentsJSON: String)] = [:]
            var recordedCalls: [Transcript.ToolCall] = []
            var recordedOutputs: [Transcript.ToolOutput] = []

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
                        onCumulativeText?(joinedRounds(completedRoundsText, text), text)
                    case .replaceTextSegment(let replacement):
                        text = replacement.content
                        onCumulativeText?(joinedRounds(completedRoundsText, text), text)
                    case .updateUsage(let reported):
                        accumulate(reported)
                    case .updateCustomSegment, .addAttachmentSegment, .removeAttachmentSegment, .updateMetadata:
                        break
                    }
                case let reasoningEvent as LanguageModelExecutorGenerationChannel.Reasoning:
                    switch reasoningEvent.action {
                    case .appendText(let fragment):
                        reasoning += fragment.content
                    case .replaceTextSegment(let replacement):
                        reasoning = replacement.content
                    case .updateUsage(let reported):
                        accumulate(reported)
                    case .updateSignature, .updateMetadata:
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
            recordUsage(usage)

            // The model's thinking is part of the durable record, ahead of
            // the response it led to.
            if !reasoning.isEmpty {
                appendEntry(.reasoning(Transcript.Reasoning(
                    segments: [.text(.init(content: reasoning))]
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
                    usage: turnUsage
                )
            }

            // Assistant text that preceded the tool calls is part of the
            // durable record: persist it ahead of the calls it led to.
            if !text.isEmpty {
                appendEntry(.response(Transcript.Response(
                    segments: [.text(.init(content: text))]
                )))
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

            for call in transcriptCalls {
                guard let tool = activeTools.first(where: { $0.name == call.toolName }) else {
                    throw LanguageModelTransportError(statusCode: 0, message: "the model called unregistered tool \(call.toolName)")
                }
                let output: String
                do {
                    output = try await SessionPropertyValues.$current.withValue(properties) {
                        try await tool.call(call.arguments)
                    }
                } catch {
                    throw ToolCallError(tool: tool.original, underlyingError: error)
                }
                let toolOutput = Transcript.ToolOutput(
                    id: call.id,
                    toolName: call.toolName,
                    segments: [.text(.init(content: output))]
                )
                appendEntry(.toolOutput(toolOutput))
                if let resolved {
                    for action in resolved.onToolCall { try await action(call) }
                    for action in resolved.onToolOutput { try await action(toolOutput) }
                    for action in resolved.onToolCallOutputPair { try await action(call, toolOutput) }
                }
            }
        }
    }

    /// Invokes the resolved profile's onResponse callbacks for a new entry.
    func notifyResponse(_ response: Transcript.Response) async throws {
        guard let resolved = SessionPropertyValues.$current.withValue(properties, operation: { profileResolver?() }) else { return }
        for action in resolved.onResponse { try await action(response) }
    }

    // MARK: Helpers

    private func appendEntry(_ entry: Transcript.Entry) {
        lock.lock()
        _transcript.append(entry)
        lock.unlock()
    }

    private func recordUsage(_ usage: Usage) {
        lock.lock()
        _usage.input.totalTokenCount += usage.input.totalTokenCount
        _usage.input.cachedTokenCount += usage.input.cachedTokenCount
        _usage.output.totalTokenCount += usage.output.totalTokenCount
        _usage.output.reasoningTokenCount += usage.output.reasoningTokenCount
        lock.unlock()
    }

    private func setResponding(_ value: Bool) {
        lock.lock()
        _isResponding = value
        lock.unlock()
    }

    private func beginResponding() throws {
        lock.lock()
        defer { lock.unlock() }
        if _isResponding {
            throw GenerationError.concurrentRequests(.init(
                debugDescription: "The session is already responding to a request."
            ))
        }
        _isResponding = true
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
        lock.lock()
        _transcript = transcript
        lock.unlock()
    }

    /// Removes the entry with the given id and everything after it. A no-op
    /// when the entry is no longer present (e.g. a history transform already
    /// dropped it) — never truncates unrelated entries by position.
    private func revertTranscript(removingFrom entryID: String) {
        lock.lock()
        if let index = _transcript.allEntries.firstIndex(where: { $0.id == entryID }) {
            _transcript = Transcript(entries: _transcript.allEntries.prefix(index))
        }
        lock.unlock()
    }

    static func stripCodeFences(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .drop(while: { $0 != "\n" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("```") {
                trimmed = String(trimmed.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
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
        defer { lock.unlock() }
        if let cached = executors[key] as? Executor { return cached }
        let executor = try Executor(configuration: configuration)
        executors[key] = executor
        return executor
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
