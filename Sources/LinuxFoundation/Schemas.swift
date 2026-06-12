// GenerationSchema / DynamicGenerationSchema / GenerationGuide.
// Mirrors FoundationModels (SDK 27).
//
// Design note: nested Generable schemas are embedded inline, recursively —
// never as $ref/$defs references. A schema for arrays of structs containing
// arrays of structs renders as one self-contained JSON Schema document.

import Foundation

indirect enum SchemaNode: Sendable, Equatable {
    struct Property: Sendable, Equatable {
        var name: String
        var description: String?
        var node: SchemaNode
        var isOptional: Bool
    }

    case string(description: String?, enumChoices: [String]?, pattern: String?)
    case integer(description: String?, minimum: Int?, maximum: Int?)
    case number(description: String?, minimum: Double?, maximum: Double?)
    case boolean(description: String?)
    case object(name: String, description: String?, properties: [Property])
    case array(description: String?, item: SchemaNode, minimumElements: Int?, maximumElements: Int?)
    case anyOf(name: String, description: String?, choices: [SchemaNode])
    case reference(String)
    /// An opaque JSON Schema document (from decoding a serialized schema).
    case raw(JSONNode)

    /// All `$ref` names reachable from this node.
    func collectReferences(into references: inout Set<String>) {
        switch self {
        case .reference(let name):
            references.insert(name)
        case .anyOf(_, _, let choices):
            for choice in choices { choice.collectReferences(into: &references) }
        case .object(_, _, let properties):
            for property in properties {
                property.node.collectReferences(into: &references)
            }
        case .array(_, let item, _, _):
            item.collectReferences(into: &references)
        case .string, .integer, .number, .boolean, .raw:
            break
        }
    }

    /// Finds the object node carrying the given type name, for hoisting
    /// referenced definitions into `$defs`.
    func findObject(named target: String) -> SchemaNode? {
        switch self {
        case .object(let name, _, let properties):
            if name == target { return self }
            for property in properties {
                if let found = property.node.findObject(named: target) { return found }
            }
            return nil
        case .array(_, let item, _, _):
            return item.findObject(named: target)
        case .anyOf(let name, _, let choices):
            if name == target { return self }
            for choice in choices {
                if let found = choice.findObject(named: target) { return found }
            }
            return nil
        case .string, .integer, .number, .boolean, .reference, .raw:
            return nil
        }
    }

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
        case .string(let description, let enumChoices, let pattern):
            members.append(.init(key: "type", value: .string("string")))
            describe(description)
            if let enumChoices {
                members.append(.init(key: "enum", value: .array(enumChoices.map { .string($0) })))
            }
            if let pattern {
                members.append(.init(key: "pattern", value: .string(pattern)))
            }
        case .integer(let description, let minimum, let maximum):
            members.append(.init(key: "type", value: .string("integer")))
            describe(description)
            if let minimum { members.append(.init(key: "minimum", value: .integer(minimum))) }
            if let maximum { members.append(.init(key: "maximum", value: .integer(maximum))) }
        case .number(let description, let minimum, let maximum):
            members.append(.init(key: "type", value: .string("number")))
            describe(description)
            if let minimum { members.append(.init(key: "minimum", value: .number(minimum))) }
            if let maximum { members.append(.init(key: "maximum", value: .number(maximum))) }
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
        case .anyOf(_, let description, let choices):
            describe(description)
            members.append(.init(key: "anyOf", value: .array(choices.map(\.jsonSchema))))
        case .reference(let name):
            members.append(.init(key: "$ref", value: .string("#/$defs/\(name)")))
        case .raw(let node):
            return node
        }
        return .object(members)
    }
}

/// Wrapper types whose schema delegates to a wrapped type; transparent to
/// recursion detection.
protocol SchemaTransparentType {}
extension Array: SchemaTransparentType {}
extension Optional: SchemaTransparentType {}

// MARK: - Cycle-safe schema construction

/// Builds the schema node for a Generable type, detecting recursive types
/// (an object nesting its own type) and emitting a `$ref` in place of the
/// infinite inline expansion. The matching `$defs` entry is hoisted at
/// render time by `GenerationSchema.jsonSchemaDocument`.
enum SchemaCycleGuard {
    private static let threadKey = "LinuxFoundation.SchemaCycleGuard.typesInProgress"

