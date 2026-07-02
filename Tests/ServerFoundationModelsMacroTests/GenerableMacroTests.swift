// Macro expansion tests for the @Generable / @Guide / @SessionPropertyEntry
// fixes: property-shape handling (let-with-initializer, multi-binding,
// inferred type, didSet), access-level mirroring, literal re-emission
// (raw strings, interpolation, enum raw values), regex-literal pattern
// guides, backticked identifiers, and module-qualified @Guide.

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
import ServerFoundationModelsMacros

final class GenerableMacroTests: XCTestCase {

    private let macros: [String: Macro.Type] = [
        "Generable": GenerableMacro.self,
        "Guide": GuideMacro.self,
        "SessionPropertyEntry": SessionPropertyEntryMacro.self,
    ]

    // MARK: 6a — let with initializer is a constant, not a generated property

    func testLetWithInitializerIsExcluded() {
        assertMacroExpansion(
            """
            @Generable
            public struct S {
                let kind: String = "fixed"
                var name: String
            }
            """,
            expandedSource: """
            public struct S {
                let kind: String = "fixed"
                var name: String

                public init(name: String) {
                        self.name = name
                }

                public init(_ generatedContent: GeneratedContent) throws {
                        self.name = try generatedContent.value(String.self, forProperty: "name")
                }

                public var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "name": self.name
                    ])
                }

                public static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "name", description: nil, type: String.self)
                        ]
                    )
                }

                public struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    public var id: GenerationID
                    public var name: String.PartiallyGenerated?

                    public init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.name = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "name") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: 6b — trailing annotation covers earlier bindings

    func testMultiBindingSharedAnnotation() {
        assertMacroExpansion(
            """
            @Generable
            struct Pair {
                var a, b: Int
            }
            """,
            expandedSource: """
            struct Pair {
                var a, b: Int

                init(a: Int, b: Int) {
                        self.a = a
                        self.b = b
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.a = try generatedContent.value(Int.self, forProperty: "a")
                        self.b = try generatedContent.value(Int.self, forProperty: "b")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "a": self.a,
                            "b": self.b
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "a", description: nil, type: Int.self),
                            GenerationSchema.Property(name: "b", description: nil, type: Int.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var a: Int.PartiallyGenerated?
                    var b: Int.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.a = try? generatedContent.value(Optional<Int.PartiallyGenerated>.self, forProperty: "a") ?? nil
                        self.b = try? generatedContent.value(Optional<Int.PartiallyGenerated>.self, forProperty: "b") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: 6c — inferred type produces a diagnostic

    func testInferredTypeEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                var title = "hi"
            }
            """,
            expandedSource: """
            struct S {
                var title = "hi"

                init(_ generatedContent: GeneratedContent) throws {
                        _ = generatedContent
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [:])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [

                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID


                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        _ = generatedContent
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Generable stored properties require an explicit type annotation",
                    line: 3,
                    column: 9
                )
            ],
            macros: macros
        )
    }

    // MARK: 6d — observer-only accessor blocks are stored properties

    func testDidSetPropertyIsStored() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                var count: Int {
                    didSet {
                        print(count)
                    }
                }
            }
            """,
            expandedSource: """
            struct S {
                var count: Int {
                    didSet {
                        print(count)
                    }
                }

