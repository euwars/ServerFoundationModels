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

    /// The conversation after any leading instructions.
    public var history: ArraySlice<Entry> {
        get {
            let start = entries.firstIndex { entry in
                if case .instructions = entry { return false }
                return true
            } ?? entries.endIndex
            return entries[start...]
        }
        set {
            let start = entries.firstIndex { entry in
                if case .instructions = entry { return false }
                return true
            } ?? entries.endIndex
            entries.replaceSubrange(start..., with: newValue)
        }
    }

    public mutating func replaceSubrange<C>(
        _ subrange: Range<Int>,
        with newElements: consuming C
    ) where C: Collection, C.Element == Entry {
        entries.replaceSubrange(subrange, with: newElements)
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

    public enum Segment: Sendable, Equatable, Identifiable {
        case text(TextSegment)
        case structure(StructuredSegment)
        case attachment(AttachmentSegment)
        case custom(any CustomSegment)

        public var id: String {
            switch self {
            case .text(let segment): return segment.id
            case .structure(let segment): return segment.id
            case .attachment(let segment): return segment.id
            case .custom(let segment): return segment.id
            }
        }

        public static func == (lhs: Segment, rhs: Segment) -> Bool {
            switch (lhs, rhs) {
            case (.text(let a), .text(let b)): return a == b
            case (.structure(let a), .structure(let b)): return a == b
            case (.attachment(let a), .attachment(let b)): return a == b
            case (.custom(let a), .custom(let b)):
                return a.isEqual(to: b)
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
        var sourceURL: URL?

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
        public var source: String
        public var content: GeneratedContent

        public var schemaName: String { source }

        public init(id: String = UUID().uuidString, content: GeneratedContent) {
            self.id = id
            self.source = ""
            self.content = content
        }

        public init(id: String = UUID().uuidString, source: String, content: GeneratedContent) {
            self.id = id
            self.source = source
            self.content = content
        }

        public init(id: String = UUID().uuidString, schemaName: String, content: GeneratedContent) {
            self.id = id
            self.source = schemaName
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
            toolDefinitions: [ToolDefinition]
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
        public var contextOptions: ContextOptions
        public var metadata: [String: any Codable & Sendable & Equatable]

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
            self.contextOptions = ContextOptions()
            self.metadata = [:]
        }

        public init(
            id: String = UUID().uuidString,
            metadata: [String: any Sendable & Codable & Equatable] = [:],
            segments: [Segment],
            options: GenerationOptions = GenerationOptions(),
            responseFormat: ResponseFormat? = nil,
            contextOptions: ContextOptions = ContextOptions()
        ) {
            self.id = id
            self.metadata = metadata
            self.segments = segments
            self.options = options
            self.responseFormat = responseFormat
            self.contextOptions = contextOptions
        }

        public static func == (lhs: Prompt, rhs: Prompt) -> Bool {
            lhs.id == rhs.id && lhs.segments == rhs.segments
                && lhs.options == rhs.options && lhs.responseFormat == rhs.responseFormat
        }
    }

    public struct Response: Sendable, Equatable {
        public var id: String
        public var assetIDs: [String]
        public var segments: [Segment]
        public var metadata: [String: any Codable & Sendable & Equatable]

        public init(
            id: String = UUID().uuidString,
            assetIDs: [String],
            segments: [Segment]
        ) {
            self.id = id
            self.assetIDs = assetIDs
            self.segments = segments
            self.metadata = [:]
        }

        public init(
            id: String = UUID().uuidString,
            metadata: [String: any Sendable & Codable & Equatable] = [:],
            segments: [Segment]
        ) {
            self.id = id
            self.assetIDs = []
            self.segments = segments
            self.metadata = metadata
        }

        public static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.id == rhs.id && lhs.assetIDs == rhs.assetIDs && lhs.segments == rhs.segments
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
        public var metadata: [String: any Codable & Sendable & Equatable]

        public init(id: String, toolName: String, arguments: GeneratedContent) {
            self.id = id
            self.toolName = toolName
            self.arguments = arguments
            self.metadata = [:]
        }

        public init(
            id: String,
            metadata: [String: any Codable & Sendable & Equatable],
            toolName: String,
            arguments: GeneratedContent
        ) {
            self.id = id
            self.metadata = metadata
            self.toolName = toolName
            self.arguments = arguments
        }

        public static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
            lhs.id == rhs.id && lhs.toolName == rhs.toolName && lhs.arguments == rhs.arguments
        }
    }

    public struct ToolOutput: Sendable, Equatable {
        public var id: String
        public var toolName: String
        public var segments: [Segment]

        public init(id: String, toolName: String, segments: [Segment]) {
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

        public init(tool: any Tool) {
            self.name = tool.name
            self.description = tool.description
            self.parameters = tool.parameters
        }

        public init(name: String, description: String, parameters: GenerationSchema) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public struct ResponseFormat: Sendable, Equatable {
        public var name: String
        var schemaNode: SchemaNode?

        public init(schema: GenerationSchema) {
            if case .object(let typeName, _, _) = schema.root {
                self.name = typeName
            } else {
                self.name = "response"
            }
            self.schemaNode = schema.root
        }

        public init<Content>(type: Content.Type) where Content: Generable {
            self.init(schema: Content.generationSchema)
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


// MARK: - Descriptions

extension Transcript.Entry: CustomStringConvertible {
    public var description: String {
        switch self {
        case .instructions(let value): return value.description
        case .prompt(let value): return value.description
        case .toolCalls(let value): return value.description
        case .toolOutput(let value): return value.description
        case .response(let value): return value.description
        case .reasoning(let value): return value.description
        }
    }
}

extension Transcript.Segment: CustomStringConvertible {
    public var description: String {
        switch self {
        case .text(let segment): return segment.description
        case .structure(let segment): return segment.description
        case .attachment(let segment): return segment.description
        case .custom(let segment): return segment.description
        }
    }
}

extension Transcript.TextSegment: CustomStringConvertible {
    public var description: String { content }
}

extension Transcript.StructuredSegment: CustomStringConvertible {
    public var description: String { content.jsonString }
}

extension Transcript.AttachmentSegment: CustomStringConvertible {
    public var description: String { label.map { "[attachment: \($0)]" } ?? "[attachment]" }
}

extension Transcript.Instructions: CustomStringConvertible {
    public var description: String { segments.map(\.description).joined(separator: "\n") }
}

extension Transcript.Prompt: CustomStringConvertible {
    public var description: String { segments.map(\.description).joined(separator: "\n") }
}

extension Transcript.Response: CustomStringConvertible {
    public var description: String { segments.map(\.description).joined(separator: "\n") }
}

extension Transcript.Reasoning: CustomStringConvertible {
    public var description: String { segments.map(\.description).joined(separator: "\n") }
}

extension Transcript.ToolCall: CustomStringConvertible {
    public var description: String { "\(toolName)(\(arguments.jsonString))" }
}

extension Transcript.ToolCalls: CustomStringConvertible {
    public var description: String { calls.map(\.description).joined(separator: "\n") }
}

extension Transcript.ResponseFormat: CustomStringConvertible {
    public var description: String { name }
}

extension Transcript.ToolOutput: CustomStringConvertible {
    public var description: String { "\(toolName) -> \(segments.map(\.description).joined(separator: "\n"))" }
}

// MARK: - CustomSegment defaults

extension Transcript.CustomSegment {
    public var description: String { String(describing: content) }

    public var promptRepresentation: Prompt { Prompt(text: description) }
    public var instructionsRepresentation: Instructions { Instructions(text: description) }

    /// Type-erased equality, used when comparing segments.
    public func isEqual(to other: any Transcript.CustomSegment) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

// MARK: - Codable

extension Transcript: Codable {
    public func encode(to encoder: any Encoder) throws {
        // Encodes the canonical JSON rendering of each entry.
        var container = encoder.unkeyedContainer()
        for entry in self {
            try container.encode(EncodedEntry(entry))
        }
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var entries: [Entry] = []
        while !container.isAtEnd {
            entries.append(try container.decode(EncodedEntry.self).entry)
        }
        self.init(entries: entries)
    }

    struct EncodedEntry: Codable {
        let entry: Entry

        init(_ entry: Entry) { self.entry = entry }

        enum CodingKeys: String, CodingKey {
            case role, id, text, toolName, calls, arguments
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch entry {
            case .instructions(let value):
                try container.encode("instructions", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try container.encode(value.segments.map(\.description).joined(separator: "\n"), forKey: .text)
            case .prompt(let value):
                try container.encode("prompt", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try container.encode(value.segments.map(\.description).joined(separator: "\n"), forKey: .text)
            case .response(let value):
                try container.encode("response", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try container.encode(value.segments.map(\.description).joined(separator: "\n"), forKey: .text)
            case .reasoning(let value):
                try container.encode("reasoning", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try container.encode(value.segments.map(\.description).joined(separator: "\n"), forKey: .text)
            case .toolCalls(let value):
                try container.encode("toolCalls", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try container.encode(value.calls.map { call in
                    EncodedToolCall(id: call.id, toolName: call.toolName, arguments: call.arguments.jsonString)
                }, forKey: .calls)
            case .toolOutput(let value):
                try container.encode("toolOutput", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try container.encode(value.toolName, forKey: .toolName)
                try container.encode(value.segments.map(\.description).joined(separator: "\n"), forKey: .text)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let role = try container.decode(String.self, forKey: .role)
            let id = try container.decode(String.self, forKey: .id)
            func segments() throws -> [Transcript.Segment] {
                [.text(.init(content: try container.decodeIfPresent(String.self, forKey: .text) ?? ""))]
            }
            switch role {
            case "instructions":
                entry = .instructions(.init(id: id, segments: try segments(), toolDefinitions: []))
            case "prompt":
                entry = .prompt(.init(id: id, segments: try segments()))
            case "response":
                entry = .response(.init(id: id, segments: try segments()))
            case "reasoning":
                entry = .reasoning(.init(id: id, segments: try segments()))
            case "toolCalls":
                let calls = try container.decode([EncodedToolCall].self, forKey: .calls)
                entry = .toolCalls(.init(id: id, calls: try calls.map {
                    Transcript.ToolCall(
                        id: $0.id,
                        toolName: $0.toolName,
                        arguments: try GeneratedContent(json: $0.arguments)
                    )
                }))
            case "toolOutput":
                entry = .toolOutput(.init(
                    id: id,
                    toolName: try container.decode(String.self, forKey: .toolName),
                    segments: try segments()
                ))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .role, in: container, debugDescription: "unknown entry role '\(role)'"
                )
            }
        }

        struct EncodedToolCall: Codable {
            var id: String
            var toolName: String
            var arguments: String
        }
    }
}

// MARK: - Image attachment conveniences

#if canImport(CoreImage)
import CoreImage
import CoreVideo

extension Transcript.ImageAttachment {
    /// The image as a CIImage.
    public var ciImage: CIImage {
        CIImage(cgImage: cgImage)
    }

    /// The image as a pixel buffer, when convertible.
    public var pixelBuffer: CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true]
        CVPixelBufferCreate(
            kCFAllocatorDefault, cgImage.width, cgImage.height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        )
        guard let buffer else { return nil }
        CIContext().render(ciImage, to: buffer)
        return buffer
    }

    /// The source URL, when the image was loaded from one.
    public var url: URL? { sourceURL }

    public init(_ ciImage: CIImage, orientation: CGImagePropertyOrientation? = nil) {
        let context = CIContext()
        let cgImage = context.createCGImage(ciImage, from: ciImage.extent)
            ?? context.createCGImage(CIImage(color: .black).cropped(to: .init(x: 0, y: 0, width: 1, height: 1)), from: .init(x: 0, y: 0, width: 1, height: 1))!
        self.init(cgImage, orientation: orientation)
    }

    public init(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation? = nil) {
        self.init(CIImage(cvPixelBuffer: pixelBuffer), orientation: orientation)
    }

    public init(imageURL: URL, orientation: CGImagePropertyOrientation? = nil) throws {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw GeneratedContentError("could not load image at \(imageURL)")
        }
        self.init(cgImage, orientation: orientation)
        self.sourceURL = imageURL
    }
}
#endif
