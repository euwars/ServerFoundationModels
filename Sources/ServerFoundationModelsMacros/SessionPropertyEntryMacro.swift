// @SessionPropertyEntry — declares a session property on SessionPropertyValues,
// mirroring FoundationModels (SDK 27). Generates a __Key_-prefixed
// SessionPropertyKey peer carrying the default value and accessors that route
// through the keyed subscript.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

public struct SessionPropertyEntryMacro: AccessorMacro, PeerMacro {

    private struct MacroError: Error, CustomStringConvertible {
        let description: String
    }

    private struct SessionPropertyDiagnostic: DiagnosticMessage {
        let message: String
        let diagnosticID: MessageID
        let severity: DiagnosticSeverity

        init(_ message: String, id: String) {
            self.message = message
            self.diagnosticID = MessageID(domain: "ServerFoundationModelsMacros", id: id)
            self.severity = .error
        }
    }

    private static func stripBackticks(_ name: String) -> String {
        var stripped = name
        while stripped.hasPrefix("`") { stripped.removeFirst() }
        while stripped.hasSuffix("`") { stripped.removeLast() }
        return stripped
    }

    private enum PartsResult {
        case success(name: String, keyName: String, type: String, defaultValue: String, access: String)
        case multipleBindings
    }

    private static func parts(
        of declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
        diagnoseMultipleBindings: Bool
    ) throws -> PartsResult {
        guard let variable = declaration.as(VariableDeclSyntax.self) else {
            throw MacroError(
                description: "@SessionPropertyEntry requires 'var name: Type = defaultValue'"
            )
        }
        if variable.bindings.count > 1 {
            if diagnoseMultipleBindings {
                context.diagnose(Diagnostic(
                    node: Syntax(variable),
                    message: SessionPropertyDiagnostic(
                        "@SessionPropertyEntry does not support multiple bindings in one declaration",
                        id: "multipleBindings"
                    )
                ))
            }
            return .multipleBindings
        }
        guard let binding = variable.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            let type = binding.typeAnnotation?.type.trimmedDescription,
            let initializer = binding.initializer?.value.trimmedDescription
        else {
            throw MacroError(
                description: "@SessionPropertyEntry requires 'var name: Type = defaultValue'"
            )
        }
        let name = pattern.identifier.text
        // Mirror the property's access level: a `public` key struct on an
        // internal property (or internal containing type) would not compile.
        return .success(
            name: name,
            keyName: stripBackticks(name),
            type: type,
            defaultValue: initializer,
            access: GenerableMacro.accessModifier(in: variable.modifiers)
        )
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        switch try parts(of: declaration, in: context, diagnoseMultipleBindings: true) {
        case .multipleBindings:
            return []
        case .success(_, let keyName, _, _, _):
            return [
                "get { self[__Key_\(raw: keyName).self] }",
                "set { self[__Key_\(raw: keyName).self] = newValue }",
            ]
        }
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        switch try parts(of: declaration, in: context, diagnoseMultipleBindings: false) {
        case .multipleBindings:
            return []
        case .success(_, let keyName, let type, let defaultValue, let access):
            return [
                """
                \(raw: access)struct __Key_\(raw: keyName): SessionPropertyKey {
                    \(raw: access)static var defaultValue: \(raw: type) { \(raw: defaultValue) }
                }
                """
            ]
        }
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
