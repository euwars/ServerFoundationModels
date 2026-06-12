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
}
