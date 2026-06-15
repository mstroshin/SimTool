import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
import SimToolStateLoggerMacros

final class SimToolDebugStateMacroTests: XCTestCase {
    /// `MacroSpec(conformances:)` mirrors what the compiler passes to the extension
    /// macro's `protocols` parameter when the conformance is not already declared.
    private let macroSpecs: [String: MacroSpec] = [
        "SimToolDebugState": MacroSpec(
            type: SimToolDebugStateMacro.self,
            conformances: ["SimToolStateLogger.SimToolStateReportable", "SimToolStateLogger.SimToolStateExpandable"]
        ),
    ]

    func testExpandsStoredPropertiesSkipsComputedAndStatic() {
        assertMacroExpansion(
            """
            @Observable
            @SimToolDebugState
            public final class AppModel {
                var count = 0
                let id = "x"
                var title: String { "t" }
                static var shared = 1
            }
            """,
            expandedSource:
            """
            @Observable
            public final class AppModel {
                var count = 0
                let id = "x"
                var title: String { "t" }
                static var shared = 1

                @MainActor public func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateLogger.SimToolStateValue {
                    #if DEBUG
                    visited.insert(ObjectIdentifier(self))
                    return .object([
                            "count": SimToolStateLogger.SimToolStateSerializer.serialize(self.count as Any, visited: &visited),
                            "id": SimToolStateLogger.SimToolStateSerializer.serialize(self.id as Any, visited: &visited),
                        ])
                    #else
                    return .null
                    #endif
                }
            }

            extension AppModel: SimToolStateLogger.SimToolStateReportable, SimToolStateLogger.SimToolStateExpandable {
            }
            """,
            macroSpecs: macroSpecs
        )
    }

    func testEmptyClassProducesEmptyObject() {
        assertMacroExpansion(
            """
            @Observable
            @SimToolDebugState
            final class Empty {
            }
            """,
            expandedSource:
            """
            @Observable
            final class Empty {

                @MainActor func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateLogger.SimToolStateValue {
                    #if DEBUG
                    visited.insert(ObjectIdentifier(self))
                    return .object([:])
                    #else
                    return .null
                    #endif
                }
            }

            extension Empty: SimToolStateLogger.SimToolStateReportable, SimToolStateLogger.SimToolStateExpandable {
            }
            """,
            macroSpecs: macroSpecs
        )
    }

    func testDiagnosesUnsupportedDeclaration() {
        assertMacroExpansion(
            """
            @SimToolDebugState
            enum AppPhase {
                case idle
            }
            """,
            expandedSource:
            """
            enum AppPhase {
                case idle
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'@SimToolDebugState' can only be applied to a class or a struct",
                    line: 1,
                    column: 1
                ),
            ],
            macroSpecs: macroSpecs
        )
    }

    func testExpandsPlainClassWithoutObservable() {
        assertMacroExpansion(
            """
            @SimToolDebugState
            final class Cart {
                var items = 0
            }
            """,
            expandedSource:
            """
            final class Cart {
                var items = 0

                @MainActor func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateLogger.SimToolStateValue {
                    #if DEBUG
                    visited.insert(ObjectIdentifier(self))
                    return .object([
                            "items": SimToolStateLogger.SimToolStateSerializer.serialize(self.items as Any, visited: &visited),
                        ])
                    #else
                    return .null
                    #endif
                }
            }

            extension Cart: SimToolStateLogger.SimToolStateReportable, SimToolStateLogger.SimToolStateExpandable {
            }
            """,
            macroSpecs: macroSpecs
        )
    }

    func testExpandsStruct() {
        assertMacroExpansion(
            """
            @SimToolDebugState
            public struct Coords {
                var x = 1.0
            }
            """,
            expandedSource:
            """
            public struct Coords {
                var x = 1.0

                @MainActor public func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateLogger.SimToolStateValue {
                    #if DEBUG
                    return .object([
                            "x": SimToolStateLogger.SimToolStateSerializer.serialize(self.x as Any, visited: &visited),
                        ])
                    #else
                    return .null
                    #endif
                }
            }

            extension Coords: SimToolStateLogger.SimToolStateExpandable {
            }
            """,
            macroSpecs: macroSpecs
        )
    }
}
