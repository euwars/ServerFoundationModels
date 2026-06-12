// LanguageModelSession — orchestrates prompts, the tool-call loop, transcript
// management, and streaming. Mirrors FoundationModels.LanguageModelSession
// (SDK 27), generic over any LanguageModel via the executor contract.

import Foundation

public final class LanguageModelSession: @unchecked Sendable {

    // MARK: State

    private let lock = NSLock()
    private var _transcript: Transcript
    private var _isResponding = false

    private let tools: [ErasedTool]
    private let toolDefinitions: [Transcript.ToolDefinition]
    private let perform: @Sendable (
        LanguageModelExecutorGenerationRequest,
        LanguageModelExecutorGenerationChannel
    ) async throws -> Void

    /// Set for profile-based sessions; re-evaluated before every request.
    var profileResolver: (() -> ResolvedProfile)?

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
                throw LanguageModelError.executorCreationFailed(underlying: error)
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
            do {
                raw = try GeneratedContent(json: Self.stripCodeFences(from: result.text))
            } catch {
                throw GeneratedContentError("response was not valid JSON (\(error)); response text: '\(result.text.prefix(2000))'")
            }
            let content = try Content(raw)

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
        let (stream, continuation) = AsyncThrowingStream<ResponseStream<String>.Snapshot, any Error>.makeStream()

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
            // before every request.
            let resolved = profileResolver?()
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
                    throw LanguageModelError.requestFailed(
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
            let executorTask = Task {
                defer { channel.finish() }
                try await perform(request, channel)
            }

            var text = ""
            var reasoning = ""
            var usage = Usage()
            var toolCalls: [(id: String, toolName: String, argumentsJSON: String)] = []
            var recordedCalls: [Transcript.ToolCall] = []
            var recordedOutputs: [Transcript.ToolOutput] = []
            for await event in channel.stream {
                switch event {
                case .textDelta(let delta):
                    text += delta
                    onCumulativeText?(text)
                case .reasoningDelta(let delta):
                    reasoning += delta
                case .usage(let reported):
                    usage.input.totalTokenCount += reported.input.totalTokenCount
                    usage.input.cachedTokenCount += reported.input.cachedTokenCount
                    usage.output.totalTokenCount += reported.output.totalTokenCount
                    usage.output.reasoningTokenCount += reported.output.reasoningTokenCount
                case .toolCall(let id, let toolName, let argumentsJSON):
                    toolCalls.append((id, toolName, argumentsJSON))
                case .recordedToolCall(let id, let toolName, let argumentsJSON):
                    let arguments = (try? GeneratedContent(json: argumentsJSON))
                        ?? GeneratedContent(properties: [:])
                    recordedCalls.append(Transcript.ToolCall(id: id, toolName: toolName, arguments: arguments))
                case .recordedToolOutput(let id, let toolName, let outputText):
                    recordedOutputs.append(Transcript.ToolOutput(
                        id: id,
                        toolName: toolName,
                        segments: [.text(.init(content: outputText))]
                    ))
                }
            }
            try await executorTask.value

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
                    throw LanguageModelError.toolNotFound(call.toolName)
                }
                let output = try await tool.call(call.arguments)
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

    private func setResponding(_ value: Bool) {
        lock.lock()
        _isResponding = value
        lock.unlock()
    }

    private func withRespondingFlag<T>(_ body: () async throws -> T) async throws -> T {
        setResponding(true)
        defer { setResponding(false) }
        return try await body()
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

        let stream: AsyncThrowingStream<Snapshot, any Error>

        public struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: AsyncThrowingStream<Snapshot, any Error>.AsyncIterator

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
    let call: @Sendable (GeneratedContent) async throws -> String

    init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.parameters = tool.parameters
        self.call = { content in
            let arguments = try T.Arguments(content)
            let output = try await tool.call(arguments: arguments)
            return output.promptRepresentation.text
        }
    }
}
