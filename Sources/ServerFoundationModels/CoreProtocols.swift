// Content conversion protocol hierarchy and standard-type conformances.
// Mirrors FoundationModels (SDK 27): ConvertibleFromGeneratedContent,
// ConvertibleToGeneratedContent, Generable, PromptRepresentable,
// InstructionsRepresentable.

import Foundation

public protocol ConvertibleFromGeneratedContent: SendableMetatype {
    init(_ content: GeneratedContent) throws
}

public protocol PromptRepresentable {
    var promptRepresentation: Prompt { get }
}

public protocol InstructionsRepresentable {
    var instructionsRepresentation: Instructions { get }
}

public protocol ConvertibleToGeneratedContent: InstructionsRepresentable, PromptRepresentable {
    var generatedContent: GeneratedContent { get }
}

public protocol Generable: ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent {
    associatedtype PartiallyGenerated: ConvertibleFromGeneratedContent = Self
    static var generationSchema: GenerationSchema { get }
}

extension Generable {
    /// The partially generated view of a complete value.
    public func asPartiallyGenerated() -> Self.PartiallyGenerated {
        // A complete value always converts to its own partial representation.
        try! Self.PartiallyGenerated(generatedContent)
    }
}

extension ConvertibleToGeneratedContent {
    public var promptRepresentation: Prompt {
        Prompt(text: generatedContent.jsonString)
    }

    public var instructionsRepresentation: Instructions {
        Instructions(text: generatedContent.jsonString)
    }
}

// MARK: - String

extension String: Generable {
    public init(_ content: GeneratedContent) throws {
        guard case .string(let value) = content.node else {
            throw GeneratedContentError("expected a string, got \(content.node.serialized)")
        }
        self = value
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .string(description: nil, enumChoices: nil, pattern: nil))
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(node: .string(self))
    }

    public var promptRepresentation: Prompt { Prompt(text: self) }
    public var instructionsRepresentation: Instructions { Instructions(text: self) }
}

// MARK: - Int

extension Int: Generable {
    public init(_ content: GeneratedContent) throws {
        switch content.node {
        case .integer(let value):
            self = value
        // `Int(exactly:)` rejects non-integral, non-finite, and out-of-range
        // doubles instead of trapping on untrusted model output.
        case .number(let value):
            guard value == value.rounded(), let exact = Int(exactly: value.rounded()) else {
                throw GeneratedContentError("expected an integer, got \(content.node.serialized)")
            }
            self = exact
        default:
            throw GeneratedContentError("expected an integer, got \(content.node.serialized)")
        }
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .integer(description: nil, minimum: nil, maximum: nil))
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(node: .integer(self))
    }
}

// MARK: - Bool

extension Bool: Generable {
    public init(_ content: GeneratedContent) throws {
        guard case .bool(let value) = content.node else {
            throw GeneratedContentError("expected a boolean, got \(content.node.serialized)")
        }
        self = value
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .boolean(description: nil))
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(node: .bool(self))
    }
}

// MARK: - Double

extension Double: Generable {
    public init(_ content: GeneratedContent) throws {
        switch content.node {
        case .number(let value): self = value
        case .integer(let value): self = Double(value)
        default:
            throw GeneratedContentError("expected a number, got \(content.node.serialized)")
        }
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .number(description: nil, minimum: nil, maximum: nil))
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(node: .number(self))
    }
}

// MARK: - Float

extension Float: Generable {
    public init(_ content: GeneratedContent) throws {
        self = Float(try Double(content))
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .number(description: nil, minimum: nil, maximum: nil))
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(node: .number(Double(self)))
    }
}

// MARK: - Decimal

extension Decimal: Generable {
    public init(_ content: GeneratedContent) throws {
        let value = try Double(content)
        // `Decimal(Double)` traps on non-finite input (untrusted model output).
        guard value.isFinite else {
            throw GeneratedContentError("expected a finite number, got \(content.node.serialized)")
        }
        self = Decimal(value)
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .number(description: nil, minimum: nil, maximum: nil))
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(node: .number((self as NSDecimalNumber).doubleValue))
    }
}

// MARK: - Array

// MARK: - Never

// Uninhabited, but Generable so `@Guide` array guides type-check in attribute
// position via GenerationGuide<[Never]> — matching Apple's framework.
extension Never: Generable {
    public init(_ content: GeneratedContent) throws {
        throw GeneratedContentError("Never cannot be instantiated")
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .object(name: "Never", description: nil, properties: []))
    }

    public var generatedContent: GeneratedContent {
        switch self {}
    }
}

// MARK: - Optional

// Apple's Optional is deliberately NOT Generable and NOT
// ConvertibleFromGeneratedContent: optional decoding goes through
// `GeneratedContent.value(_: Value?.Type, forProperty:)`, and an extra
// conformance here would make `Property(name:type: String?.self)` ambiguous.
extension Optional: PromptRepresentable where Wrapped: ConvertibleToGeneratedContent {}
extension Optional: InstructionsRepresentable where Wrapped: ConvertibleToGeneratedContent {}

extension Optional: ConvertibleToGeneratedContent where Wrapped: ConvertibleToGeneratedContent {
    public var generatedContent: GeneratedContent {
        switch self {
        case .some(let wrapped): return wrapped.generatedContent
        case .none: return GeneratedContent(node: .null)
        }
    }
}

extension Optional where Wrapped: Generable {
    public typealias PartiallyGenerated = Wrapped.PartiallyGenerated
}

// MARK: - Array

extension Array: ConvertibleFromGeneratedContent where Element: ConvertibleFromGeneratedContent {
    public init(_ content: GeneratedContent) throws {
        guard case .array(let elements) = content.node else {
            throw GeneratedContentError("expected an array, got \(content.node.serialized)")
        }
        self = try elements.map { try Element(GeneratedContent(node: $0)) }
    }
}

extension Array: PromptRepresentable where Element: ConvertibleToGeneratedContent {}
extension Array: InstructionsRepresentable where Element: ConvertibleToGeneratedContent {}

extension Array: ConvertibleToGeneratedContent where Element: ConvertibleToGeneratedContent {
    public var generatedContent: GeneratedContent {
        GeneratedContent(node: .array(map { $0.generatedContent.node }))
    }
}

extension Array: Generable where Element: Generable {
    public typealias PartiallyGenerated = [Element.PartiallyGenerated]

    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .array(
            description: nil,
            item: SchemaCycleGuard.node(for: Element.self),
            minimumElements: nil,
            maximumElements: nil
        ))
    }
}
