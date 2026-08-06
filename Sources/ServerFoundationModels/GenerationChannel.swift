// LanguageModelExecutorGenerationChannel — the public event stream executors
// write generation results into. Mirrors FoundationModels (SDK 27 beta 4):
// Event and the Action types are opaque structs built through static
// factories — executors send events; only the session interprets them.
// Events are entry-ID-addressed edits (response text, reasoning, tool calls)
// so executors can build transcript entries incrementally.

import Foundation

public struct LanguageModelExecutorGenerationChannel: AsyncSequence, Sendable {
    public typealias Element = Event

    let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    public init() {
        // Deliberately unbounded: executor events are incremental edits
        // (deltas), not coalescable snapshots — dropping any would corrupt
        // the assembled response. The session drains this stream eagerly in
        // its generation loop, so buffering stays proportional to one round.
        // (Session-facing snapshot streams, by contrast, buffer only the
        // newest snapshot, since each snapshot carries the full content.)
        (stream, continuation) = AsyncStream.makeStream()
    }

    /// Enqueues the event. `async` for API parity only — the channel is
    /// unbounded, so this never suspends and applies no backpressure.
    public func send(_ event: Event) async {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<Event>.AsyncIterator

        public mutating func next() async throws -> Event? {
            await iterator.next()
        }

        public mutating func next(isolation actor: isolated (any Actor)?) async throws -> Event? {
            await iterator.next(isolation: actor)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }

    // MARK: Event

    /// Opaque to clients, matching Apple's surface: constructed through the
    /// static factories below, destructured only inside this package.
    public struct Event: Sendable {
        package enum Storage: Sendable {
            case response(Response)
            case reasoning(Reasoning)
            case toolCalls(ToolCalls)
            case recordedToolExecution(RecordedToolExecution)
        }

        package let storage: Storage

        package init(storage: Storage) {
            self.storage = storage
        }

        public static func response(
            entryID: String? = nil,
            action: Response.Action
        ) -> Event {
            Event(storage: .response(.init(entryID: entryID, action: action)))
        }

        public static func reasoning(
            entryID: String? = nil,
            action: Reasoning.Action
        ) -> Event {
            Event(storage: .reasoning(.init(entryID: entryID, action: action)))
        }

        public static func toolCalls(
            entryID: String? = nil,
            action: ToolCalls.Action
        ) -> Event {
            Event(storage: .toolCalls(.init(entryID: entryID, action: action)))
        }

        /// A tool invocation an executor already ran natively (e.g. inside
        /// Apple's on-device session): recorded in the transcript without
        /// re-execution. Not part of Apple's public surface.
        package static func recordedToolExecution(
            id: String,
            toolName: String,
            argumentsJSON: String,
            outputText: String
        ) -> Event {
            Event(storage: .recordedToolExecution(.init(
                id: id, toolName: toolName,
                argumentsJSON: argumentsJSON, outputText: outputText
            )))
        }
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
        public var metadata: [String: any Sendable & Codable & Equatable]
        public init(
            input: Input,
            output: Output,
            metadata: [String: any Sendable & Codable & Equatable] = [:]
        ) {
            self.input = input
            self.output = output
            self.metadata = metadata
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

    public struct Response: Sendable {
        public var entryID: String?
        public var action: Action

        public struct Action: Sendable {
            package enum Storage: Sendable {
                case appendText(TextFragment)
                case replaceTextSegment(TextSegmentReplacement)
                case updateCustomSegment(any Transcript.CustomSegment)
                case addAttachmentSegment(Transcript.AttachmentSegment)
                case removeAttachmentSegment(id: String)
                case updateMetadata(Metadata)
                case updateUsage(Usage)
            }

            package let storage: Storage

            package init(storage: Storage) {
                self.storage = storage
            }
        }
    }

    // MARK: Reasoning events

    public struct Reasoning: Sendable {
        public var entryID: String?
        public var action: Action

        public struct Action: Sendable {
            package enum Storage: Sendable {
                case appendText(TextFragment)
                case replaceTextSegment(TextSegmentReplacement)
                case updateSignature(ReasoningSignature)
                case updateMetadata(Metadata)
                case updateUsage(Usage)
            }

            package let storage: Storage

            package init(storage: Storage) {
                self.storage = storage
            }
        }
    }

    // MARK: Tool call events

    public struct ToolCalls: Sendable {
        public var entryID: String?
        public var action: Action

        public struct Action: Sendable {
            package enum Storage: Sendable {
                case toolCall(ToolCall)
                case removeToolCall(id: String)
                case updateMetadata(Metadata)
                case updateUsage(Usage)
            }

            package let storage: Storage

            package init(storage: Storage) {
                self.storage = storage
            }
        }

        public struct ToolCall: Sendable {
            public var id: String
            public var name: String
            public var action: Action

            public struct Action: Sendable {
                package enum Storage: Sendable {
                    case appendArguments(ArgumentsFragment)
                    case updateMetadata(Metadata)
                }

                package let storage: Storage

                package init(storage: Storage) {
                    self.storage = storage
                }
            }

            public struct ArgumentsFragment: Sendable {
                public var content: String
                public var tokenCount: Int
            }
        }
    }
}

// MARK: - Action factories (Apple-parity)

extension LanguageModelExecutorGenerationChannel.Response.Action {
    public static func appendText(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Self {
        .init(storage: .appendText(.init(content: text, segmentID: segmentID, tokenCount: tokenCount)))
    }

    public static func replaceTextSegment(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Self {
        .init(storage: .replaceTextSegment(.init(content: text, segmentID: segmentID, tokenCount: tokenCount)))
    }

    public static func updateCustomSegment(_ segment: any Transcript.CustomSegment) -> Self {
        .init(storage: .updateCustomSegment(segment))
    }

    public static func addAttachmentSegment(_ segment: Transcript.AttachmentSegment) -> Self {
        .init(storage: .addAttachmentSegment(segment))
    }

    public static func removeAttachmentSegment(id: String) -> Self {
        .init(storage: .removeAttachmentSegment(id: id))
    }

    public static func updateMetadata(_ values: [String: any Sendable & Codable & Equatable]) -> Self {
        .init(storage: .updateMetadata(.init(values: values)))
    }

    public static func updateUsage(
        input: LanguageModelExecutorGenerationChannel.Usage.Input,
        output: LanguageModelExecutorGenerationChannel.Usage.Output,
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) -> Self {
        .init(storage: .updateUsage(.init(input: input, output: output, metadata: metadata)))
    }
}

extension LanguageModelExecutorGenerationChannel.Reasoning.Action {
    public static func appendText(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Self {
        .init(storage: .appendText(.init(content: text, segmentID: segmentID, tokenCount: tokenCount)))
    }

    public static func replaceTextSegment(_ text: String, segmentID: String? = nil, tokenCount: Int) -> Self {
        .init(storage: .replaceTextSegment(.init(content: text, segmentID: segmentID, tokenCount: tokenCount)))
    }

    public static func updateSignature(_ signature: Data, tokenCount: Int) -> Self {
        .init(storage: .updateSignature(.init(signature: signature, tokenCount: tokenCount)))
    }

    public static func updateMetadata(_ values: [String: any Sendable & Codable & Equatable]) -> Self {
        .init(storage: .updateMetadata(.init(values: values)))
    }

    public static func updateUsage(
        input: LanguageModelExecutorGenerationChannel.Usage.Input,
        output: LanguageModelExecutorGenerationChannel.Usage.Output,
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) -> Self {
        .init(storage: .updateUsage(.init(input: input, output: output, metadata: metadata)))
    }
}

extension LanguageModelExecutorGenerationChannel.ToolCalls.Action {
    public static func toolCall(
        id: String,
        name: String,
        action: LanguageModelExecutorGenerationChannel.ToolCalls.ToolCall.Action
    ) -> Self {
        .init(storage: .toolCall(.init(id: id, name: name, action: action)))
    }

    public static func removeToolCall(id: String) -> Self {
        .init(storage: .removeToolCall(id: id))
    }

    public static func updateMetadata(_ values: [String: any Sendable & Codable & Equatable]) -> Self {
        .init(storage: .updateMetadata(.init(values: values)))
    }

    public static func updateUsage(
        input: LanguageModelExecutorGenerationChannel.Usage.Input,
        output: LanguageModelExecutorGenerationChannel.Usage.Output,
        metadata: [String: any Sendable & Codable & Equatable] = [:]
    ) -> Self {
        .init(storage: .updateUsage(.init(input: input, output: output, metadata: metadata)))
    }
}

extension LanguageModelExecutorGenerationChannel.ToolCalls.ToolCall.Action {
    public static func appendArguments(_ content: String, tokenCount: Int) -> Self {
        .init(storage: .appendArguments(.init(content: content, tokenCount: tokenCount)))
    }

    public static func updateMetadata(_ values: [String: any Sendable & Codable & Equatable]) -> Self {
        .init(storage: .updateMetadata(.init(values: values)))
    }
}

// MARK: - Internal events

/// Payload for `Event.recordedToolExecution` — see that factory's doc.
package struct RecordedToolExecution: Sendable {
    package var id: String
    package var toolName: String
    package var argumentsJSON: String
    package var outputText: String
}
