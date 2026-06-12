// GenerationSchema / DynamicGenerationSchema / GenerationGuide.
// Mirrors FoundationModels (SDK 27).

import Foundation

indirect enum SchemaNode: Sendable, Equatable {
    struct Property: Sendable, Equatable {
        var name: String
        var description: String?
        var node: SchemaNode
        var isOptional: Bool
    }

    case string(description: String?, enumChoices: [String]?)
    case integer(description: String?)
    case number(description: String?)
    case boolean(description: String?)
    case object(name: String, description: String?, properties: [Property])
    case array(description: String?, item: SchemaNode, minimumElements: Int?, maximumElements: Int?)
    case reference(String)

    /// Standard JSON Schema rendering, used for chat-completions
    /// `response_format` and tool parameter definitions.
    var jsonSchema: JSONNode {
        var members: [JSONNode.Member] = []
        func describe(_ description: String?) {
            if let description {
                members.append(.init(key: "description", value: .string(description)))
            }
        }
        switch self {
        case .string(let description, let enumChoices):
            members.append(.init(key: "type", value: .string("string")))
            describe(description)
            if let enumChoices {
                members.append(.init(key: "enum", value: .array(enumChoices.map { .string($0) })))
            }
        case .integer(let description):
            members.append(.init(key: "type", value: .string("integer")))
            describe(description)
        case .number(let description):
            members.append(.init(key: "type", value: .string("number")))
            describe(description)
        case .boolean(let description):
            members.append(.init(key: "type", value: .string("boolean")))
            describe(description)
        case .object(_, let description, let properties):
            members.append(.init(key: "type", value: .string("object")))
            describe(description)
            var propertyMembers: [JSONNode.Member] = []
            for property in properties {
                var node = property.node.jsonSchema
                if let propertyDescription = property.description, case .object(var inner) = node {
                    inner.removeAll { $0.key == "description" }
                    inner.insert(.init(key: "description", value: .string(propertyDescription)), at: 0)
                    node = .object(inner)
                }
                propertyMembers.append(.init(key: property.name, value: node))
            }
            members.append(.init(key: "properties", value: .object(propertyMembers)))
            let required = properties.filter { !$0.isOptional }.map { JSONNode.string($0.name) }
            members.append(.init(key: "required", value: .array(required)))
            members.append(.init(key: "additionalProperties", value: .bool(false)))
        case .array(let description, let item, let minimumElements, let maximumElements):
            members.append(.init(key: "type", value: .string("array")))
            describe(description)
            members.append(.init(key: "items", value: item.jsonSchema))
            if let minimumElements {
                members.append(.init(key: "minItems", value: .integer(minimumElements)))
            }
            if let maximumElements {
                members.append(.init(key: "maxItems", value: .integer(maximumElements)))
            }
        case .reference(let name):
            members.append(.init(key: "$ref", value: .string("#/$defs/\(name)")))
        }
        return .object(members)
    }
}

public struct GenerationSchema: Sendable, Equatable, CustomDebugStringConvertible {
    let root: SchemaNode

    init(node: SchemaNode) {
        self.root = node
    }

    public init(root: DynamicGenerationSchema, dependencies: [DynamicGenerationSchema]) throws {
        // Reference resolution across dependencies arrives with @Generable
        // macro support; the scenarios exercised so far use inline schemas.
        self.root = root.node
    }

    public init(type: any Generable.Type, description: String? = nil, anyOf choices: [String]) {
        self.root = .string(description: description, enumChoices: choices)
    }

    public var debugDescription: String { root.jsonSchema.serialized }

    public struct Property: Sendable {
        let name: String
        let description: String?
        let node: SchemaNode

        public init<Value>(
            name: String,
            description: String? = nil,
            type: Value.Type,
            guides: [GenerationGuide<Value>] = []
        ) where Value: Generable {
            self.name = name
            self.description = description
            self.node = Value.generationSchema.root
        }
    }

    public init(type: any Generable.Type, description: String? = nil, properties: [Property]) {
        self.root = .object(
            name: String(describing: type),
            description: description,
            properties: properties.map {
                .init(name: $0.name, description: $0.description, node: $0.node, isOptional: false)
            }
        )
    }
}

public struct DynamicGenerationSchema: Sendable {
    let node: SchemaNode

    public init(name: String, description: String? = nil, properties: [Property]) {
        self.node = .object(
            name: name,
            description: description,
            properties: properties.map {
                .init(name: $0.name, description: $0.description, node: $0.schema.node, isOptional: $0.isOptional)
            }
        )
    }

    public init(name: String, description: String? = nil, anyOf choices: [String]) {
        self.node = .string(description: description, enumChoices: choices)
    }

    public init<Value>(type: Value.Type, guides: [GenerationGuide<Value>] = []) where Value: Generable {
        self.node = Value.generationSchema.root
    }

    public init(
        arrayOf itemSchema: DynamicGenerationSchema,
        minimumElements: Int? = nil,
        maximumElements: Int? = nil
    ) {
        self.node = .array(
            description: nil,
            item: itemSchema.node,
            minimumElements: minimumElements,
            maximumElements: maximumElements
        )
    }

    public init(referenceTo name: String) {
        self.node = .reference(name)
    }

    public struct Property: Sendable {
        let name: String
        let description: String?
        let schema: DynamicGenerationSchema
        let isOptional: Bool

        public init(
            name: String,
            description: String? = nil,
            schema: DynamicGenerationSchema,
            isOptional: Bool = false
        ) {
            self.name = name
            self.description = description
            self.schema = schema
            self.isOptional = isOptional
        }
    }
}

public struct GenerationGuide<Value>: Sendable {}
