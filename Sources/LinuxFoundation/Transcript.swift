// Transcript — the durable record of a session's conversation.
// Mirrors FoundationModels.Transcript (SDK 27): a RandomAccessCollection of
// entries (instructions, prompt, toolCalls, toolOutput, response, reasoning).

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

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

    mutating func append(_ entry: Entry) {
        entries.append(entry)
    }

    var allEntries: [Entry] { entries }

    // MARK: Entries

    public enum Entry: Sendable, Equatable, Identifiable {
        case instructions(Transcript.Instructions)
        case prompt(Transcript.Prompt)
        case toolCalls(Transcript.ToolCalls)
        case toolOutput(Transcript.ToolOutput)
        case response(Transcript.Response)
        case reasoning(Transcript.Reasoning)

        public var id: String {
            switch self {
            case .instructions(let value): return value.id
            case .prompt(let value): return value.id
            case .toolCalls(let value): return value.id
            case .toolOutput(let value): return value.id
            case .response(let value): return value.id
            case .reasoning(let value): return value.id
            }
        }
    }

    // MARK: Segments

    public enum Segment: Sendable, Equatable {
        case text(TextSegment)
        case structure(StructuredSegment)
        case attachment(AttachmentSegment)
        case custom(any CustomSegment)

        public static func == (lhs: Segment, rhs: Segment) -> Bool {
            switch (lhs, rhs) {
            case (.text(let a), .text(let b)): return a == b
            case (.structure(let a), .structure(let b)): return a == b
            case (.attachment(let a), .attachment(let b)): return a == b
            case (.custom(let a), .custom(let b)):
                return a.id == b.id && a.description == b.description
            default: return false
            }
        }
    }

    /// Executor-defined transcript segments (e.g. server-tool activity) that
    /// replay verbatim on later requests.
    public protocol CustomSegment: InstructionsRepresentable, PromptRepresentable,
        CustomStringConvertible, Equatable, Identifiable, Sendable
    where ID == String {
        associatedtype Content: Decodable, Encodable, Equatable, Sendable
        var id: String { get }
        var content: Content { get }
    }

    public enum Attachment: Sendable, Equatable {
        case image(ImageAttachment)
    }

    public struct ImageAttachment: @unchecked Sendable, Equatable {
        #if canImport(CoreGraphics)
        public var cgImage: CGImage
        public var orientation: CGImagePropertyOrientation

        public init(_ cgImage: CGImage, orientation: CGImagePropertyOrientation? = nil) {
            self.cgImage = cgImage
            self.orientation = orientation ?? .up
        }

        public static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
            lhs.cgImage === rhs.cgImage && lhs.orientation == rhs.orientation
        }
        #else
        public var data: Data
        public init(data: Data) { self.data = data }
        #endif
    }

    public struct AttachmentSegment: Sendable, Identifiable, Equatable {
        public var id: String
        public var content: Attachment
        public var label: String?

        public init(id: String = UUID().uuidString, content: Attachment, label: String? = nil) {
            self.id = id
            self.content = content
            self.label = label
        }
    }

    public struct TextSegment: Sendable, Equatable {
        public var id: String
        public var content: String

        public init(id: String = UUID().uuidString, content: String) {
            self.id = id
            self.content = content
        }
    }

    public struct StructuredSegment: Sendable, Equatable {
        public var id: String
        public var content: GeneratedContent

        public init(id: String = UUID().uuidString, content: GeneratedContent) {
            self.id = id
            self.content = content
        }
    }

    // MARK: Entry payloads

    public struct Instructions: Sendable, Equatable {
        public var id: String
        public var segments: [Segment]
        public var toolDefinitions: [ToolDefinition]

        public init(
            id: String = UUID().uuidString,
            segments: [Segment],
            toolDefinitions: [ToolDefinition] = []
        ) {
            self.id = id
            self.segments = segments
            self.toolDefinitions = toolDefinitions
        }
    }

    public struct Prompt: Sendable, Equatable {
        public var id: String
        public var segments: [Segment]
        public var options: GenerationOptions
        public var responseFormat: ResponseFormat?

        public init(
            id: String = UUID().uuidString,
            segments: [Segment],
            options: GenerationOptions = GenerationOptions(),
            responseFormat: ResponseFormat? = nil
        ) {
            self.id = id
            self.segments = segments
            self.options = options
            self.responseFormat = responseFormat
        }
    }

    public struct Response: Sendable, Equatable {
        public var id: String
        public var assetIDs: [String]
        public var segments: [Segment]

        public init(
            id: String = UUID().uuidString,
            assetIDs: [String] = [],
            segments: [Segment]
        ) {
            self.id = id
            self.assetIDs = assetIDs
            self.segments = segments
        }
    }

    public struct ToolCalls: Sendable, Identifiable, Equatable, RandomAccessCollection {
        public typealias Element = ToolCall
        public typealias Index = Int

        public var id: String
        var calls: [ToolCall]

        public init<S: Sequence>(id: String = UUID().uuidString, _ calls: S) where S.Element == ToolCall {
            self.id = id
            self.calls = Array(calls)
        }

        init(id: String = UUID().uuidString, calls: [ToolCall]) {
            self.id = id
            self.calls = calls
        }

        public var startIndex: Int { calls.startIndex }
        public var endIndex: Int { calls.endIndex }
        public subscript(position: Int) -> ToolCall { calls[position] }
    }

    public struct ToolCall: Sendable, Equatable {
        public var id: String
        public var toolName: String
        public var arguments: GeneratedContent

        public init(id: String = UUID().uuidString, toolName: String, arguments: GeneratedContent) {
            self.id = id
            self.toolName = toolName
            self.arguments = arguments
        }
    }

    public struct ToolOutput: Sendable, Equatable {
        public var id: String
        public var toolName: String
        public var segments: [Segment]

        public init(id: String = UUID().uuidString, toolName: String, segments: [Segment]) {
            self.id = id
            self.toolName = toolName
            self.segments = segments
        }
    }

    public struct Reasoning: Sendable, Equatable, Identifiable {
        public var id: String
        public var segments: [Segment]
        public var signature: Data?
        public var metadata: [String: any Codable & Sendable & Equatable]

        public init(
            id: String = UUID().uuidString,
            metadata: [String: any Sendable & Codable & Equatable] = [:],
            segments: [Segment],
            signature: Data? = nil
        ) {
            self.id = id
            self.metadata = metadata
            self.segments = segments
            self.signature = signature
        }

        public static func == (lhs: Reasoning, rhs: Reasoning) -> Bool {
            lhs.id == rhs.id && lhs.segments == rhs.segments && lhs.signature == rhs.signature
        }
    }

    public struct ToolDefinition: Sendable, Equatable {
        public var name: String
        public var description: String
        public var parameters: GenerationSchema

        public init(name: String, description: String, parameters: GenerationSchema) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public struct ResponseFormat: Sendable, Equatable {
        var name: String
        var schemaNode: SchemaNode?

        public init(schema: GenerationSchema) {
            self.name = "response"
            self.schemaNode = schema.root
        }
    }
}

extension [Transcript.Segment] {
    var joinedText: String {
        compactMap { segment in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structure): return structure.content.jsonString
            case .custom(let custom): return custom.description
            case .attachment: return nil
            }
        }.joined(separator: "\n")
    }
}
