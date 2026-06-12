import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct LinuxFoundationMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        GenerableMacro.self,
        GuideMacro.self,
        SessionPropertyEntryMacro.self,
        SessionPropertyEntryDefaultValueMacro.self,
    ]
}
