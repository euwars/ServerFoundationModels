// GeneratedContent — the dynamic structured-content currency of the API.
// Mirrors FoundationModels.GeneratedContent (SDK 27).

import Foundation

public struct GeneratedContentError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "GeneratedContentError: \(message)" }
}

public struct GeneratedContent: Sendable, Equatable, CustomDebugStringConvertible {
    let node: JSONNode
    let generationID: GenerationID?

    /// Whether the content represents fully generated (non-partial) output.
    public var isComplete: Bool { complete }
    private let complete: Bool

    init(node: JSONNode, isComplete: Bool = true, id: GenerationID? = nil) {
        self.node = node
        self.complete = isComplete
        self.generationID = id
    }

    public init(json: String) throws {
        do {
            self.node = try JSONNode.parse(json)
        } catch {
            throw ParsingError(
                rawContent: json,
                underlyingError: error,
                debugDescription: "invalid JSON: \(error)"
            )
        }
        self.complete = true
        self.generationID = nil
    }

    public init(properties: KeyValuePairs<String, any ConvertibleToGeneratedContent>, id: GenerationID? = nil) {
        let members = properties.map { key, value in
            JSONNode.Member(key: key, value: value.generatedContent.node)
        }
        self.init(node: .object(members), id: id)
    }

    public init<S>(
        properties: S,
        id: GenerationID? = nil,
        uniquingKeysWith combine: (GeneratedContent, GeneratedContent) throws -> some ConvertibleToGeneratedContent
    ) rethrows where S: Sequence, S.Element == (String, any ConvertibleToGeneratedContent) {
        var members: [JSONNode.Member] = []
        var indexByKey: [String: Int] = [:]
        for (key, value) in properties {
            if let existing = indexByKey[key] {
                let merged = try combine(
                    GeneratedContent(node: members[existing].value),
                    value.generatedContent
                )
                members[existing] = JSONNode.Member(key: key, value: merged.generatedContent.node)
            } else {
                indexByKey[key] = members.count
                members.append(JSONNode.Member(key: key, value: value.generatedContent.node))
            }
        }
        self.init(node: .object(members), id: id)
    }

    public init<S>(elements: S, id: GenerationID? = nil)
    where S: Sequence, S.Element == any ConvertibleToGeneratedContent {
        self.init(node: .array(elements.map { $0.generatedContent.node }), id: id)
    }

    public init(_ value: some ConvertibleToGeneratedContent) {
        self = value.generatedContent
    }

    public init(_ value: some ConvertibleToGeneratedContent, id: GenerationID) {
        self.init(node: value.generatedContent.node, id: id)
    }

    public var jsonString: String { node.serialized }

    public func value<Value>(
        _ type: Value.Type = Value.self
    ) throws -> Value where Value: ConvertibleFromGeneratedContent {
        try Value(self)
    }

    public func value<Value>(
        _ type: Value.Type = Value.self,
        forProperty property: String
    ) throws -> Value where Value: ConvertibleFromGeneratedContent {
        guard case .object(let members) = node else {
            throw GeneratedContentError("content is not an object; cannot read property '\(property)'")
        }
        guard let member = members.first(where: { $0.key == property }) else {
            throw GeneratedContentError("no property named '\(property)'")
        }
        return try Value(GeneratedContent(node: member.value))
    }

    /// Optional property access: returns nil when the property is absent or
    /// explicitly null, instead of throwing.
    public func value<Value>(
        _ type: Value?.Type = Value?.self,
        forProperty property: String
    ) throws -> Value? where Value: ConvertibleFromGeneratedContent {
        guard case .object(let members) = node else {
            throw GeneratedContentError("content is not an object; cannot read property '\(property)'")
        }
        guard let member = members.first(where: { $0.key == property }) else {
            return nil
        }
        if case .null = member.value { return nil }
        return try Value(GeneratedContent(node: member.value))
    }

    public enum Kind: Equatable, Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([GeneratedContent])
        case structure(properties: [String: GeneratedContent], orderedKeys: [String])
    }

    /// A structural view of the value.
    public var kind: Kind {
        switch node {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .integer(let value): return .number(Double(value))
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .array(let elements): return .array(elements.map { GeneratedContent(node: $0) })
        case .object(let members):
            var properties: [String: GeneratedContent] = [:]
            for member in members { properties[member.key] = GeneratedContent(node: member.value) }
            return .structure(properties: properties, orderedKeys: members.map(\.key))
        }
    }

    public init(kind: Kind, id: GenerationID? = nil) {
        switch kind {
        case .null: self.init(node: .null)
        case .bool(let value): self.init(node: .bool(value))
        case .number(let value):
            self.init(node: value == value.rounded() && value.magnitude < 1e15
                ? .integer(Int(value)) : .number(value))
        case .string(let value): self.init(node: .string(value))
        case .array(let elements): self.init(node: .array(elements.map(\.node)))
        case .structure(let properties, let orderedKeys):
            self.init(node: .object(orderedKeys.compactMap { key in
                properties[key].map { JSONNode.Member(key: key, value: $0.node) }
            }))
        }
    }

    /// The id of the generation this content came from, when known.
    public var id: GenerationID? { generationID }

    public static let null = GeneratedContent(node: .null)

    /// Parses a possibly-incomplete JSON prefix, marking the result partial.
    static func partial(json: String) -> GeneratedContent? {
        JSONNode.parseLenient(json).map { GeneratedContent(node: $0, isComplete: false) }
    }

    public var debugDescription: String { "GeneratedContent(\(node.serialized))" }

    public static func == (lhs: GeneratedContent, rhs: GeneratedContent) -> Bool {
        lhs.node == rhs.node
    }
}

extension GeneratedContent: Generable {
    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .object(name: "GeneratedContent", description: nil, properties: []))
    }

    public init(_ content: GeneratedContent) throws {
        self = content
    }

    public var generatedContent: GeneratedContent { self }
}
