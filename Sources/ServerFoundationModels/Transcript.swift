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
    ///
    /// `history` is the non-instructions conversation: the getter skips the
    /// leading run of `.instructions` entries, and the setter replaces
    /// everything after that prefix with the assigned value.
    ///
    /// Note that if the assigned value itself *starts* with `.instructions`
    /// entries, they become adjacent to the existing prefix and are absorbed
    /// into it: a subsequent get returns the assigned value minus those
    /// leading instructions entries (they are not lost — they remain in the
    /// transcript's instructions prefix). Assigning a value that does not
    /// start with instructions round-trips exactly.
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
            guard lhs.orientation == rhs.orientation else { return false }
            // Fast path: same CGImage instance.
            if lhs.cgImage === rhs.cgImage { return true }
            // Identity differs (e.g. two attachments loaded from the same
            // file): fall back to value-comparing the underlying bitmap so
            // semantics match Linux, where the stored Data is compared.
            guard lhs.cgImage.width == rhs.cgImage.width,
                lhs.cgImage.height == rhs.cgImage.height,
                lhs.cgImage.bitsPerPixel == rhs.cgImage.bitsPerPixel,
                lhs.cgImage.bytesPerRow == rhs.cgImage.bytesPerRow
            else { return false }
            guard let lhsData = lhs.cgImage.dataProvider?.data as Data?,
                let rhsData = rhs.cgImage.dataProvider?.data as Data?
            else { return false }
            return lhsData == rhsData
        }
        #else
        public var data: Data
        public var url: URL? { nil }
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
                && lhs.contextOptions == rhs.contextOptions
                && metadataIsEqual(lhs.metadata, rhs.metadata)
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
                && metadataIsEqual(lhs.metadata, rhs.metadata)
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
                && metadataIsEqual(lhs.metadata, rhs.metadata)
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
                && metadataIsEqual(lhs.metadata, rhs.metadata)
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

        init(name: String, schemaNode: SchemaNode?) {
            self.name = name
            self.schemaNode = schemaNode
        }
    }
}

// MARK: - Erased metadata equality

/// Pairwise erased equality for `metadata` dictionaries: same keys, and each
/// pair of values equal after dynamically matching their concrete types
/// (mirrors the `CustomSegment.isEqual` pattern).
func metadataIsEqual(
    _ lhs: [String: any Codable & Sendable & Equatable],
    _ rhs: [String: any Codable & Sendable & Equatable]
) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (key, lhsValue) in lhs {
        guard let rhsValue = rhs[key], erasedEqual(lhsValue, rhsValue) else { return false }
    }
    return true
}

