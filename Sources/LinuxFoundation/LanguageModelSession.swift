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
    var errorPolicy: TranscriptErrorHandlingPolicy?

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
            let text = erased.allInstructionTexts.joined(separator: "\n\n")
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
        let configuration = model.executorConfiguration
        self.perform = { request, channel in
            let executor: Model.Executor
            do {
                executor = try Model.Executor(configuration: configuration)
            } catch {
                throw LanguageModelTransportError(statusCode: 0, message: "failed to create executor: \(error)")
            }
            try await executor.respond(to: request, model: model, streamingInto: channel)
        }

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
        try await withRespondingFlag {
            let preCount = transcript.count
            appendEntry(.prompt(Transcript.Prompt(
                segments: [.text(.init(content: prompt))],
                options: options
            )))

            let result = try await generateLoop(schema: nil, options: options, onCumulativeText: nil)

            appendEntry(.response(Transcript.Response(segments: [.text(.init(content: result.text))])))
            return Response(
                content: result.text,
                rawContent: result.text.generatedContent,
                transcriptEntries: transcript.allEntries[preCount...],
                usage: result.usage
            )
        }
    }

    // MARK: Respond — structured

    public func respond(
        to prompt: String,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<GeneratedContent> {
        try await withRespondingFlag {
            let preCount = transcript.count
            appendEntry(.prompt(Transcript.Prompt(
                segments: [.text(.init(content: prompt))],
                options: options,
                responseFormat: Transcript.ResponseFormat(schema: schema)
            )))

            let result = try await generateLoop(schema: schema, options: options, onCumulativeText: nil)
            let content = try GeneratedContent(json: Self.stripCodeFences(from: result.text))

            appendEntry(.response(Transcript.Response(
                segments: [.structure(.init(content: content))]
            )))
            return Response(
                content: content,
                rawContent: content,
                transcriptEntries: transcript.allEntries[preCount...],
                usage: result.usage
            )
        }
    }

    // MARK: Respond — typed Generable

    public func respond<Content>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> Response<Content> where Content: Generable {
        try await withRespondingFlag {
            let preCount = transcript.count
            let schema = Content.generationSchema
            appendEntry(.prompt(Transcript.Prompt(
                segments: [.text(.init(content: prompt))],
                options: options,
                responseFormat: Transcript.ResponseFormat(schema: schema)
            )))

            let result = try await generateLoop(schema: schema, options: options, onCumulativeText: nil)
            let raw: GeneratedContent
            let content: Content
            do {
                raw = try GeneratedContent(json: Self.stripCodeFences(from: result.text))
                content = try Content(raw)
            } catch {
                throw GenerationError.decodingFailure(.init(
                    debugDescription: "failed to decode \(Content.self) from response (\(error)); response text: '\(result.text.prefix(2000))'"
                ))
            }

            appendEntry(.response(Transcript.Response(
                segments: [.structure(.init(content: raw))]
            )))
            return Response(
                content: content,
                rawContent: raw,
                transcriptEntries: transcript.allEntries[preCount...],
                usage: result.usage
            )
        }
    }

    // MARK: Streaming

    public func streamResponse(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) -> ResponseStream<String> {
        let (stream, continuation) = AsyncThrowingStream<ResponseStream<String>.Snapshot, any Swift.Error>.makeStream()

        Task {
            do {
                setResponding(true)
                appendEntry(.prompt(Transcript.Prompt(
                    segments: [.text(.init(content: prompt))],
                    options: options
                )))

                let result = try await generateLoop(schema: nil, options: options) { cumulative in
                    continuation.yield(ResponseStream<String>.Snapshot(
                        content: cumulative,
                        rawContent: cumulative.generatedContent
                    ))
                }

                appendEntry(.response(Transcript.Response(segments: [.text(.init(content: result.text))])))
                setResponding(false)
                continuation.finish()
            } catch {
                setResponding(false)
                continuation.finish(throwing: error)
            }
        }

        return ResponseStream(stream: stream)
    }

    // MARK: Generation loop

    /// Runs executor requests until the model produces a final response,
    /// executing tool calls between rounds and recording them in the transcript.
    struct LoopResult {
        var text: String
        var usage: Usage
    }

    private func generateLoop(
        schema: GenerationSchema?,
        options: GenerationOptions,
        onCumulativeText: (@Sendable (String) -> Void)?
    ) async throws -> LoopResult {
        while true {
            // Profile-based sessions re-resolve model/instructions/options
            // before every request; resolution and tool execution see this
            // session's properties via the task-local context.
            properties.history = transcript.allEntries[...]
            let resolved = SessionPropertyValues.$current.withValue(properties) {
                profileResolver?()
            }
            var requestEntries = transcript.allEntries
            if let transform = resolved?.historyTransform {
                // Matching Apple: the transform receives the full request
                // transcript (in-flight prompt included) and must keep it
                // ending in a prompt or tool output.
                requestEntries = transform(requestEntries)
                switch requestEntries.last {
                case .prompt, .toolOutput:
                    break
                default:
                    throw LanguageModelTransportError(
                        statusCode: 0,
                        message: "Transcript must end with a .prompt or .toolOutput entry."
                    )
                }
            }
            if let instructionsText = resolved?.instructionsText {
                requestEntries.removeAll { if case .instructions = $0 { return true }; return false }
                requestEntries.insert(.instructions(Transcript.Instructions(
                    segments: [.text(.init(content: instructionsText))],
                    toolDefinitions: toolDefinitions
                )), at: 0)
            }
            var effectiveOptions = options
            if effectiveOptions.temperature == nil { effectiveOptions.temperature = resolved?.temperature }
            if effectiveOptions.samplingMode == nil { effectiveOptions.samplingMode = resolved?.samplingMode }
            if effectiveOptions.maximumResponseTokens == nil {
                effectiveOptions.maximumResponseTokens = resolved?.maximumResponseTokens
            }

            let channel = LanguageModelExecutorGenerationChannel()
            var request = LanguageModelExecutorGenerationRequest(
                transcript: Transcript(entries: requestEntries),
                enabledTools: toolDefinitions,
                schema: schema,
                generationOptions: effectiveOptions
            )
            request.contextOptions = ContextOptions(reasoningLevel: resolved?.reasoningLevel)
            request.executableTools = tools

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

            func accumulate(_ reported: LanguageModelExecutorGenerationChannel.Usage) {
                usage.input.totalTokenCount += reported.input.totalTokenCount
                usage.input.cachedTokenCount += reported.input.cachedTokenCount
                usage.output.totalTokenCount += reported.output.totalTokenCount
                usage.output.reasoningTokenCount += reported.output.reasoningTokenCount
            }

            for await event in channel.stream {
                switch event {
                case let response as LanguageModelExecutorGenerationChannel.Response:
                    switch response.action {
                    case .appendText(let fragment):
                        text += fragment.content
                        onCumulativeText?(text)
                    case .replaceTextSegment(let replacement):
                        text = replacement.content
                        onCumulativeText?(text)
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
            try await executorTask.value

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
            }

            if toolCalls.isEmpty {
                return LoopResult(text: text, usage: usage)
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
                guard let tool = tools.first(where: { $0.name == call.toolName }) else {
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
                appendEntry(.toolOutput(Transcript.ToolOutput(
                    id: call.id,
                    toolName: call.toolName,
                    segments: [.text(.init(content: output))]
                )))
            }
        }
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

    private func withRespondingFlag<T>(_ body: () async throws -> T) async throws -> T {
        try beginResponding()
        defer { setResponding(false) }

        let preCount = transcript.count
        do {
            return try await body()
        } catch {
            if transcriptErrorHandlingPolicy == .revertTranscript {
                truncateTranscript(to: preCount)
            }
            throw error
        }
    }

    private func truncateTranscript(to count: Int) {
        lock.lock()
        _transcript = Transcript(entries: _transcript.allEntries.prefix(count))
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
            public var totalTokenCount: Int = 0
            public var cachedTokenCount: Int = 0
        }
        public struct Output: Sendable {
            public var totalTokenCount: Int = 0
            public var reasoningTokenCount: Int = 0
        }
        public var input: Input = Input()
        public var output: Output = Output()
    }

    public struct ResponseStream<Content>: AsyncSequence where Content: Generable {
        public struct Snapshot {
            public var content: Content.PartiallyGenerated
            public var rawContent: GeneratedContent
        }

        public typealias Element = Snapshot

        let stream: AsyncThrowingStream<Snapshot, any Swift.Error>

        public struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: AsyncThrowingStream<Snapshot, any Swift.Error>.AsyncIterator

            public mutating func next() async throws -> Snapshot? {
                try await iterator.next()
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: stream.makeAsyncIterator())
        }
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
