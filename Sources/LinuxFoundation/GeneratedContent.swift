// GeneratedContent — the dynamic structured-content currency of the API.
// Mirrors FoundationModels.GeneratedContent (SDK 27).

import Foundation

public struct GeneratedContentError: Error, CustomStringConvertible {
    public let message: String
    init(_ message: String) { self.message = message }
    public var description: String { "GeneratedContentError: \(message)" }
}

public struct GeneratedContent: Sendable, Equatable, CustomDebugStringConvertible {
    let node: JSONNode

    /// Whether the content represents fully generated (non-partial) output.
    public var isComplete: Bool { complete }
    private let complete: Bool

    init(node: JSONNode, isComplete: Bool = true) {
        self.node = node
        self.complete = isComplete
    }

    public init(json: String) throws {
        do {
            self.node = try JSONNode.parse(json)
        } catch {
            throw GeneratedContentError("invalid JSON: \(error)")
        }
        self.complete = true
    }

    public init(properties: KeyValuePairs<String, any ConvertibleToGeneratedContent>) {
        let members = properties.map { key, value in
            JSONNode.Member(key: key, value: value.generatedContent.node)
        }
        self.init(node: .object(members))
    }

    public init(_ value: some ConvertibleToGeneratedContent) {
        self = value.generatedContent
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
