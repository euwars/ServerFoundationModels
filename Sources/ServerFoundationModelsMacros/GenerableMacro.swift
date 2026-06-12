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

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

public struct GenerableMacro: MemberMacro, ExtensionMacro {

    // MARK: Property model

    private struct StoredProperty {
        /// The Swift identifier, kept verbatim (including backticks for
        /// escaped keywords) for code references like `self.\(name)`.
        var name: String
        /// The wire/schema key: `name` with backticks stripped.
        var wireName: String
        var type: String
        var isOptional: Bool
        /// The original `@Guide(description:)` expression source, spliced
        /// verbatim into generated code (preserves raw strings, multiline
        /// literals, and interpolation).
        var guideDescriptionSource: String?
        var guideExpressions: [String]

        /// The streaming-partial counterpart of the base type, with array
        /// sugar translated structurally ([X] -> [X.PartiallyGenerated]) to
        /// avoid member-type lookup on sugared array types.
        var partialType: String {
            func translate(_ type: String) -> String {
                let trimmed = type.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    let inner = String(trimmed.dropFirst().dropLast())
                    // Dictionary sugar is not generable; only arrays appear here.
                    return "[\(translate(inner))]"
                }
                return "\(trimmed).PartiallyGenerated"
            }
            return translate(baseType)
        }

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

    private struct GenerableDiagnostic: DiagnosticMessage {
        let message: String
        let diagnosticID: MessageID
        let severity: DiagnosticSeverity

        init(_ message: String, id: String, severity: DiagnosticSeverity = .error) {
            self.message = message
            self.diagnosticID = MessageID(domain: "ServerFoundationModelsMacros", id: id)
            self.severity = severity
        }
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

