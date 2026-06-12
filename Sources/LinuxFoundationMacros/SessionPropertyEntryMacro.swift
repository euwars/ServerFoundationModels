// @SessionPropertyEntry — declares a session property on SessionPropertyValues,
// mirroring FoundationModels (SDK 27). Generates a __Key_-prefixed
// SessionPropertyKey peer carrying the default value and accessors that route
// through the keyed subscript.

import SwiftSyntax
import SwiftSyntaxMacros

public struct SessionPropertyEntryMacro: AccessorMacro, PeerMacro {

    private struct MacroError: Error, CustomStringConvertible {
        let description: String
    }

    private static func parts(
        of declaration: some DeclSyntaxProtocol
    ) throws -> (name: String, type: String, defaultValue: String) {
        guard let variable = declaration.as(VariableDeclSyntax.self),
            let binding = variable.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            let type = binding.typeAnnotation?.type.trimmedDescription,
            let initializer = binding.initializer?.value.trimmedDescription
        else {
            throw MacroError(
                description: "@SessionPropertyEntry requires 'var name: Type = defaultValue'"
            )
        }
        return (pattern.identifier.text, type, initializer)
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let (name, _, _) = try parts(of: declaration)
        return [
            "get { self[__Key_\(raw: name).self] }",
            "set { self[__Key_\(raw: name).self] = newValue }",
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let (name, type, defaultValue) = try parts(of: declaration)
        return [
            """
            public struct __Key_\(raw: name): SessionPropertyKey {
                public static var defaultValue: \(raw: type) { \(raw: defaultValue) }
            }
            """
        ]
    }
}

/// Parity declaration; Apple's expansion uses it internally. Expands to nothing.
public struct SessionPropertyEntryDefaultValueMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        []
    }
}
