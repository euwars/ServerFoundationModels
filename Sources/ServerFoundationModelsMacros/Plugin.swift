import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ServerFoundationModelsMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        GenerableMacro.self,
        GuideMacro.self,
        SessionPropertyEntryMacro.self,
        SessionPropertyEntryDefaultValueMacro.self,
    ]
}