        // Generated members mirror the attached type's access level: `public`
        // members on an internal type would not compile (public initializer
        // with internal parameter types).
        let access = accessModifier(in: declaration.modifiers)
        let typeDescription = descriptionArgumentSource(in: node)
        let properties = storedProperties(of: declaration, in: context)

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
                \(raw: access)init(\(raw: parameters)) {
                \(raw: assignments)
                }
                """
            )
        }

        // init(_: GeneratedContent)
        let decodingLines = properties.map { property -> String in
            if property.isOptional {
                return "        self.\(property.name) = try generatedContent.value(\(property.baseType)?.self, forProperty: \"\(property.wireName)\")"
            }
            return "        self.\(property.name) = try generatedContent.value(\(property.baseType).self, forProperty: \"\(property.wireName)\")"
        }.joined(separator: "\n")
        members.append(
            """
            \(raw: access)init(_ generatedContent: GeneratedContent) throws {
            \(raw: decodingLines.isEmpty ? "        _ = generatedContent" : decodingLines)
            }
            """
        )

        // generatedContent
        let encodingPairs = properties
            .map { "            \"\($0.wireName)\": self.\($0.name)" }
            .joined(separator: ",\n")
        if properties.isEmpty {
            members.append(
                """
                \(raw: access)var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [:])
                }
                """
            )
        } else {
            members.append(
                """
                \(raw: access)var generatedContent: GeneratedContent {
                    GeneratedContent(properties: [
                \(raw: encodingPairs)
                    ])
                }
                """
            )
        }

        // generationSchema
        let schemaProperties = properties.map { property -> String in
            let description = property.guideDescriptionSource ?? "nil"
            let guides = property.guideExpressions.isEmpty
                ? ""
                : ", guides: [\(property.guideExpressions.joined(separator: ", "))]"
            let typeReference = property.isOptional ? "\(property.baseType)?.self" : "\(property.baseType).self"
            return "            GenerationSchema.Property(name: \"\(property.wireName)\", description: \(description), type: \(typeReference)\(guides))"
        }.joined(separator: ",\n")
        let schemaDescription = typeDescription ?? "nil"
        members.append(
            """
            \(raw: access)static var generationSchema: GenerationSchema {
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

        // PartiallyGenerated — the streaming view: every property optional,
        // decoded leniently from partial content.
        let partialFields = properties
            .map { "    \(access)var \($0.name): \($0.partialType)?" }
            .joined(separator: "\n")
        let partialDecoding = properties
            .map { "        self.\($0.name) = try? generatedContent.value(Optional<\($0.partialType)>.self, forProperty: \"\($0.wireName)\") ?? nil" }
            .joined(separator: "\n")
        members.append(
            """
            \(raw: access)struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
                \(raw: access)var id: GenerationID
            \(raw: partialFields)

                \(raw: access)init(_ generatedContent: GeneratedContent) throws {
                    self.id = generatedContent.id ?? GenerationID()
            \(raw: partialDecoding.isEmpty ? "        _ = generatedContent" : partialDecoding)
                }
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
        let access = accessModifier(in: declaration.modifiers)

        var caseNames: [String] = []
        // Swift expression source for each case's wire value: the original
        // raw-value literal verbatim (preserving raw/multiline string forms),
        // else the quoted case name.
        var caseValueSources: [String] = []
        for member in declaration.memberBlock.members {
            guard let enumCase = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in enumCase.elements {
                guard element.parameterClause == nil else {
                    throw MacroError(description: "@Generable enums with associated values are not supported yet")
                }
                let name = element.name.text
                caseNames.append(name)
                if let raw = element.rawValue?.value, raw.is(StringLiteralExprSyntax.self) {
                    caseValueSources.append(raw.trimmedDescription)
                } else {
                    caseValueSources.append("\"\(stripBackticks(name))\"")
                }
            }
        }
        guard !caseNames.isEmpty else {
            throw MacroError(description: "@Generable enums must declare at least one case")
        }

        let typeDescription = descriptionArgumentSource(in: node)
        let descriptionArgument = typeDescription ?? "nil"
        let decodeCases = zip(caseNames, caseValueSources)
            .map { "        case \($1): self = .\($0)" }
            .joined(separator: "\n")
        let encodeCases = zip(caseNames, caseValueSources)
            .map { "        case .\($0): rawValue = \($1)" }
            .joined(separator: "\n")
        let choices = caseValueSources.joined(separator: ", ")

        return [
            """
            \(raw: access)init(_ generatedContent: GeneratedContent) throws {
                let rawValue = try generatedContent.value(String.self)
                switch rawValue {
            \(raw: decodeCases)
                default:
                    throw GeneratedContentError("'\\(rawValue)' is not a valid \(raw: declaration.name.text)")
                }
            }
            """,
            """
            \(raw: access)var generatedContent: GeneratedContent {
                let rawValue: String
                switch self {
            \(raw: encodeCases)
                }
                return rawValue.generatedContent
            }
            """,
            """
            \(raw: access)static var generationSchema: GenerationSchema {
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

    private static func storedProperties(
        of declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> [StoredProperty] {
        var properties: [StoredProperty] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard !variable.modifiers.contains(where: { $0.name.text == "static" }) else { continue }

            var guideDescriptionSource: String?
            var guideExpressions: [String] = []
            if let guide = attribute(named: "Guide", on: variable),
                let arguments = guide.arguments?.as(LabeledExprListSyntax.self) {
                for argument in arguments {
                    if argument.label?.text == "description" {
                        // Splice the original expression verbatim so raw
                        // strings, multiline literals, and interpolation all
                        // survive the expansion.
                        guideDescriptionSource = argument.expression.trimmedDescription
                    } else {
                        guideExpressions.append(guideExpressionSource(argument.expression))
                    }
                }
            }

            let isConstant = variable.bindingSpecifier.text == "let"

            // A trailing type annotation applies to every preceding
            // annotation-less binding (`var a, b: Int` declares two Ints),
            // so resolve types in reverse. An initialized binding takes its
            // type from the initializer, and the annotation does not reach
            // across it.
            var resolved: [(binding: PatternBindingSyntax, type: TypeSyntax?)] = []
            var carriedType: TypeSyntax?
            for binding in variable.bindings.reversed() {
                if let annotation = binding.typeAnnotation {
                    carriedType = annotation.type
                    resolved.append((binding, annotation.type))
                } else if binding.initializer != nil {
                    resolved.append((binding, nil))
                    carriedType = nil
                } else {
                    resolved.append((binding, carriedType))
                }
            }

            for (binding, resolvedType) in resolved.reversed() {
                // Computed properties are skipped; accessor blocks made up
                // solely of observers (willSet/didSet) are stored properties.
                if let accessorBlock = binding.accessorBlock,
                    !isStoredAccessorBlock(accessorBlock) {
                    continue
                }
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }

                // `let x = ...` is a constant: it cannot be assigned in the
                // generated initializers, so it does not participate.
                if isConstant && binding.initializer != nil { continue }

                guard let resolvedType else {
                    if binding.initializer != nil {
                        context.diagnose(Diagnostic(
                            node: Syntax(binding),
                            message: GenerableDiagnostic(
                                "@Generable stored properties require an explicit type annotation",
                                id: "missingTypeAnnotation"
                            )
                        ))
                    }
                    continue
                }

                let type = resolvedType.trimmedDescription
                let isOptional = resolvedType.is(OptionalTypeSyntax.self)
                    || (type.hasPrefix("Optional<") && type.hasSuffix(">"))
                let name = pattern.identifier.text
                properties.append(StoredProperty(
                    name: name,
                    wireName: stripBackticks(name),
                    type: type,
                    isOptional: isOptional,
                    guideDescriptionSource: guideDescriptionSource,
                    guideExpressions: guideExpressions
                ))
            }
        }
        return properties
    }

    /// True when the accessor block declares a stored property: observers
    /// only (willSet/didSet). A getter (or get/set/_read/...) is computed.
    private static func isStoredAccessorBlock(_ block: AccessorBlockSyntax) -> Bool {
        switch block.accessors {
        case .getter:
            return false
        case .accessors(let list):
            return list.allSatisfy { accessor in
                let kind = accessor.accessorSpecifier.text
                return kind == "willSet" || kind == "didSet"
            }
        }
    }

    private static func attribute(named name: String, on variable: VariableDeclSyntax) -> AttributeSyntax? {
        for attribute in variable.attributes {
            guard let attribute = attribute.as(AttributeSyntax.self) else { continue }
            // Compare the terminal name so module-qualified attributes
            // (@ServerFoundationModels.Guide) are recognized too.
            let terminalName: String?
            if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
                terminalName = identifier.name.text
            } else if let memberType = attribute.attributeName.as(MemberTypeSyntax.self) {
                terminalName = memberType.name.text
            } else {
                terminalName = nil
            }
            if terminalName == name { return attribute }
        }
        return nil
    }

    /// The original `description:` argument expression source, spliced
    /// verbatim into generated code.
    private static func descriptionArgumentSource(in node: AttributeSyntax) -> String? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for argument in arguments where argument.label?.text == "description" {
            return argument.expression.trimmedDescription
        }
        return nil
    }

    /// The Swift source to re-emit for a guide expression. Regex literals
    /// (whose pattern text is only available syntactically — Swift's Regex
    /// cannot expose it at runtime) are converted to real pattern guides.
    private static func guideExpressionSource(_ expression: ExprSyntax) -> String {
        if let regex = expression.as(RegexLiteralExprSyntax.self) {
            return ".pattern(\"\(escapedForStringLiteral(regex.regex.text))\")"
        }
        // `.pattern(/.../)` — rewrite the inner regex literal the same way,
        // since the Regex-based overload cannot recover the pattern text.
        if let call = expression.as(FunctionCallExprSyntax.self),
            let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            member.declName.baseName.text == "pattern",
            call.arguments.count == 1,
            let regex = call.arguments.first?.expression.as(RegexLiteralExprSyntax.self) {
            return ".pattern(\"\(escapedForStringLiteral(regex.regex.text))\")"
        }
        return expression.trimmedDescription
    }

    /// Escapes regex pattern text for emission inside a plain double-quoted
    /// Swift string literal.
    private static func escapedForStringLiteral(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\0": result += "\\0"
            default: result.append(character)
            }
        }
        return result
    }

    private static func stripBackticks(_ name: String) -> String {
        var stripped = name
        while stripped.hasPrefix("`") { stripped.removeFirst() }
        while stripped.hasSuffix("`") { stripped.removeLast() }
        return stripped
    }

    /// The access-control prefix generated members should carry, mirroring
    /// the attached declaration ("public " / "package " / "" for internal
    /// and below — default visibility always satisfies the conformance).
    static func accessModifier(in modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers {
            switch modifier.name.text {
            case "open", "public":
                return "public "
            case "package":
                return "package "
            default:
                continue
            }
        }
        return ""
    }
}