    static func node<Value: Generable>(for type: Value.Type) -> SchemaNode {
        // Wrapper types (Array, Optional) are transparent: cycles are detected
        // and named at the nominal object type they wrap, so a recursive
        // FileNode cuts at "$ref": "#/$defs/FileNode", not "Array<FileNode>".
        if Value.self is any SchemaTransparentType.Type {
            return Value.generationSchema.root
        }
        let identifier = ObjectIdentifier(Value.self)
        var inProgress = Thread.current.threadDictionary[threadKey] as? Set<ObjectIdentifier> ?? []
        if inProgress.contains(identifier) {
            return .reference(String(describing: Value.self))
        }
        inProgress.insert(identifier)
        Thread.current.threadDictionary[threadKey] = inProgress
        defer {
            var current = Thread.current.threadDictionary[threadKey] as? Set<ObjectIdentifier> ?? []
            current.remove(identifier)
            Thread.current.threadDictionary[threadKey] = current
        }
        return Value.generationSchema.root
    }
}

// MARK: - GenerationGuide

enum GenerationGuideConstraint: Sendable {
    case minimumInt(Int)
    case maximumInt(Int)
    case minimumNumber(Double)
    case maximumNumber(Double)
    case anyOf([String])
    case constant(String)
    case minimumCount(Int)
    case maximumCount(Int)
    case element([GenerationGuideConstraint])
}

public struct GenerationGuide<Value>: Sendable {
    typealias Constraint = GenerationGuideConstraint

    let constraints: [Constraint]

    init(_ constraints: [Constraint]) {
        self.constraints = constraints
    }

    func apply(to node: SchemaNode) -> SchemaNode {
        var node = node
        for constraint in constraints {
            switch (constraint, node) {
            case (.minimumInt(let value), .integer(let description, _, let maximum)):
                node = .integer(description: description, minimum: value, maximum: maximum)
            case (.maximumInt(let value), .integer(let description, let minimum, _)):
                node = .integer(description: description, minimum: minimum, maximum: value)
            case (.minimumNumber(let value), .number(let description, _, let maximum)):
                node = .number(description: description, minimum: value, maximum: maximum)
            case (.maximumNumber(let value), .number(let description, let minimum, _)):
                node = .number(description: description, minimum: minimum, maximum: value)
            case (.anyOf(let choices), .string(let description, _, let pattern)):
                node = .string(description: description, enumChoices: choices, pattern: pattern)
            case (.constant(let value), .string(let description, _, let pattern)):
                node = .string(description: description, enumChoices: [value], pattern: pattern)
            case (.minimumCount(let count), .array(let description, let item, _, let maximum)):
                node = .array(description: description, item: item, minimumElements: count, maximumElements: maximum)
            case (.maximumCount(let count), .array(let description, let item, let minimum, _)):
                node = .array(description: description, item: item, minimumElements: minimum, maximumElements: count)
            case (.element(let constraints), .array(let description, let item, let minimum, let maximum)):
                let guided = GenerationGuide<Never>(constraints).apply(to: item)
                node = .array(description: description, item: guided, minimumElements: minimum, maximumElements: maximum)
            default:
                continue
            }
        }
        return node
    }
}

extension GenerationGuide where Value == String {
    public static func constant(_ value: String) -> GenerationGuide<String> {
        GenerationGuide<String>([.constant(value)])
    }

    /// Constrains generation to match a regex. Swift's Regex does not expose
    /// its source pattern, so this guide is honored by backends with native
    /// regex support and otherwise documented as advisory.
    public static func pattern<Output>(_ regex: Regex<Output>) -> GenerationGuide<String> {
        GenerationGuide<String>([])
    }

    public static func anyOf(_ values: [String]) -> GenerationGuide<String> {
        GenerationGuide<String>([.anyOf(values)])
    }
}

extension GenerationGuide where Value == Int {
    public static func minimum(_ value: Int) -> GenerationGuide<Int> {
        GenerationGuide<Int>([.minimumInt(value)])
    }

    public static func maximum(_ value: Int) -> GenerationGuide<Int> {
        GenerationGuide<Int>([.maximumInt(value)])
    }

    public static func range(_ range: ClosedRange<Int>) -> GenerationGuide<Int> {
        GenerationGuide<Int>([.minimumInt(range.lowerBound), .maximumInt(range.upperBound)])
    }
}

extension GenerationGuide where Value == Float {
    public static func minimum(_ value: Float) -> GenerationGuide<Float> {
        GenerationGuide<Float>([.minimumNumber(Double(value))])
    }

    public static func maximum(_ value: Float) -> GenerationGuide<Float> {
        GenerationGuide<Float>([.maximumNumber(Double(value))])
    }

    public static func range(_ range: ClosedRange<Float>) -> GenerationGuide<Float> {
        GenerationGuide<Float>([.minimumNumber(Double(range.lowerBound)), .maximumNumber(Double(range.upperBound))])
    }
}

extension GenerationGuide where Value == Decimal {
    public static func minimum(_ value: Decimal) -> GenerationGuide<Decimal> {
        GenerationGuide<Decimal>([.minimumNumber((value as NSDecimalNumber).doubleValue)])
    }

