// @Generable — generates the full Generable conformance for a struct:
// memberwise init, init(_: GeneratedContent), generatedContent, and
// generationSchema (folding in @Guide descriptions and guides).
//
// Design note: nested Generable types are embedded INLINE in the generated
// schema (each property's schema comes from `PropertyType.generationSchema`,
// recursively). There are no $ref/$defs, so arbitrarily deep nesting —
// including arrays of structs containing arrays of structs — renders as a
// single self-contained JSON Schema. This deliberately avoids the broken
// reference-resolution paths seen in other FoundationModels clones.

import SwiftSyntax
import SwiftSyntaxMacros

public struct GenerableMacro: MemberMacro, ExtensionMacro {

    // MARK: Property model

    private struct StoredProperty {
        var name: String
        var type: String
        var isOptional: Bool
        var guideDescription: String?
        var guideExpressions: [String]

        /// The non-optional base type, for schema/decoding generics.
        var baseType: String {
            if isOptional {
                if type.hasSuffix("?") { return String(type.dropLast()) }
                if type.hasPrefix("Optional<"), type.hasSuffix(">") {
                    return String(type.dropFirst("Optional<".count).dropLast())
                }
            }
            return type
        }
    }

    private struct MacroError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Member expansion

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if let enumDeclaration = declaration.as(EnumDeclSyntax.self) {
            return try enumExpansion(of: node, enum: enumDeclaration)
        }
        guard declaration.is(StructDeclSyntax.self) else {
            throw MacroError(description: "@Generable currently supports structs and enums")
        }

        let typeDescription = stringLiteralArgument(named: "description", in: node)
        let properties = try storedProperties(of: declaration)

        var members: [DeclSyntax] = []

        // Memberwise initializer.
        if !properties.isEmpty {
            let parameters = properties
                .map { "\($0.name): \($0.type)" }
                .joined(separator: ", ")
            let assignments = properties
                .map { "        self.\($0.name) = \($0.name)" }
                .joined(separator: "\n")
            members.append(
                """
                public init(\(raw: parameters)) {
                \(raw: assignments)
                }
                """
            )
        }

        // init(_: GeneratedContent)
        let decodingLines = properties.map { property -> String in
            if property.isOptional {
                return "        self.\(property.name) = try generatedContent.value(\(property.baseType)?.self, forProperty: \"\(property.name)\")"
            }
            return "        self.\(property.name) = try generatedContent.value(\(property.baseType).self, forProperty: \"\(property.name)\")"
        }.joined(separator: "\n")
        members.append(
            """
            public init(_ generatedContent: GeneratedContent) throws {
            \(raw: decodingLines.isEmpty ? "        _ = generatedContent" : decodingLines)
            }
            """
        )

        // generatedContent
        let encodingPairs = properties
            .map { "            \"\($0.name)\": self.\($0.name)" }
            .joined(separator: ",\n")
        if properties.isEmpty {
            members.append(
                """
                public var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [:])
                }
                """
            )
        } else {
            members.append(
                """
                public var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                \(raw: encodingPairs)
                    ])
                }
                """
            )
        }

        // generationSchema
        let schemaProperties = properties.map { property -> String in
            let description = property.guideDescription.map { "\"\($0)\"" } ?? "nil"
            let guides = property.guideExpressions.isEmpty
                ? ""
                : ", guides: [\(property.guideExpressions.joined(separator: ", "))]"
            let typeReference = property.isOptional ? "\(property.baseType)?.self" : "\(property.baseType).self"
            return "            GenerationSchema.Property(name: \"\(property.name)\", description: \(description), type: \(typeReference)\(guides))"
        }.joined(separator: ",\n")
        let schemaDescription = typeDescription.map { "\"\($0)\"" } ?? "nil"
        members.append(
            """
            public static var generationSchema: GenerationSchema {
                GenerationSchema(
                    type: Self.self,
                    description: \(raw: schemaDescription),
                    properties: [
            \(raw: schemaProperties)
                    ]
                )
            }
            """
        )

