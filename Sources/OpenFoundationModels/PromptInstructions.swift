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
    public static func buildBlock(_ components: any PromptRepresentable...) -> Prompt {
        Prompt(text: components.map { $0.promptRepresentation.text }.joined(separator: "\n"))
    }

    public static func buildOptional(_ component: Prompt?) -> Prompt {
        component ?? Prompt(text: "")
    }

    public static func buildEither(first component: Prompt) -> Prompt { component }
    public static func buildEither(second component: Prompt) -> Prompt { component }

    public static func buildArray(_ components: [Prompt]) -> Prompt {
        Prompt(text: components.map(\.text).joined(separator: "\n"))
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
    public static func buildBlock(_ components: any InstructionsRepresentable...) -> Instructions {
        Instructions(text: components.map { $0.instructionsRepresentation.text }.joined(separator: "\n"))
    }

    public static func buildOptional(_ component: Instructions?) -> Instructions {
        component ?? Instructions(text: "")
    }

    public static func buildEither(first component: Instructions) -> Instructions { component }
    public static func buildEither(second component: Instructions) -> Instructions { component }

    public static func buildArray(_ components: [Instructions]) -> Instructions {
        Instructions(text: components.map(\.text).joined(separator: "\n"))
    }
}
