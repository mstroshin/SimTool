// StateLogger/Sources/SimToolStateLoggerMacros/SimToolDebugStateMacro.swift
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct SimToolDebugStateMacro {}

enum SimToolDebugStateDiagnostic: String, DiagnosticMessage {
    case unsupportedDeclaration

    var message: String {
        "'@SimToolDebugState' can only be applied to a class or a struct"
    }

    var diagnosticID: MessageID { MessageID(domain: "SimToolStateLoggerMacros", id: rawValue) }
    var severity: DiagnosticSeverity { .error }
}

extension SimToolDebugStateMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Validation diagnostics are emitted by the member expansion only, so they
        // don't appear twice; here we just stay silent on invalid declarations.
        guard let kind = annotatedKind(declaration), !protocols.isEmpty else { return [] }
        return [
            try ExtensionDeclSyntax("extension \(type.trimmed): \(raw: kind.conformanceClause) {}")
        ]
    }
}

extension SimToolDebugStateMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let kind = annotatedKind(declaration) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(node), message: SimToolDebugStateDiagnostic.unsupportedDeclaration)
            ])
        }

        let modifiers: DeclModifierListSyntax
        let memberBlock: MemberBlockSyntax
        let insertsVisited: Bool
        switch kind {
        case .classDecl(let classDecl):
            modifiers = classDecl.modifiers
            memberBlock = classDecl.memberBlock
            insertsVisited = true
        case .structDecl(let structDecl):
            modifiers = structDecl.modifiers
            memberBlock = structDecl.memberBlock
            insertsVisited = false
        }

        let access = modifiers.first {
            $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.package)
        }.map { "\($0.name.text) " } ?? ""

        let names = storedPropertyNames(in: memberBlock)
        let dictionary: String
        if names.isEmpty {
            dictionary = "[:]"
        } else {
            let entries = names
                .map { "\"\($0)\": SimToolStateLogger.SimToolStateSerializer.serialize(self.\($0) as Any, visited: &visited)" }
                .joined(separator: ",\n            ")
            dictionary = "[\n            \(entries),\n        ]"
        }

        // Classes record themselves in `visited` to break reference cycles; value
        // types cannot cycle, so structs skip the insert.
        let visitedInsert = insertsVisited ? "visited.insert(ObjectIdentifier(self))\n    " : ""
        return [
            """
            @MainActor \(raw: access)func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateLogger.SimToolStateValue {
                #if DEBUG
                \(raw: visitedInsert)return .object(\(raw: dictionary))
                #else
                return .null
                #endif
            }
            """
        ]
    }
}

private enum AnnotatedKind {
    case classDecl(ClassDeclSyntax)
    case structDecl(StructDeclSyntax)

    /// Classes restate `SimToolStateExpandable` next to `SimToolStateReportable`:
    /// the protocol is in the macro's `conformances:` list, so the compiler
    /// suppresses the conformance implied by protocol inheritance and expects the
    /// macro to declare it explicitly.
    var conformanceClause: String {
        switch self {
        case .classDecl:
            return "SimToolStateLogger.SimToolStateReportable, SimToolStateLogger.SimToolStateExpandable"
        case .structDecl:
            return "SimToolStateLogger.SimToolStateExpandable"
        }
    }
}

private func annotatedKind(_ declaration: some DeclGroupSyntax) -> AnnotatedKind? {
    if let classDecl = declaration.as(ClassDeclSyntax.self) { return .classDecl(classDecl) }
    if let structDecl = declaration.as(StructDeclSyntax.self) { return .structDecl(structDecl) }
    return nil
}

/// Stored instance properties only: skips statics, computed properties (get/set
/// accessors), but keeps properties with willSet/didSet observers.
private func storedPropertyNames(in memberBlock: MemberBlockSyntax) -> [String] {
    var names: [String] = []
    for member in memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
        let isStatic = variable.modifiers.contains {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        }
        if isStatic { continue }
        for binding in variable.bindings {
            if let accessorBlock = binding.accessorBlock, !isStored(accessorBlock) { continue }
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            names.append(identifier.identifier.text)
        }
    }
    return names
}

private func isStored(_ block: AccessorBlockSyntax) -> Bool {
    switch block.accessors {
    case .getter:
        return false
    case .accessors(let list):
        return list.allSatisfy { accessor in
            accessor.accessorSpecifier.tokenKind == .keyword(.willSet)
                || accessor.accessorSpecifier.tokenKind == .keyword(.didSet)
        }
    }
}
