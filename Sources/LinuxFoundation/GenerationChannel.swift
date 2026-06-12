// LanguageModelExecutorGenerationChannel — the public event stream executors
// write generation results into. Mirrors FoundationModels (SDK 27): events
// are entry-ID-addressed edits (response text, reasoning, tool calls) so
// executors can build transcript entries incrementally.

import Foundation

public struct LanguageModelExecutorGenerationChannel: AsyncSequence, Sendable {
    public typealias Element = any Event

    let stream: AsyncStream<any Event>
    private let continuation: AsyncStream<any Event>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    public func send(_ event: some Event) async {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<any Event>.AsyncIterator

        public mutating func next() async throws -> (any Event)? {
            await iterator.next()
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async throws -> (any Event)? {
            await iterator.next(isolation: actor)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }

    // MARK: Event protocol

    public protocol Event: Sendable {
        var kind: EventKind { get }
    }

    public struct EventKind: Sendable {
        let raw: String
    }

    // MARK: Shared payloads

    public struct Metadata: Sendable {
        public var values: [String: any Sendable & Codable & Equatable]
    }

    public struct Usage: Sendable {
        public struct Input: Sendable {
            public var totalTokenCount: Int
            public var cachedTokenCount: Int
            public init(totalTokenCount: Int, cachedTokenCount: Int) {
                self.totalTokenCount = totalTokenCount
                self.cachedTokenCount = cachedTokenCount
            }
        }
        public struct Output: Sendable {
            public var totalTokenCount: Int
            public var reasoningTokenCount: Int
            public init(totalTokenCount: Int, reasoningTokenCount: Int) {
                self.totalTokenCount = totalTokenCount
                self.reasoningTokenCount = reasoningTokenCount
            }
        }
        public var input: Input
        public var output: Output
        public init(input: Input, output: Output) {
            self.input = input
            self.output = output
        }
    }

    public struct TextFragment: Sendable {
        public var content: String
        public var segmentID: String?
        public var tokenCount: Int
    }

    public struct TextSegmentReplacement: Sendable {
        public var content: String
        public var segmentID: String?
        public var tokenCount: Int
    }

    public struct ReasoningSignature: Sendable {
        public var signature: Data
        public var tokenCount: Int
    }

    // MARK: Response events

    public struct Response: Event {
        public var entryID: String?
        public var action: Action

        public var kind: EventKind { EventKind(raw: "response") }

        public enum Action: Sendable {
            case appendText(TextFragment)
            case replaceTextSegment(TextSegmentReplacement)
            case updateCustomSegment(any Transcript.CustomSegment)
            case addAttachmentSegment(Transcript.AttachmentSegment)
            case removeAttachmentSegment(id: String)
            case updateMetadata(Metadata)
            case updateUsage(Usage)
        }
    }

    // MARK: Reasoning events

    public struct Reasoning: Event {
        public var entryID: String?
        public var action: Action

        public var kind: EventKind { EventKind(raw: "reasoning") }

        public enum Action: Sendable {
            case appendText(TextFragment)
            case replaceTextSegment(TextSegmentReplacement)
            case updateSignature(ReasoningSignature)
            case updateMetadata(Metadata)
            case updateUsage(Usage)
        }
    }

    // MARK: Tool call events

    public struct ToolCalls: Event {
        public var entryID: String?
        public var action: Action

        public var kind: EventKind { EventKind(raw: "toolCalls") }

        public enum Action: Sendable {
            case toolCall(ToolCall)
            case removeToolCall(id: String)
            case updateMetadata(Metadata)
            case updateUsage(Usage)
        }

        public struct ToolCall: Sendable {
            public var id: String
            public var name: String
            public var action: Action

            public enum Action: Sendable {
                case appendArguments(ArgumentsFragment)
                case updateMetadata(Metadata)
            }

            public struct ArgumentsFragment: Sendable {
                public var content: String
                public var tokenCount: Int
            }
        }
    }
}

// MARK: - Convenience constructors (Apple-parity)

extension LanguageModelExecutorGenerationChannel.Response.Action {
    public static func appendText(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Self {
        .appendText(.init(content: text, segmentID: segmentID, tokenCount: tokenCount))
    }

    public static func replaceTextSegment(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Self {
        .replaceTextSegment(.init(content: text, segmentID: segmentID, tokenCount: tokenCount))
    }

    public static func updateMetadata(_ values: [String: any Sendable & Codable & Equatable]) -> Self {
        .updateMetadata(.init(values: values))
    }

    public static func updateUsage(
        input: LanguageModelExecutorGenerationChannel.Usage.Input,
        output: LanguageModelExecutorGenerationChannel.Usage.Output
    ) -> Self {
        .updateUsage(.init(input: input, output: output))
    }
}

extension LanguageModelExecutorGenerationChannel.Reasoning.Action {
    public static func appendText(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Self {
        .appendText(.init(content: text, segmentID: segmentID, tokenCount: tokenCount))
    }

    public static func replaceTextSegment(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Self {
        .replaceTextSegment(.init(content: text, segmentID: segmentID, tokenCount: tokenCount))
    }

    public static func updateSignature(_ signature: Data, tokenCount: Int) -> Self {
        .updateSignature(.init(signature: signature, tokenCount: tokenCount))
    }

    public static func updateMetadata(_ values: [String: any Sendable & Codable & Equatable]) -> Self {
        .updateMetadata(.init(values: values))
    }

    public static func updateUsage(
        input: LanguageModelExecutorGenerationChannel.Usage.Input,
        output: LanguageModelExecutorGenerationChannel.Usage.Output
    ) -> Self {
        .updateUsage(.init(input: input, output: output))
    }
}

extension LanguageModelExecutorGenerationChannel.ToolCalls.Action {
    public static func toolCall(
        id: String,
        name: String,
        action: LanguageModelExecutorGenerationChannel.ToolCalls.ToolCall.Action
    ) -> Self {
        .toolCall(.init(id: id, name: name, action: action))
    }

    public static func updateMetadata(_ values: [String: any Sendable & Codable & Equatable]) -> Self {
        .updateMetadata(.init(values: values))
    }

    public static func updateUsage(
        input: LanguageModelExecutorGenerationChannel.Usage.Input,
        output: LanguageModelExecutorGenerationChannel.Usage.Output
    ) -> Self {
        .updateUsage(.init(input: input, output: output))
    }
}

extension LanguageModelExecutorGenerationChannel.ToolCalls.ToolCall.Action {
    public static func appendArguments(_ content: String, tokenCount: Int) -> Self {
        .appendArguments(.init(content: content, tokenCount: tokenCount))
    }

    public static func updateMetadata(_ values: [String: any Sendable & Codable & Equatable]) -> Self {
        .updateMetadata(.init(values: values))
    }
}

extension LanguageModelExecutorGenerationChannel.Event
where Self == LanguageModelExecutorGenerationChannel.Response {
    public static func response(
        entryID: String? = nil,
        action: LanguageModelExecutorGenerationChannel.Response.Action
    ) -> Self {
        Self(entryID: entryID, action: action)
    }
}

extension LanguageModelExecutorGenerationChannel.Event
where Self == LanguageModelExecutorGenerationChannel.Reasoning {
    public static func reasoning(
        entryID: String? = nil,
        action: LanguageModelExecutorGenerationChannel.Reasoning.Action
    ) -> Self {
        Self(entryID: entryID, action: action)
    }
}

extension LanguageModelExecutorGenerationChannel.Event
where Self == LanguageModelExecutorGenerationChannel.ToolCalls {
    public static func toolCalls(
        entryID: String? = nil,
        action: LanguageModelExecutorGenerationChannel.ToolCalls.Action
    ) -> Self {
        Self(entryID: entryID, action: action)
    }
}

// MARK: - Internal events

/// A tool invocation an executor already ran natively (e.g. inside Apple's
/// on-device session): recorded in the transcript without re-execution.
struct RecordedToolExecution: LanguageModelExecutorGenerationChannel.Event {
    var id: String
    var toolName: String
    var argumentsJSON: String
    var outputText: String

    var kind: LanguageModelExecutorGenerationChannel.EventKind {
        .init(raw: "recordedToolExecution")
    }
}