    public static func maximum(_ value: Decimal) -> GenerationGuide<Decimal> {
        GenerationGuide<Decimal>([.maximumNumber((value as NSDecimalNumber).doubleValue)])
    }

    public static func range(_ range: ClosedRange<Decimal>) -> GenerationGuide<Decimal> {
        GenerationGuide<Decimal>([
            .minimumNumber((range.lowerBound as NSDecimalNumber).doubleValue),
            .maximumNumber((range.upperBound as NSDecimalNumber).doubleValue),
        ])
    }
}

extension GenerationGuide where Value == Double {
    public static func minimum(_ value: Double) -> GenerationGuide<Double> {
        GenerationGuide<Double>([.minimumNumber(value)])
    }

    public static func maximum(_ value: Double) -> GenerationGuide<Double> {
        GenerationGuide<Double>([.maximumNumber(value)])
    }

    public static func range(_ range: ClosedRange<Double>) -> GenerationGuide<Double> {
        GenerationGuide<Double>([.minimumNumber(range.lowerBound), .maximumNumber(range.upperBound)])
    }
}

extension GenerationGuide {
    /// Applies a guide to every element of an array.
    public static func element<Element>(_ guide: GenerationGuide<Element>) -> GenerationGuide<[Element]> where Value == [Element] {
        GenerationGuide<[Element]>([.element(guide.constraints)])
    }

    public static func minimumCount<Element>(_ count: Int) -> GenerationGuide<[Element]> where Value == [Element] {
        GenerationGuide<[Element]>([.minimumCount(count)])
    }

    public static func maximumCount<Element>(_ count: Int) -> GenerationGuide<[Element]> where Value == [Element] {
        GenerationGuide<[Element]>([.maximumCount(count)])
    }

    public static func count<Element>(_ count: Int) -> GenerationGuide<[Element]> where Value == [Element] {
        GenerationGuide<[Element]>([.minimumCount(count), .maximumCount(count)])
    }

    public static func count<Element>(_ range: ClosedRange<Int>) -> GenerationGuide<[Element]> where Value == [Element] {
        GenerationGuide<[Element]>([.minimumCount(range.lowerBound), .maximumCount(range.upperBound)])
    }
}

// In attribute position (`@Guide(description:_, .count(2))`) the generic
// parameter T is undetermined, so — exactly like Apple's framework — provide
// non-generic [Never] overloads that satisfy the type checker. The Generable
// macro re-emits the guide expressions in a fully typed context; these
// placeholders are never executed.
extension GenerationGuide where Value == [Never] {
    public static func minimumCount(_ count: Int) -> GenerationGuide<Value> {
        fatalError("GenerationGuide<[Never]>.\(#function) should not be called.")
    }

    public static func maximumCount(_ count: Int) -> GenerationGuide<Value> {
        fatalError("GenerationGuide<[Never]>.\(#function) should not be called.")
    }

    public static func count(_ range: ClosedRange<Int>) -> GenerationGuide<Value> {
        fatalError("GenerationGuide<[Never]>.\(#function) should not be called.")
    }

    @_disfavoredOverload
    public static func count(_ count: Int) -> GenerationGuide<Value> {
        fatalError("GenerationGuide<[Never]>.\(#function) should not be called.")
    }
}

// MARK: - GenerationSchema

public struct GenerationSchema: Sendable, Equatable, Codable, CustomDebugStringConvertible {
    let root: SchemaNode

    public func encode(to encoder: any Encoder) throws {
        try jsonSchemaDocument.encode(to: encoder)
    }

    public init(from decoder: any Decoder) throws {
        self.root = .raw(try JSONNode(from: decoder))
    }

    init(node: SchemaNode) {
        self.root = node
    }

    public init(root: DynamicGenerationSchema, dependencies: [DynamicGenerationSchema]) throws {
        // Validate that every reference resolves within root + dependencies,
        // and that named types are not defined twice.
        var definedNames: [String] = []
        func collectNames(_ node: SchemaNode) {
            if case .object(let name, _, let properties) = node {
                definedNames.append(name)
                for property in properties { collectNames(property.node) }
            } else if case .array(_, let item, _, _) = node {
                collectNames(item)
            }
        }
        collectNames(root.node)
        for dependency in dependencies { collectNames(dependency.node) }

        let duplicates = Dictionary(grouping: definedNames, by: { $0 }).filter { $1.count > 1 }
        if let duplicate = duplicates.keys.sorted().first {
            throw SchemaError.duplicateType(
                schema: nil,
                type: duplicate,
                context: .init(debugDescription: "Duplicate type \(duplicate) in schema")
            )
        }

        var references: Set<String> = []
        root.node.collectReferences(into: &references)
        for dependency in dependencies { dependency.node.collectReferences(into: &references) }
        let unresolved = references.subtracting(definedNames).sorted()
        if !unresolved.isEmpty {
            throw SchemaError.undefinedReferences(
                schema: nil,
                references: unresolved,
                context: .init(debugDescription: "Undefined references: \(unresolved.joined(separator: ", "))")
            )
        }

        self.root = root.node
    }