private func erasedEqual(_ lhs: any Equatable, _ rhs: any Equatable) -> Bool {
    func open<Value: Equatable>(_ lhs: Value) -> Bool {
        guard let rhs = rhs as? Value else { return false }
        return lhs == rhs
    }
    return open(lhs)
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

/// Full-fidelity Codable for transcripts.
///
/// Round-trips entry IDs, segment IDs, text and structured segments, tool
/// definitions, generation options, response formats, context options, asset
/// IDs, and reasoning signatures. Decoding also accepts the legacy flat
/// format (role/id/text keys carrying joined segment text) emitted by
/// earlier releases.
///
/// Known limitations, each preserving as much as is representable:
/// - The `metadata` dictionaries are `[String: any Codable & Sendable &
///   Equatable]` existentials whose concrete types cannot be recovered when
///   decoding, so metadata is not encoded and always decodes as `[:]`.
/// - `.custom` segments encode their id and textual description (the same
///   text used to replay them in prompts). `XAIServerToolSegment` round-trips
///   via `subtype: "xai_server_tool"`. Other custom segment types decode as
///   `.text` segments preserving the id and description.
/// - Image attachments encode their id, label, orientation, and image bytes
///   (PNG-encoded on Darwin; the stored data on Linux). On Darwin the
///   decoded `CGImage` is a re-decoded copy of those bytes, equal by value
///   rather than by identity.
/// - A decoded `GenerationSchema` (in tool definitions and response formats)
///   carries the same serialized JSON Schema document as the original rather
///   than the original's structural node tree.
extension Transcript: Codable {
    public func encode(to encoder: any Encoder) throws {
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
            // Legacy and shared keys.
            case role, id, text, toolName, calls, arguments
            // Full-fidelity keys.
            case segments, toolDefinitions, options, responseFormat
            case contextOptions, assetIDs, signature
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            /// Encodes the structured segments plus the legacy joined-text
            /// rendering, so older decoders can still read new payloads.
            func encodeSegments(_ segments: [Transcript.Segment]) throws {
                try container.encode(segments.map(EncodedSegment.init), forKey: .segments)
                try container.encode(segments.map(\.description).joined(separator: "\n"), forKey: .text)
            }

            switch entry {
            case .instructions(let value):
                try container.encode("instructions", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try encodeSegments(value.segments)
                try container.encode(value.toolDefinitions, forKey: .toolDefinitions)
            case .prompt(let value):
                try container.encode("prompt", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try encodeSegments(value.segments)
                try container.encode(value.options, forKey: .options)
                try container.encodeIfPresent(value.responseFormat, forKey: .responseFormat)
                try container.encode(value.contextOptions, forKey: .contextOptions)
            case .response(let value):
                try container.encode("response", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try encodeSegments(value.segments)
                try container.encode(value.assetIDs, forKey: .assetIDs)
            case .reasoning(let value):
                try container.encode("reasoning", forKey: .role)
                try container.encode(value.id, forKey: .id)
                try encodeSegments(value.segments)
                try container.encodeIfPresent(value.signature, forKey: .signature)
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
                try encodeSegments(value.segments)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let role = try container.decode(String.self, forKey: .role)
            let id = try container.decode(String.self, forKey: .id)

            /// Structured segments when present; otherwise falls back to the
            /// legacy flat format (one text segment carrying the joined
            /// text; the legacy format did not record segment IDs).
            func segments() throws -> [Transcript.Segment] {
                if let encoded = try container.decodeIfPresent([EncodedSegment].self, forKey: .segments) {
                    return try encoded.map { try $0.segment() }
                }
                return [.text(.init(content: try container.decodeIfPresent(String.self, forKey: .text) ?? ""))]
            }

            switch role {
            case "instructions":
                entry = .instructions(.init(
                    id: id,
                    segments: try segments(),
                    toolDefinitions: try container.decodeIfPresent(
                        [Transcript.ToolDefinition].self, forKey: .toolDefinitions
                    ) ?? []
                ))
            case "prompt":
                entry = .prompt(.init(
                    id: id,
                    segments: try segments(),
                    options: try container.decodeIfPresent(GenerationOptions.self, forKey: .options)
                        ?? GenerationOptions(),
                    responseFormat: try container.decodeIfPresent(
                        Transcript.ResponseFormat.self, forKey: .responseFormat
                    ),
                    contextOptions: try container.decodeIfPresent(ContextOptions.self, forKey: .contextOptions)
                        ?? ContextOptions()
                ))
            case "response":
                entry = .response(.init(
                    id: id,
                    assetIDs: try container.decodeIfPresent([String].self, forKey: .assetIDs) ?? [],
                    segments: try segments()
                ))
            case "reasoning":
                entry = .reasoning(.init(
                    id: id,
                    segments: try segments(),
                    signature: try container.decodeIfPresent(Data.self, forKey: .signature)
                ))
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

    /// One transcript segment in its serialized form. See the limitations
    /// documented on `Transcript`'s Codable conformance for `.custom` and
    /// `.attachment` segments.
    struct EncodedSegment: Codable {
        var kind: String
        var id: String
        var content: String?
        var subtype: String?
        var source: String?
        var label: String?
        var data: Data?
        var orientation: UInt32?

        init(_ segment: Transcript.Segment) {
            subtype = nil
            switch segment {
            case .text(let text):
                kind = "text"
                id = text.id
                content = text.content
            case .structure(let structure):
                kind = "structure"
                id = structure.id
                source = structure.source
                content = structure.content.jsonString
            case .attachment(let attachment):
                kind = "attachment"
                id = attachment.id
                label = attachment.label
                switch attachment.content {
                case .image(let image):
                    #if canImport(CoreGraphics)
                    data = image.pngData  // best effort; nil when encoding fails
                    orientation = image.orientation.rawValue
                    #else
                    data = image.data
                    #endif
                }
            case .custom(let custom):
                kind = "custom"
                id = custom.id
                if let activity = custom as? XAIServerToolSegment,
                    let encoded = Self.encodeXAIContent(activity.content)
                {
                    subtype = "xai_server_tool"
                    content = encoded
                } else {
                    content = custom.description
                }
            }
        }

        func segment() throws -> Transcript.Segment {
            switch kind {
            case "text":
                return .text(.init(id: id, content: content ?? ""))
            case "structure":
                return .structure(.init(
                    id: id,
                    source: source ?? "",
                    content: try GeneratedContent(json: content ?? "null")
                ))
            case "attachment":
                guard let data, !data.isEmpty else {
                    // The image bytes could not be captured at encode time;
                    // preserve the segment as its textual placeholder.
                    return .text(.init(id: id, content: label.map { "[attachment: \($0)]" } ?? "[attachment]"))
                }
                #if canImport(CoreGraphics)
                guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                    let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
                else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: [],
                        debugDescription: "could not decode image bytes for attachment segment '\(id)'"
                    ))
                }
                let image = Transcript.ImageAttachment(
                    cgImage,
                    orientation: orientation.flatMap(CGImagePropertyOrientation.init(rawValue:))
                )
                return .attachment(.init(id: id, content: .image(image), label: label))
                #else
                return .attachment(.init(id: id, content: .image(.init(data: data)), label: label))
                #endif
            case "custom":
                if subtype == "xai_server_tool",
                    let payload = content,
                    let decoded = Self.decodeXAIContent(payload)
                {
                    return .custom(XAIServerToolSegment(id: id, content: decoded))
                }
                // Unknown custom segment types preserve replay text as a text segment.
                return .text(.init(id: id, content: content ?? ""))
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "unknown segment kind '\(kind)'"
                ))
            }
        }

        private static func encodeXAIContent(_ content: XAIServerToolSegment.Content) -> String? {
            guard let data = try? JSONEncoder().encode(content) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static func decodeXAIContent(_ payload: String) -> XAIServerToolSegment.Content? {
            guard let data = payload.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(XAIServerToolSegment.Content.self, from: data)
        }
    }
}

#if canImport(CoreGraphics)
extension Transcript.ImageAttachment {
    /// PNG-encoded bytes of the image, used when serializing transcripts.
    var pngData: Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif

extension Transcript.ToolDefinition: Codable {}

extension Transcript.ResponseFormat: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, schema
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if let schemaNode {
            try container.encode(GenerationSchema(node: schemaNode), forKey: .schema)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            schemaNode: try container.decodeIfPresent(GenerationSchema.self, forKey: .schema)?.root
        )
    }
}

// MARK: - Options Codable conformances
//
// Manual implementations: these types are declared in other files, and
// Codable synthesis is only available in same-file extensions.

extension GenerationOptions.SamplingMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode, k, threshold, seed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .greedy:
            try container.encode("greedy", forKey: .mode)
        case .top(let k, let seed):
            try container.encode("top", forKey: .mode)
            try container.encode(k, forKey: .k)
            try container.encodeIfPresent(seed, forKey: .seed)
        case .nucleus(let threshold, let seed):
            try container.encode("nucleus", forKey: .mode)
            try container.encode(threshold, forKey: .threshold)
            try container.encodeIfPresent(seed, forKey: .seed)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(String.self, forKey: .mode)
        switch mode {
        case "greedy":
            self = .greedy
        case "top":
            self.init(kind: .top(
                k: try container.decode(Int.self, forKey: .k),
                seed: try container.decodeIfPresent(UInt64.self, forKey: .seed)
            ))
        case "nucleus":
            self.init(kind: .nucleus(
                threshold: try container.decode(Double.self, forKey: .threshold),
                seed: try container.decodeIfPresent(UInt64.self, forKey: .seed)
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: container, debugDescription: "unknown sampling mode '\(mode)'"
            )
        }
    }
}

extension GenerationOptions.ToolCallingMode: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch kind {
        case .allowed: try container.encode("allowed")
        case .required: try container.encode("required")
        case .disallowed: try container.encode("disallowed")
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "allowed": self = .allowed
        case "required": self = .required
        case "disallowed": self = .disallowed
        default:
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown tool-calling mode '\(raw)'"
            )
        }
    }
}

