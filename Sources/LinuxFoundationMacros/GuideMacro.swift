// @Guide — a marker the GenerableMacro reads syntactically while expanding
// the enclosing type. Expands to nothing itself.

import SwiftSyntax
import SwiftSyntaxMacros

public struct GuideMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
