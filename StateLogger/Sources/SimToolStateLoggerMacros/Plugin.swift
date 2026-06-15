import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SimToolStateLoggerPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [SimToolDebugStateMacro.self]
}
