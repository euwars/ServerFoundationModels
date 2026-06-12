// Prompt / Instructions value types and their result builders.
// Mirrors FoundationModels (SDK 27).

import Foundation

public struct Prompt: Sendable {
    let text: String

    init(text: String) {
        self.text = text
    }

    public init(_ representable: some PromptRepresentable) {
        self = representable.promptRepresentation
    }

    public init(@PromptBuilder _ content: () throws -> Prompt) rethrows {
        self = try content()
    }
}

extension Prompt: PromptRepresentable {
    public var promptRepresentation: Prompt { self }
}

@resultBuilder
public struct PromptBuilder {
    public static func buildBlock<each P>(_ components: repeat each P) -> Prompt where repeat each P: PromptRepresentable {
        var texts: [String] = []
        for component in repeat each components {
            texts.append(component.promptRepresentation.text)
        }
        // Empty components (e.g. a false `if` via buildOptional, or an empty
        // buildArray) contribute nothing rather than a blank line.
        return Prompt(text: texts.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    @_disfavoredOverload
    public static func buildExpression<P>(_ expression: P) -> P where P: PromptRepresentable {
        expression
    }

    public static func buildExpression(_ expression: Prompt) -> Prompt {
        expression
    }

    @available(*, unavailable, message: "Only `Prompt` and `PromptRepresentable` are supported.")
    @_disfavoredOverload
    public static func buildExpression<T>(_ expression: T) -> Prompt {
        fatalError()
    }

    public static func buildOptional(_ component: Prompt?) -> Prompt {
        component ?? Prompt(text: "")
    }

    public static func buildEither(first component: some PromptRepresentable) -> Prompt {
        component.promptRepresentation
    }

    public static func buildEither(second component: some PromptRepresentable) -> Prompt {
        component.promptRepresentation
    }

    public static func buildArray(_ prompts: [some PromptRepresentable]) -> Prompt {
        Prompt(text: prompts.map { $0.promptRepresentation.text }.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    public static func buildLimitedAvailability(_ prompt: some PromptRepresentable) -> Prompt {
        prompt.promptRepresentation
    }
}

public struct Instructions: Sendable {
    let text: String

    init(text: String) {
        self.text = text
    }

    public init(_ representable: some InstructionsRepresentable) {
        self = representable.instructionsRepresentation
    }

    public init(@InstructionsBuilder _ content: () throws -> Instructions) rethrows {
        self = try content()
    }
}

extension Instructions: InstructionsRepresentable {
    public var instructionsRepresentation: Instructions { self }
}

@resultBuilder
public struct InstructionsBuilder {
    public static func buildBlock<each I>(_ components: repeat each I) -> Instructions where repeat each I: InstructionsRepresentable {
        var texts: [String] = []
        for component in repeat each components {
            texts.append(component.instructionsRepresentation.text)
        }
        // Empty components (e.g. a false `if` via buildOptional, or an empty
        // buildArray) contribute nothing rather than a blank line.
        return Instructions(text: texts.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    @_disfavoredOverload
    public static func buildExpression<I>(_ expression: I) -> I where I: InstructionsRepresentable {
        expression
    }

    public static func buildExpression(_ expression: Instructions) -> Instructions {
        expression
    }

    @available(*, unavailable, message: "Only `Instructions` and `InstructionsRepresentable` are supported.")
    @_disfavoredOverload
    public static func buildExpression<T>(_ expression: T) -> Instructions {
        fatalError()
    }

    public static func buildOptional(_ instructions: Instructions?) -> Instructions {
        instructions ?? Instructions(text: "")
    }

    public static func buildEither(first component: some InstructionsRepresentable) -> Instructions {
        component.instructionsRepresentation
    }

    public static func buildEither(second component: some InstructionsRepresentable) -> Instructions {
        component.instructionsRepresentation
    }

    public static func buildArray(_ instructions: [some InstructionsRepresentable]) -> Instructions {
        Instructions(text: instructions.map { $0.instructionsRepresentation.text }.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    public static func buildLimitedAvailability(_ instructions: some InstructionsRepresentable) -> Instructions {
        instructions.instructionsRepresentation
    }
}