    public init(type: any Generable.Type, description: String? = nil, anyOf choices: [String]) {
        self.root = .string(description: description, enumChoices: choices, pattern: nil)
    }

    public init(type: any Generable.Type, description: String? = nil, anyOf types: [any Generable.Type]) {
        self.root = .anyOf(
            name: String(describing: type),
            description: description,
            choices: types.map { $0.generationSchema.root }
        )
    }

    public init(
        type: any Generable.Type,
        description: String? = nil,
        representNilExplicitlyInGeneratedContent explicitNil: Bool,
        properties: [Property]
    ) {
        self.init(type: type, description: description, properties: properties)
    }

    public init(type: any Generable.Type, description: String? = nil, properties: [Property]) {
        self.root = .object(
            name: String(describing: type),
            description: description,
            properties: properties.map {
                .init(name: $0.name, description: $0.description, node: $0.node, isOptional: $0.isOptional)
            }
        )
    }

    public var debugDescription: String { jsonSchemaDocument.serialized }

    /// Full JSON Schema document. When the schema is recursive, referenced
    /// type definitions are hoisted into `$defs` so every `$ref` resolves.
    var jsonSchemaDocument: JSONNode {
        var references: Set<String> = []
        root.collectReferences(into: &references)
        guard !references.isEmpty else { return root.jsonSchema }

        var definitions: [JSONNode.Member] = []
        for name in references.sorted() {
            if let definition = root.findObject(named: name) {
                definitions.append(.init(key: name, value: definition.jsonSchema))
            }
        }

        // Self-recursive root: the root object is itself a definition.
        if case .object(let name, _, _) = root, references.contains(name) {
            return .object([
                .init(key: "$defs", value: .object(definitions)),
                .init(key: "$ref", value: .string("#/$defs/\(name)")),
            ])
        }

        guard case .object(var members) = root.jsonSchema else { return root.jsonSchema }
        members.insert(.init(key: "$defs", value: .object(definitions)), at: 0)
        return .object(members)
    }

    public struct Property: Sendable {
        let name: String
        let description: String?
        let node: SchemaNode
        let isOptional: Bool

        public init<Value>(
            name: String,
            description: String? = nil,
            type: Value.Type,
            guides: [GenerationGuide<Value>] = []
        ) where Value: Generable {
            self.name = name
            self.description = description
            self.node = guides.reduce(SchemaCycleGuard.node(for: Value.self)) { $1.apply(to: $0) }
            self.isOptional = false
        }

        public init<Value>(
            name: String,
            description: String? = nil,
            type: Value?.Type,
            guides: [GenerationGuide<Value>] = []
        ) where Value: Generable {
            self.name = name
            self.description = description
            self.node = guides.reduce(SchemaCycleGuard.node(for: Value.self)) { $1.apply(to: $0) }
            self.isOptional = true
        }

        /// Regex guides are advisory: Swift's Regex does not expose its
        /// source pattern for schema rendering.
        public init<RegexOutput>(
            name: String,
            description: String? = nil,
            type: String.Type,
            guides: [Regex<RegexOutput>] = []
        ) {
            self.name = name
            self.description = description
            self.node = .string(description: nil, enumChoices: nil, pattern: nil)
            self.isOptional = false
        }

        public init<RegexOutput>(
            name: String,
            description: String? = nil,
            type: String?.Type,
            guides: [Regex<RegexOutput>] = []
        ) {
            self.name = name
            self.description = description
            self.node = .string(description: nil, enumChoices: nil, pattern: nil)
            self.isOptional = true
        }
    }
}

// MARK: - DynamicGenerationSchema

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
        self.node = .string(description: description, enumChoices: choices, pattern: nil)
    }

    public init(name: String, description: String? = nil, anyOf choices: [DynamicGenerationSchema]) {
        self.node = .anyOf(name: name, description: description, choices: choices.map(\.node))
    }

    public init(
        name: String,
        description: String? = nil,
        representNilExplicitlyInGeneratedContent explicitNil: Bool,
        properties: [Property]
    ) {
        self.init(name: name, description: description, properties: properties)
    }

    public init<Value>(type: Value.Type, guides: [GenerationGuide<Value>] = []) where Value: Generable {
        self.node = guides.reduce(SchemaCycleGuard.node(for: Value.self)) { $1.apply(to: $0) }
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

    /// A schema matching only JSON null.
    public static var null: DynamicGenerationSchema {
        DynamicGenerationSchema(node: .raw(.object([
            .init(key: "type", value: .string("null"))
        ])))
    }

    init(node: SchemaNode) {
        self.node = node
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
