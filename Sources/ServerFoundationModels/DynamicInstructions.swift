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
    var resolvedInstructionTools: [ErasedTool] { get }
}

extension ResolvableDynamicInstructions {
    var resolvedInstructionTools: [ErasedTool] { [] }
}

extension DynamicInstructions {
    var allInstructionTexts: [String] {
        if let resolvable = self as? ResolvableDynamicInstructions {
            return resolvable.resolvedInstructionTexts
        }
        return body.allInstructionTexts
    }

    var allInstructionTools: [ErasedTool] {
        if let resolvable = self as? ResolvableDynamicInstructions {
            return resolvable.resolvedInstructionTools
        }
        return body.allInstructionTools
    }
}

/// Tools declared inline in a DynamicInstructions body; registered with the
/// session for the requests the instructions are active.
struct ToolDynamicInstructions: DynamicInstructions, ResolvableDynamicInstructions {
    let tools: [ErasedTool]

    var body: Never { fatalError("leaf DynamicInstructions") }
    typealias Body = Never

    var resolvedInstructionTexts: [String] { [] }
    var resolvedInstructionTools: [ErasedTool] { tools }
}

extension Never: ResolvableDynamicInstructions {
    var resolvedInstructionTexts: [String] { [] }
}

extension Instructions: DynamicInstructions, ResolvableDynamicInstructions {
    // Resolution short-circuits at this leaf; the body is never walked.
    public var body: some DynamicInstructions { EmptyDynamicInstructions() }
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

    var resolvedInstructionTools: [ErasedTool] {
        var tools: [ErasedTool] = []
        for element in repeat each content {
            tools.append(contentsOf: element.allInstructionTools)
        }
        return tools
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

    var resolvedInstructionTools: [ErasedTool] {
        switch branch {
        case .trueContent(let content): return content.allInstructionTools
        case .falseContent(let content): return content.allInstructionTools
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
    var resolvedInstructionTools: [ErasedTool] { wrapped.allInstructionTools }
}

public struct _DynamicInstructionsForEach<Data, ID, Content>: DynamicInstructions, ResolvableDynamicInstructions
where Data: RandomAccessCollection, ID: Hashable, Content: DynamicInstructions {
    let data: Data
    let content: (Data.Element) -> Content

    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @DynamicInstructionsBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.content = content
    }

    public var body: Never { fatalError("leaf DynamicInstructions") }
    public typealias Body = Never

    var resolvedInstructionTexts: [String] {
        data.flatMap { content($0).allInstructionTexts }
    }

    var resolvedInstructionTools: [ErasedTool] {
        data.flatMap { content($0).allInstructionTools }
    }
}

extension _DynamicInstructionsForEach where ID == Data.Element.ID, Data.Element: Identifiable {
    public init(
        _ data: Data,
        @DynamicInstructionsBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.init(data, id: \.id, content: content)
    }
}

extension DynamicInstructions {
    public typealias ForEach = _DynamicInstructionsForEach
}

extension Optional: DynamicInstructions, ResolvableDynamicInstructions where Wrapped: DynamicInstructions {
    public var body: Never { fatalError("leaf DynamicInstructions") }
    public typealias Body = Never

    var resolvedInstructionTexts: [String] { self?.allInstructionTexts ?? [] }
    var resolvedInstructionTools: [ErasedTool] { self?.allInstructionTools ?? [] }
}

@resultBuilder
public struct DynamicInstructionsBuilder {
    // Leaf nodes declare `Body == Never`; `content` is uninhabited so the body is
    // unreachable. An empty body has no statement to flag as "will never be
    // executed" (unlike `content` or `switch content {}`, which warn on Linux).
    public static func buildBlock(_ content: Never) -> Never {}

    public static func buildBlock() -> EmptyDynamicInstructions {
        EmptyDynamicInstructions()
    }

    public static func buildBlock<T>(_ content: T) -> T where T: DynamicInstructions {
        content
    }

    public static func buildBlock<each Content: DynamicInstructions>(
        _ contents: repeat each Content
    ) -> TupleDynamicInstructions<repeat each Content> {
        TupleDynamicInstructions(repeat each contents)
    }

    public static func buildExpression<T>(_ expression: T) -> T where T: DynamicInstructions {
        expression
    }

    public static func buildExpression(_ text: String) -> Instructions {
        Instructions(text: text)
    }

    public static func buildExpression<T>(_ expression: T) -> some DynamicInstructions where T: Tool {
        ToolDynamicInstructions(tools: [ErasedTool(expression)])
    }

    public static func buildExpression(_ tools: [any Tool]) -> some DynamicInstructions {
        ToolDynamicInstructions(tools: tools.map { ErasedTool($0) })
    }

    public static func buildOptional<Content: DynamicInstructions>(
        _ content: Content?
    ) -> Content? {
        content
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
