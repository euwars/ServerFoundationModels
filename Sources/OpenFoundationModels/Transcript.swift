// Transcript — the durable record of a session's conversation.
// Mirrors FoundationModels.Transcript (SDK 27): a RandomAccessCollection of
// entries (instructions, prompt, toolCalls, toolOutput, response, reasoning).

import Foundation

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

    public struct ToolCalls: Sendable, Equatable {
        public var id: String
        var calls: [ToolCall]

        init(id: String = UUID().uuidString, calls: [ToolCall]) {
            self.id = id
            self.calls = calls
        }
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

    public struct Reasoning: Sendable, Equatable {
        public var id: String
        public var segments: [Segment]

        public init(id: String = UUID().uuidString, segments: [Segment]) {
            self.id = id
            self.segments = segments
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
            }
        }.joined(separator: "\n")
    }
}
