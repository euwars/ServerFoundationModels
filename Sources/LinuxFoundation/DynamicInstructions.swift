// DynamicInstructions — SwiftUI-style declarative instructions (SDK 27).

import Foundation

public protocol DynamicInstructions {
    associatedtype Body: DynamicInstructions
    @DynamicInstructionsBuilder var body: Body { get }
}

extension Never: DynamicInstructions {
    public var body: Never { fatalError("unreachable") }
}

/// Internal resolution: leaf nodes provide texts directly; composite custom
/// types recurse through `body`.
protocol ResolvableDynamicInstructions {
    var resolvedInstructionTexts: [String] { get }
}

extension DynamicInstructions {
    var allInstructionTexts: [String] {
        if let resolvable = self as? ResolvableDynamicInstructions {
            return resolvable.resolvedInstructionTexts
        }
        return body.allInstructionTexts
    }
}

extension Never: ResolvableDynamicInstructions {
    var resolvedInstructionTexts: [String] { [] }
}

extension Instructions: DynamicInstructions, ResolvableDynamicInstructions {
    public var body: Never { fatalError("leaf DynamicInstructions") }
    public typealias Body = Never
    var resolvedInstructionTexts: [String] { text.isEmpty ? [] : [text] }
}

public struct EmptyDynamicInstructions: DynamicInstructions, Sendable, ResolvableDynamicInstructions {
    public init() {}
    public var body: Never { fatalError("leaf DynamicInstructions") }
    public typealias Body = Never
    var resolvedInstructionTexts: [String] { [] }
}

public struct TupleDynamicInstructions<each Content: DynamicInstructions>: DynamicInstructions, ResolvableDynamicInstructions {
    let content: (repeat each Content)

    public init(_ content: repeat each Content) {
        self.content = (repeat each content)
    }

    public var body: Never { fatalError("leaf DynamicInstructions") }
    public typealias Body = Never

    var resolvedInstructionTexts: [String] {
        var texts: [String] = []
        for element in repeat each content {
            texts.append(contentsOf: element.allInstructionTexts)
        }
        return texts
    }
}

public struct ConditionalDynamicInstructions<TrueContent: DynamicInstructions, FalseContent: DynamicInstructions>: DynamicInstructions, ResolvableDynamicInstructions {
    public enum Branch {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }
    let branch: Branch

    public init(_ branch: Branch) {
        self.branch = branch
    }

    public var body: Never { fatalError("leaf DynamicInstructions") }
    public typealias Body = Never

    var resolvedInstructionTexts: [String] {
        switch branch {
        case .trueContent(let content): return content.allInstructionTexts
        case .falseContent(let content): return content.allInstructionTexts
        }
    }
}

public struct AnyDynamicInstructions: DynamicInstructions, ResolvableDynamicInstructions {
    let wrapped: any DynamicInstructions

    public init(_ dynamicInstructions: any DynamicInstructions) {
        self.wrapped = dynamicInstructions
    }

    public init(erasing dynamicInstructions: some DynamicInstructions) {
        self.wrapped = dynamicInstructions
    }

    public var body: Never { fatalError("leaf DynamicInstructions") }
    public typealias Body = Never

    var resolvedInstructionTexts: [String] { wrapped.allInstructionTexts }
}

@resultBuilder
public struct DynamicInstructionsBuilder {
    // Leaf nodes declare `Body == Never`; their unreachable bodies pass through.
    public static func buildBlock(_ content: Never) -> Never {
        content
    }

    public static func buildBlock<each Content: DynamicInstructions>(
        _ content: repeat each Content
    ) -> TupleDynamicInstructions<repeat each Content> {
        TupleDynamicInstructions(repeat each content)
    }

    public static func buildExpression<Content: DynamicInstructions>(_ content: Content) -> Content {
        content
    }

    public static func buildExpression(_ text: String) -> Instructions {
        Instructions(text: text)
    }

    public static func buildOptional<Content: DynamicInstructions>(
        _ content: Content?
    ) -> ConditionalDynamicInstructions<Content, EmptyDynamicInstructions> {
        if let content {
            return ConditionalDynamicInstructions(.trueContent(content))
        }
        return ConditionalDynamicInstructions(.falseContent(EmptyDynamicInstructions()))
    }

    public static func buildEither<TrueContent, FalseContent>(
        first content: TrueContent
    ) -> ConditionalDynamicInstructions<TrueContent, FalseContent> {
        ConditionalDynamicInstructions(.trueContent(content))
    }

    public static func buildEither<TrueContent, FalseContent>(
        second content: FalseContent
    ) -> ConditionalDynamicInstructions<TrueContent, FalseContent> {
        ConditionalDynamicInstructions(.falseContent(content))
    }
}