                init(count: Int) {
                        self.count = count
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.count = try generatedContent.value(Int.self, forProperty: "count")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "count": self.count
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "count", description: nil, type: Int.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var count: Int.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.count = try? generatedContent.value(Optional<Int.PartiallyGenerated>.self, forProperty: "count") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: 7 — access level mirrors the attached type

    func testInternalTypeGetsNoAccessModifier() {
        assertMacroExpansion(
            """
            @Generable
            struct Inner {
                var v: Int
            }
            """,
            expandedSource: """
            struct Inner {
                var v: Int

                init(v: Int) {
                        self.v = v
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.v = try generatedContent.value(Int.self, forProperty: "v")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "v": self.v
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "v", description: nil, type: Int.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var v: Int.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.v = try? generatedContent.value(Optional<Int.PartiallyGenerated>.self, forProperty: "v") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: 8 — literal re-emission

    func testRawStringDescriptionSurvives() {
        assertMacroExpansion(
            ##"""
            @Generable
            struct S {
                @Guide(description: #"a "quoted" \d value"#)
                var s: String
            }
            """##,
            expandedSource: ##"""
            struct S {
                var s: String

                init(s: String) {
                        self.s = s
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.s = try generatedContent.value(String.self, forProperty: "s")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "s": self.s
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "s", description: #"a "quoted" \d value"#, type: String.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var s: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.s = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "s") ?? nil
                    }
                }
            }
            """##,
            macros: macros
        )
    }

    func testInterpolatedDescriptionSurvives() {
        assertMacroExpansion(
            #"""
            @Generable
            struct S {
                @Guide(description: "at most \(limit) items")
                var s: String
            }
            """#,
            expandedSource: #"""
            struct S {
                var s: String

                init(s: String) {
                        self.s = s
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.s = try generatedContent.value(String.self, forProperty: "s")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "s": self.s
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "s", description: "at most \(limit) items", type: String.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var s: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.s = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "s") ?? nil
                    }
                }
            }
            """#,
            macros: macros
        )
    }

    func testRegexLiteralGuideBecomesPattern() {
        assertMacroExpansion(
            #"""
            @Generable
            struct S {
                @Guide(description: "a year", /\d{4}/)
                var year: String
            }
            """#,
            expandedSource: #"""
            struct S {
                var year: String

                init(year: String) {
                        self.year = year
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.year = try generatedContent.value(String.self, forProperty: "year")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "year": self.year
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "year", description: "a year", type: String.self, guides: [.pattern("\\d{4}")])
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var year: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.year = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "year") ?? nil
                    }
                }
            }
            """#,
            macros: macros
        )
    }

    func testEnumRawValuesSplicedVerbatim() {
        assertMacroExpansion(
            ##"""
            @Generable
            public enum Kind {
                case plain = "plain text"
                case weird = #"raw "quoted""#
                case bare
            }
            """##,
            expandedSource: ##"""
            public enum Kind {
                case plain = "plain text"
                case weird = #"raw "quoted""#
                case bare

                public init(_ generatedContent: GeneratedContent) throws {
                    let rawValue = try generatedContent.value(String.self)
                    switch rawValue {
                        case "plain text":
                        self = .plain
                        case #"raw "quoted""#:
                        self = .weird
                        case "bare":
                        self = .bare
                    default:
                        throw GeneratedContentError("'\(rawValue)' is not a valid Kind")
                    }
                }

                public var generatedContent: GeneratedContent {
                    let rawValue: String
                    switch self {
                        case .plain:
                        rawValue = "plain text"
                        case .weird:
                        rawValue = #"raw "quoted""#
                        case .bare:
                        rawValue = "bare"
                    }
                    return rawValue.generatedContent
                }

                public static var generationSchema: GenerationSchema {
                    GenerationSchema(type: Self.self, description: nil, anyOf: ["plain text", #"raw "quoted""#, "bare"])
                }
            }
            """##,
            macros: macros
        )
    }

    // MARK: 9 — backticked identifiers

    func testBacktickedIdentifierStrippedOnWire() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                var `class`: String
            }
            """,
            expandedSource: """
            struct S {
                var `class`: String

                init(`class`: String) {
                        self.`class` = `class`
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.`class` = try generatedContent.value(String.self, forProperty: "class")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "class": self.`class`
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "class", description: nil, type: String.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var `class`: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.`class` = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "class") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: 10 — module-qualified @Guide

    func testModuleQualifiedGuideIsRecognized() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                @ServerFoundationModels.Guide(description: "qualified")
                var s: String
            }
            """,
            expandedSource: """
            struct S {
                @ServerFoundationModels.Guide(description: "qualified")
                var s: String

                init(s: String) {
                        self.s = s
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.s = try generatedContent.value(String.self, forProperty: "s")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "s": self.s
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "s", description: "qualified", type: String.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var s: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.s = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "s") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: 7 — @SessionPropertyEntry access mirroring

    func testSessionPropertyEntryMirrorsAccess() {
        assertMacroExpansion(
            """
            extension SessionPropertyValues {
                @SessionPropertyEntry
                var maxTokens: Int = 4
            }
            """,
            expandedSource: """
            extension SessionPropertyValues {
                var maxTokens: Int {
                    get {
                        self[__Key_maxTokens.self]
                    }
                    set {
                        self[__Key_maxTokens.self] = newValue
                    }
                }

                struct __Key_maxTokens: SessionPropertyKey {
                    static var defaultValue: Int {
                        4
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testSessionPropertyEntryKeepsPublic() {
        assertMacroExpansion(
            """
            extension SessionPropertyValues {
                @SessionPropertyEntry
                public var maxTokens: Int = 4
            }
            """,
            expandedSource: """
            extension SessionPropertyValues {
                public var maxTokens: Int {
                    get {
                        self[__Key_maxTokens.self]
                    }
                    set {
                        self[__Key_maxTokens.self] = newValue
                    }
                }

                public struct __Key_maxTokens: SessionPropertyKey {
                    public static var defaultValue: Int {
                        4
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: — optional properties

    func testOptionalSugarSpelling() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                var name: String?
            }
            """,
            expandedSource: """
            struct S {
                var name: String?

                init(name: String? = nil) {
                        self.name = name
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.name = try generatedContent.value(String?.self, forProperty: "name")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "name": self.name
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "name", description: nil, type: String?.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var name: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.name = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "name") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testOptionalGenericSpelling() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                var name: Optional<String>
            }
            """,
            expandedSource: """
            struct S {
                var name: Optional<String>

                init(name: Optional<String> = nil) {
                        self.name = name
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.name = try generatedContent.value(String?.self, forProperty: "name")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "name": self.name
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "name", description: nil, type: String?.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var name: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.name = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "name") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: — nested array partial translation

    func testArrayOfNestedGenerableType() {
        assertMacroExpansion(
            """
            @Generable
            struct Outer {
                var items: [Inner]
            }
            """,
            expandedSource: """
            struct Outer {
                var items: [Inner]

                init(items: [Inner]) {
                        self.items = items
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.items = try generatedContent.value([Inner].self, forProperty: "items")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "items": self.items
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "items", description: nil, type: [Inner].self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var items: [Inner.PartiallyGenerated]?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.items = try? generatedContent.value(Optional<[Inner.PartiallyGenerated]>.self, forProperty: "items") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: — type-level description

    func testTypeLevelDescription() {
        assertMacroExpansion(
            """
            @Generable(description: "A person")
            struct Person {
                var name: String
            }
            """,
            expandedSource: """
            struct Person {
                var name: String

                init(name: String) {
                        self.name = name
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.name = try generatedContent.value(String.self, forProperty: "name")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "name": self.name
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: "A person",
                        properties: [
                            GenerationSchema.Property(name: "name", description: nil, type: String.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var name: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.name = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "name") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: — empty struct

    func testEmptyStruct() {
        assertMacroExpansion(
            """
            @Generable
            struct Empty {}
            """,
            expandedSource: """
            struct Empty {

                init(_ generatedContent: GeneratedContent) throws {
                        _ = generatedContent
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [:])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [

                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID


                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        _ = generatedContent
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: — non-regex guide pass-through

    func testRangeAndCountGuidesPassThrough() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                @Guide(description: "a score", .range(0...100), .count(1...5))
                var scores: [Int]
            }
            """,
            expandedSource: """
            struct S {
                var scores: [Int]

                init(scores: [Int]) {
                        self.scores = scores
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.scores = try generatedContent.value([Int].self, forProperty: "scores")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "scores": self.scores
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "scores", description: "a score", type: [Int].self, guides: [.range(0 ... 100), .count(1 ... 5)])
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var scores: [Int.PartiallyGenerated]?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.scores = try? generatedContent.value(Optional<[Int.PartiallyGenerated]>.self, forProperty: "scores") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: — .pattern(/regex/) rewrite

    func testPatternCallWithRegexLiteral() {
        assertMacroExpansion(
            #"""
            @Generable
            struct S {
                @Guide(description: "digits", .pattern(/\d+/))
                var code: String
            }
            """#,
            expandedSource: #"""
            struct S {
                var code: String

                init(code: String) {
                        self.code = code
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.code = try generatedContent.value(String.self, forProperty: "code")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "code": self.code
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "code", description: "digits", type: String.self, guides: [.pattern("\\d+")])
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var code: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.code = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "code") ?? nil
                    }
                }
            }
            """#,
            macros: macros
        )
    }

    // MARK: — let without initializer

    func testLetWithoutInitializerIsIncluded() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                let name: String
                var age: Int
            }
            """,
            expandedSource: """
            struct S {
                let name: String
                var age: Int

                init(name: String, age: Int) {
                        self.name = name
                        self.age = age
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.name = try generatedContent.value(String.self, forProperty: "name")
                        self.age = try generatedContent.value(Int.self, forProperty: "age")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "name": self.name,
                            "age": self.age
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "name", description: nil, type: String.self),
                            GenerationSchema.Property(name: "age", description: nil, type: Int.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var name: String.PartiallyGenerated?
                    var age: Int.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.name = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "name") ?? nil
                        self.age = try? generatedContent.value(Optional<Int.PartiallyGenerated>.self, forProperty: "age") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: — package access level

    func testPackageAccessLevel() {
        assertMacroExpansion(
            """
            @Generable
            package struct S {
                var v: Int
            }
            """,
            expandedSource: """
            package struct S {
                var v: Int

                package init(v: Int) {
                        self.v = v
                }

                package init(_ generatedContent: GeneratedContent) throws {
                        self.v = try generatedContent.value(Int.self, forProperty: "v")
                }

                package var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "v": self.v
                    ])
                }

                package static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "v", description: nil, type: Int.self)
                        ]
                    )
                }

                package struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    package var id: GenerationID
                    package var v: Int.PartiallyGenerated?

                    package init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.v = try? generatedContent.value(Optional<Int.PartiallyGenerated>.self, forProperty: "v") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: — Int raw-value enum warning

    func testIntRawValueEnumEmitsWarning() {
        assertMacroExpansion(
            """
            @Generable
            enum Priority: Int {
                case low = 1
                case high = 2
            }
            """,
            expandedSource: """
            enum Priority: Int {
                case low = 1
                case high = 2

                init(_ generatedContent: GeneratedContent) throws {
                    let rawValue = try generatedContent.value(String.self)
                    switch rawValue {
                        case "low":
                        self = .low
                        case "high":
                        self = .high
                    default:
                        throw GeneratedContentError("'\\(rawValue)' is not a valid Priority")
                    }
                }

                var generatedContent: GeneratedContent {
                    let rawValue: String
                    switch self {
                        case .low:
                        rawValue = "low"
                        case .high:
                        rawValue = "high"
                    }
                    return rawValue.generatedContent
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(type: Self.self, description: nil, anyOf: ["low", "high"])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Generable uses enum case names on the wire; non-String raw values are ignored",
                    line: 2,
                    column: 6,
                    severity: .warning
                )
            ],
            macros: macros
        )
    }

    // MARK: — memberwise init default values

    func testMemberwiseInitDefaultValues() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                var x: Int = 5
                var y: String?
            }
            """,
            expandedSource: """
            struct S {
                var x: Int = 5
                var y: String?

                init(x: Int = 5, y: String? = nil) {
                        self.x = x
                        self.y = y
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.x = try generatedContent.value(Int.self, forProperty: "x")
                        self.y = try generatedContent.value(String?.self, forProperty: "y")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "x": self.x,
                            "y": self.y
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "x", description: nil, type: Int.self),
                            GenerationSchema.Property(name: "y", description: nil, type: String?.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var x: Int.PartiallyGenerated?
                    var y: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.x = try? generatedContent.value(Optional<Int.PartiallyGenerated>.self, forProperty: "x") ?? nil
                        self.y = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "y") ?? nil
                    }
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: — diagnostics

    func testClassAttachmentEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @Generable
            class C {
                var x: Int
            }
            """,
            expandedSource: """
            class C {
                var x: Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Generable currently supports structs and enums",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testActorAttachmentEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @Generable
            actor A {
                var x: Int
            }
            """,
            expandedSource: """
            actor A {
                var x: Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Generable currently supports structs and enums",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testEnumAssociatedValuesEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @Generable
            enum E {
                case foo(Int)
            }
            """,
            expandedSource: """
            enum E {
                case foo(Int)
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Generable enums with associated values are not supported yet",
                    line: 3,
                    column: 10
                )
            ],
            macros: macros
        )
    }

    func testTuplePatternEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                var (a, b): (Int, Int)
            }
            """,
            expandedSource: """
            struct S {
                var (a, b): (Int, Int)

                init(_ generatedContent: GeneratedContent) throws {
                        _ = generatedContent
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [:])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [

                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID


                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        _ = generatedContent
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Generable does not support tuple-pattern properties",
                    line: 3,
                    column: 9
                )
            ],
            macros: macros
        )
    }

    func testImplicitlyUnwrappedOptionalEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                var s: String!
            }
            """,
            expandedSource: """
            struct S {
                var s: String!

                init(_ generatedContent: GeneratedContent) throws {
                        _ = generatedContent
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [:])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [

                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID


                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        _ = generatedContent
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Generable does not support implicitly unwrapped optional properties",
                    line: 3,
                    column: 12
                )
            ],
            macros: macros
        )
    }

    func testLazyPropertyEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                lazy var x: Int = 0
            }
            """,
            expandedSource: """
            struct S {
                lazy var x: Int = 0

                init(_ generatedContent: GeneratedContent) throws {
                        _ = generatedContent
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [:])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [

                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID


                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        _ = generatedContent
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Generable does not support lazy stored properties",
                    line: 3,
                    column: 5
                )
            ],
            macros: macros
        )
    }

    func testDuplicateGuideEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @Generable
            struct S {
                @Guide(description: "first")
                @Guide(description: "second")
                var s: String
            }
            """,
            expandedSource: """
            struct S {
                var s: String

                init(s: String) {
                        self.s = s
                }

                init(_ generatedContent: GeneratedContent) throws {
                        self.s = try generatedContent.value(String.self, forProperty: "s")
                }

                var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                            "s": self.s
                    ])
                }

                static var generationSchema: GenerationSchema {
                    GenerationSchema(
                        type: Self.self,
                        description: nil,
                        properties: [
                            GenerationSchema.Property(name: "s", description: "first", type: String.self)
                        ]
                    )
                }

                struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                    var id: GenerationID
                    var s: String.PartiallyGenerated?

                    init(_ generatedContent: GeneratedContent) throws {
                        self.id = generatedContent.id ?? GenerationID()
                        self.s = try? generatedContent.value(Optional<String.PartiallyGenerated>.self, forProperty: "s") ?? nil
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Generable supports only one @Guide attribute per property",
                    line: 4,
                    column: 5
                )
            ],
            macros: macros
        )
    }

    func testSessionPropertyEntryMultipleBindingsEmitsDiagnostic() {
        assertMacroExpansion(
            """
            extension SessionPropertyValues {
                @SessionPropertyEntry
                var a: Int = 1, b: Int = 2
            }
            """,
            expandedSource: """
            extension SessionPropertyValues {
                var a: Int = 1, b: Int = 2
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@SessionPropertyEntry does not support multiple bindings in one declaration",
                    line: 3,
                    column: 5
                )
            ],
            macros: macros
        )
    }

    func testSessionPropertyEntryBacktickedName() {
        assertMacroExpansion(
            """
            extension SessionPropertyValues {
                @SessionPropertyEntry
                var `class`: Int = 1
            }
            """,
            expandedSource: """
            extension SessionPropertyValues {
                var `class`: Int {
                    get {
                        self[__Key_class.self]
                    }
                    set {
                        self[__Key_class.self] = newValue
                    }
                }

                struct __Key_class: SessionPropertyKey {
                    static var defaultValue: Int {
                        1
                    }
                }
            }
            """,
            macros: macros
        )
    }
}