        return members
    }

    // MARK: Enum expansion

    /// Simple enums generate as constrained strings: each case is represented
    /// by its String raw value when present, else its case name.
    private static func enumExpansion(
        of node: AttributeSyntax,
        enum declaration: EnumDeclSyntax
    ) throws -> [DeclSyntax] {
        var caseNames: [String] = []
        var caseValues: [String] = []
        for member in declaration.memberBlock.members {
            guard let enumCase = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in enumCase.elements {
                guard element.parameterClause == nil else {
                    throw MacroError(description: "@Generable enums with associated values are not supported yet")
                }
                let name = element.name.text
                caseNames.append(name)
                if let raw = element.rawValue?.value.as(StringLiteralExprSyntax.self) {
                    caseValues.append(raw.segments.compactMap {
                        $0.as(StringSegmentSyntax.self)?.content.text
                    }.joined())
                } else {
                    caseValues.append(name)
                }
            }
        }
        guard !caseNames.isEmpty else {
            throw MacroError(description: "@Generable enums must declare at least one case")
        }

        let typeDescription = stringLiteralArgument(named: "description", in: node)
        let descriptionArgument = typeDescription.map { "\"\($0)\"" } ?? "nil"
        let decodeCases = zip(caseNames, caseValues)
            .map { "        case \"\(String($1))\": self = .\(String($0))" }
            .joined(separator: "\n")
        let encodeCases = zip(caseNames, caseValues)
            .map { "        case .\(String($0)): rawValue = \"\(String($1))\"" }
            .joined(separator: "\n")
        let choices = caseValues.map { "\"\(String($0))\"" }.joined(separator: ", ")

        return [
            """
            public init(_ generatedContent: GeneratedContent) throws {
                let rawValue = try generatedContent.value(String.self)
                switch rawValue {
            \(raw: decodeCases)
                default:
                    throw GeneratedContentError("'\\(rawValue)' is not a valid \(raw: declaration.name.text)")
                }
            }
            """,
            """
            public var generatedContent: GeneratedContent {
                let rawValue: String
                switch self {
            \(raw: encodeCases)
                }
                return rawValue.generatedContent
            }
            """,
            """
            public static var generationSchema: GenerationSchema {
                GenerationSchema(type: Self.self, description: \(raw: descriptionArgument), anyOf: [\(raw: choices)])
            }
            """,
        ]
    }

    // MARK: Extension expansion

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty else { return [] }
        let declaration: DeclSyntax = "extension \(type.trimmed): Generable {}"
        return [declaration.cast(ExtensionDeclSyntax.self)]
    }

    // MARK: Syntax mining

    private static func storedProperties(of declaration: some DeclGroupSyntax) throws -> [StoredProperty] {
        var properties: [StoredProperty] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard !variable.modifiers.contains(where: { $0.name.text == "static" }) else { continue }

            var guideDescription: String?
            var guideExpressions: [String] = []
            if let guide = attribute(named: "Guide", on: variable),
                let arguments = guide.arguments?.as(LabeledExprListSyntax.self) {
                for argument in arguments {
                    if argument.label?.text == "description" {
                        guideDescription = stringLiteralValue(of: argument.expression)
                    } else {
                        guideExpressions.append(argument.expression.trimmedDescription)
                    }
                }
            }

            for binding in variable.bindings {
                guard binding.accessorBlock == nil,
                    let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                    let typeAnnotation = binding.typeAnnotation
                else { continue }

                let type = typeAnnotation.type.trimmedDescription
                let isOptional = typeAnnotation.type.is(OptionalTypeSyntax.self)
                    || (type.hasPrefix("Optional<") && type.hasSuffix(">"))
                properties.append(StoredProperty(
                    name: pattern.identifier.text,
                    type: type,
                    isOptional: isOptional,
                    guideDescription: guideDescription,
                    guideExpressions: guideExpressions
                ))
            }
        }
        return properties
    }

    private static func attribute(named name: String, on variable: VariableDeclSyntax) -> AttributeSyntax? {
        for attribute in variable.attributes {
            if let attribute = attribute.as(AttributeSyntax.self),
                attribute.attributeName.trimmedDescription == name {
                return attribute
            }
        }
        return nil
    }

    private static func stringLiteralArgument(named name: String, in node: AttributeSyntax) -> String? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for argument in arguments where argument.label?.text == name {
            return stringLiteralValue(of: argument.expression)
        }
        return nil
    }

    private static func stringLiteralValue(of expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
        return literal.segments.compactMap { segment in
            segment.as(StringSegmentSyntax.self)?.content.text
        }.joined()
    }
}