extension GenerationOptions: Codable {
    private enum CodingKeys: String, CodingKey {
        case sampling, temperature, maximumResponseTokens, toolCalling
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(samplingMode, forKey: .sampling)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(maximumResponseTokens, forKey: .maximumResponseTokens)
        try container.encodeIfPresent(toolCallingMode, forKey: .toolCalling)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            samplingMode: try container.decodeIfPresent(SamplingMode.self, forKey: .sampling),
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
            maximumResponseTokens: try container.decodeIfPresent(Int.self, forKey: .maximumResponseTokens),
            toolCallingMode: try container.decodeIfPresent(ToolCallingMode.self, forKey: .toolCalling)
        )
    }
}

extension ContextOptions.ReasoningLevel: Codable {
    private enum CodingKeys: String, CodingKey {
        case level, custom
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .light:
            try container.encode("light", forKey: .level)
        case .moderate:
            try container.encode("moderate", forKey: .level)
        case .deep:
            try container.encode("deep", forKey: .level)
        case .custom(let value):
            try container.encode("custom", forKey: .level)
            try container.encode(value, forKey: .custom)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let level = try container.decode(String.self, forKey: .level)
        switch level {
        case "light": self = .light
        case "moderate": self = .moderate
        case "deep": self = .deep
        case "custom": self = .custom(try container.decode(String.self, forKey: .custom))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .level, in: container, debugDescription: "unknown reasoning level '\(level)'"
            )
        }
    }
}

extension ContextOptions: Codable {
    private enum CodingKeys: String, CodingKey {
        case includeSchemaInPrompt, reasoningLevel
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(includeSchemaInPrompt, forKey: .includeSchemaInPrompt)
        try container.encodeIfPresent(reasoningLevel, forKey: .reasoningLevel)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            includeSchemaInPrompt: try container.decodeIfPresent(Bool.self, forKey: .includeSchemaInPrompt),
            reasoningLevel: try container.decodeIfPresent(ReasoningLevel.self, forKey: .reasoningLevel)
        )
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
