# SimTool State Logger (`@SimToolDebugState`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apps annotate `@Observable` models with `@SimToolDebugState`; in debug builds every state change streams to SimTool and shows up in the web UI as live snapshots plus a diff history.

**Architecture:** A new standalone SwiftPM package `StateLogger/` (mirroring `NetworkLogger/`) holds the macro, an observation-driven tracker, a Mirror-based JSON serializer, shared payload models, and the event store. The SimTool server adds two routes (`POST`/`GET /api/v1/state/events`) following the network-events pattern, and the web UI gets a "State" inspector tab. Spec: `docs/superpowers/specs/2026-06-10-simtool-state-macro-design.md`.

**Tech Stack:** Swift 5.9+ package (builds with the installed Swift 6.3 toolchain), swift-syntax macros, Observation framework, Swifter HTTP server, vanilla-JS embedded web UI, XCTest.

**Conventions for every task:**
- Run package tests with `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test`; main-package tests with `cd /Users/maksim/Workspace/SimTool && swift test --filter <TestClass>`.
- The working tree already has unrelated modified files (`Sources/SimToolCore/AppLaunch.swift`, `Sources/SimToolServer/StreamServer.swift`, `Tests/SimToolCoreTests/AppLaunchRegistryTests.swift`). **Always `git add` only the files you created/changed for your task — never `git add -A`.**
- Commit messages follow repo style (`feat(state): …`, `test(state): …`) and end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- In macro-expansion tests, if `assertMacroExpansion` fails on a *whitespace-only* diff, update the expected string to the actual formatting — indentation produced by SwiftSyntax can differ slightly between versions. Semantic diffs are real failures.

---

### Task 1: StateLogger package skeleton

**Files:**
- Create: `StateLogger/Package.swift`
- Create: `StateLogger/Sources/SimToolStateLogger/StateReportable.swift` (stub, filled in Task 2/5)
- Create: `StateLogger/Sources/SimToolStateLoggerMacros/Plugin.swift`
- Create: `StateLogger/Tests/SimToolStateLoggerTests/StateValueTests.swift` (placeholder test)

- [ ] **Step 1: Create the package manifest**

```swift
// StateLogger/Package.swift
// swift-tools-version: 5.9
import CompilerPluginSupport
import PackageDescription

// Standalone package for the embeddable model-state logger. Kept separate from the main
// SimTool package (like NetworkLogger) so host apps can depend on only this product.
// iOS floor stays at 15 so SimToolClient consumers don't regress; the Observation-driven
// tracker is gated with @available(iOS 17, macOS 14, *).
let package = Package(
    name: "SimToolStateLogger",
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        .library(name: "SimToolStateLogger", targets: ["SimToolStateLogger"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "509.0.0"..<"700.0.0"),
    ],
    targets: [
        .target(name: "SimToolStateLogger", dependencies: ["SimToolStateLoggerMacros"]),
        .macro(
            name: "SimToolStateLoggerMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "SimToolStateLoggerTests",
            dependencies: ["SimToolStateLogger"]
        ),
        .testTarget(
            name: "SimToolStateLoggerMacrosTests",
            dependencies: [
                "SimToolStateLoggerMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Create the plugin entry point and a stub source file**

```swift
// StateLogger/Sources/SimToolStateLoggerMacros/Plugin.swift
import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SimToolStateLoggerPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = []
}
```

```swift
// StateLogger/Sources/SimToolStateLogger/StateReportable.swift
// Filled in by later tasks; placeholder so the target compiles.
```

```swift
// StateLogger/Tests/SimToolStateLoggerTests/StateValueTests.swift
import XCTest
@testable import SimToolStateLogger

final class StateValueTests: XCTestCase {
    func testPackageBuilds() {
        XCTAssertTrue(true)
    }
}
```

Note: the `SimToolStateLoggerMacrosTests` target needs at least one source file to build; create `StateLogger/Tests/SimToolStateLoggerMacrosTests/SimToolDebugStateMacroTests.swift` with an empty `final class SimToolDebugStateMacroTests: XCTestCase {}` (imports added in Task 5).

- [ ] **Step 3: Verify the package builds and tests pass**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test`
Expected: first run resolves and compiles swift-syntax (takes a few minutes), then `Test Suite 'All tests' passed`.

- [ ] **Step 4: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger
git commit -m "feat(state): scaffold SimToolStateLogger package with macro target"
```

---

### Task 2: `SimToolStateValue` — JSON value type

**Files:**
- Create: `StateLogger/Sources/SimToolStateLogger/StateValue.swift`
- Modify: `StateLogger/Tests/SimToolStateLoggerTests/StateValueTests.swift`

- [ ] **Step 1: Write the failing tests** (replace the placeholder test)

```swift
import XCTest
@testable import SimToolStateLogger

final class StateValueTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let value: SimToolStateValue = .object([
            "count": .number(1),
            "title": .string("hi"),
            "flag": .bool(true),
            "missing": .null,
            "items": .array([.number(1), .string("two")]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(SimToolStateValue.self, from: data), value)
    }

    func testEncodesAsPlainJSON() throws {
        let data = try JSONEncoder().encode(SimToolStateValue.object(["a": .number(1)]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":1}"#)
    }

    func testDecodesBoolBeforeNumber() throws {
        let decoded = try JSONDecoder().decode(SimToolStateValue.self, from: Data("true".utf8))
        XCTAssertEqual(decoded, .bool(true))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateValueTests`
Expected: FAIL — `cannot find 'SimToolStateValue' in scope`.

- [ ] **Step 3: Implement `SimToolStateValue`**

```swift
// StateLogger/Sources/SimToolStateLogger/StateValue.swift
import Foundation

/// A plain JSON value: the wire format for model snapshots. Encodes as raw JSON
/// (no enum-case wrappers) so the web UI can consume it directly.
public enum SimToolStateValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SimToolStateValue])
    case object([String: SimToolStateValue])
}

extension SimToolStateValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([SimToolStateValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: SimToolStateValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateValueTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Sources/SimToolStateLogger/StateValue.swift StateLogger/Tests/SimToolStateLoggerTests/StateValueTests.swift
git commit -m "feat(state): add SimToolStateValue JSON value type"
```

---

### Task 3: Event payload models

**Files:**
- Create: `StateLogger/Sources/SimToolStateLogger/StateModels.swift`
- Create: `StateLogger/Tests/SimToolStateLoggerTests/StateModelsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SimToolStateLogger

final class StateModelsTests: XCTestCase {
    func testEventRoundTripsThroughJSON() throws {
        let event = StateLoggerEvent(
            modelId: "AppModel#0",
            name: "AppModel",
            seq: 3,
            timestamp: 1_700_000_000.5,
            snapshot: .object(["count": .number(2)]),
            deallocated: true,
            pid: 123,
            launchId: 1,
            cursor: 42
        )
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(StateLoggerEvent.self, from: data), event)
    }

    func testOptionalFieldsAreOmittedWhenNil() throws {
        let event = StateLoggerEvent(
            modelId: "AppModel#0", name: "AppModel", seq: 0, timestamp: 1, snapshot: .null
        )
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(json.contains("deallocated"))
        XCTAssertFalse(json.contains("launchId"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateModelsTests`
Expected: FAIL — `cannot find 'StateLoggerEvent' in scope`.

- [ ] **Step 3: Implement the models**

```swift
// StateLogger/Sources/SimToolStateLogger/StateModels.swift
import Foundation

/// One state snapshot of one tracked model instance.
public struct StateLoggerEvent: Codable, Equatable, Sendable {
    /// Stable per-instance id: "<name>#<instance counter>".
    public var modelId: String
    public var name: String
    /// Per-instance monotonic sequence number.
    public var seq: Int
    /// Epoch seconds.
    public var timestamp: Double
    public var snapshot: SimToolStateValue
    /// Set on the final event when the tracked model deallocates.
    public var deallocated: Bool?
    public var pid: Int?
    /// Stamped by the server from the batch pid (see AppLaunchRegistry).
    public var launchId: Int?
    /// Server-assigned global ordering cursor; nil until ingested.
    public var cursor: Int?

    public init(
        modelId: String,
        name: String,
        seq: Int,
        timestamp: Double,
        snapshot: SimToolStateValue,
        deallocated: Bool? = nil,
        pid: Int? = nil,
        launchId: Int? = nil,
        cursor: Int? = nil
    ) {
        self.modelId = modelId
        self.name = name
        self.seq = seq
        self.timestamp = timestamp
        self.snapshot = snapshot
        self.deallocated = deallocated
        self.pid = pid
        self.launchId = launchId
        self.cursor = cursor
    }
}

public struct StateLoggerBatchPayload: Codable, Equatable, Sendable {
    public var events: [StateLoggerEvent]
    public var pid: Int?

    public init(events: [StateLoggerEvent], pid: Int? = nil) {
        self.events = events
        self.pid = pid
    }
}

public struct StateLoggerEventsPayload: Codable, Equatable, Sendable {
    public var events: [StateLoggerEvent]
    /// Cursor of the last returned event; pass back as `since` to poll incrementally.
    public var nextCursor: Int

    public init(events: [StateLoggerEvent], nextCursor: Int) {
        self.events = events
        self.nextCursor = nextCursor
    }
}

public struct StateLoggerIngestionResponse: Codable, Equatable, Sendable {
    public var acceptedCount: Int

    public init(acceptedCount: Int) {
        self.acceptedCount = acceptedCount
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateModelsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Sources/SimToolStateLogger/StateModels.swift StateLogger/Tests/SimToolStateLoggerTests/StateModelsTests.swift
git commit -m "feat(state): add state logger event payload models"
```

---

### Task 4: Protocol + Mirror-based serializer

**Files:**
- Modify: `StateLogger/Sources/SimToolStateLogger/StateReportable.swift`
- Create: `StateLogger/Sources/SimToolStateLogger/StateSerializer.swift`
- Create: `StateLogger/Tests/SimToolStateLoggerTests/StateSerializerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import XCTest
@testable import SimToolStateLogger

// File-scope fixtures (local types can't reliably synthesize Codable / conform).
private struct EncodableUser: Encodable {
    var name = "Blob"
}

private enum Status {
    case idle
    case loading(Double)
}

@MainActor
private final class Node: SimToolStateReportable {
    var name = "a"
    var next: Node?

    func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateValue {
        visited.insert(ObjectIdentifier(self))
        return .object([
            "name": SimToolStateSerializer.serialize(name, visited: &visited),
            "next": SimToolStateSerializer.serialize(next as Any, visited: &visited),
        ])
    }
}

@MainActor
final class StateSerializerTests: XCTestCase {
    private func serialize(_ value: Any) -> SimToolStateValue {
        var visited: Set<ObjectIdentifier> = []
        return SimToolStateSerializer.serialize(value, visited: &visited)
    }

    func testPrimitives() {
        XCTAssertEqual(serialize(true), .bool(true))
        XCTAssertEqual(serialize(42), .number(42))
        XCTAssertEqual(serialize(1.5), .number(1.5))
        XCTAssertEqual(serialize("hi"), .string("hi"))
        XCTAssertEqual(serialize(URL(string: "https://example.test")!), .string("https://example.test"))
    }

    func testOptionals() {
        XCTAssertEqual(serialize(Optional<Int>.none as Any), .null)
        XCTAssertEqual(serialize(Optional<Int>.some(7) as Any), .number(7))
    }

    func testCollections() {
        XCTAssertEqual(serialize([1, 2]), .array([.number(1), .number(2)]))
        XCTAssertEqual(serialize(["a": 1]), .object(["a": .number(1)]))
    }

    func testEncodableGoesThroughJSONEncoder() {
        XCTAssertEqual(serialize(EncodableUser()), .object(["name": .string("Blob")]))
    }

    func testEnums() {
        XCTAssertEqual(serialize(Status.idle), .string("idle"))
        XCTAssertEqual(serialize(Status.loading(0.5)), .object(["loading": .number(0.5)]))
    }

    func testNestedReportableRecursesAndCutsCycles() {
        let a = Node()
        let b = Node()
        b.name = "b"
        a.next = b
        b.next = a
        let snapshot = a._simToolSnapshot()
        guard case .object(let aObject) = snapshot,
              case .object(let bObject)? = aObject["next"] else {
            return XCTFail("expected nested objects, got \(snapshot)")
        }
        XCTAssertEqual(bObject["name"], .string("b"))
        XCTAssertEqual(bObject["next"], .string("<cycle: Node>"))
    }

    func testFallbackUsesStringDescribing() {
        let closure: () -> Void = {}
        guard case .string(let description) = serialize(closure) else {
            return XCTFail("expected string fallback")
        }
        XCTAssertTrue(description.contains("Function"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateSerializerTests`
Expected: FAIL — `cannot find type 'SimToolStateReportable' in scope`.

- [ ] **Step 3: Implement the protocol**

Replace the placeholder content of `StateReportable.swift`:

```swift
// StateLogger/Sources/SimToolStateLogger/StateReportable.swift
import Foundation

/// A model whose state can be snapshotted for SimTool. Conformance is generated
/// by the `@SimToolDebugState` macro; do not implement by hand in app code.
///
/// The requirement is `@MainActor` (not the whole protocol) so conforming types do
/// not become implicitly main-actor-isolated, while `@MainActor` model classes can
/// still satisfy it.
public protocol SimToolStateReportable: AnyObject {
    @MainActor
    func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateValue
}

extension SimToolStateReportable {
    @MainActor
    public func _simToolSnapshot() -> SimToolStateValue {
        var visited: Set<ObjectIdentifier> = []
        return _simToolSnapshot(visited: &visited)
    }
}
```

- [ ] **Step 4: Implement the serializer**

```swift
// StateLogger/Sources/SimToolStateLogger/StateSerializer.swift
import Foundation

/// Converts arbitrary property values into `SimToolStateValue` JSON. Resolution order:
/// passthrough → optional unwrap → primitives → nested reportable models (cycle-guarded)
/// → Encodable via JSONEncoder → Mirror reflection → `String(describing:)` fallback.
/// Serialization must never throw out of a snapshot: unrepresentable values degrade
/// to placeholder strings.
@MainActor
public enum SimToolStateSerializer {
    public static func serialize(_ value: Any, visited: inout Set<ObjectIdentifier>) -> SimToolStateValue {
        if let already = value as? SimToolStateValue { return already }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return .null }
            return serialize(child.value, visited: &visited)
        }

        switch value {
        case let primitive as Bool: return .bool(primitive)
        case let primitive as String: return .string(primitive)
        case let primitive as any BinaryInteger: return .number(Double(primitive))
        case let primitive as Double: return .number(primitive)
        case let primitive as Float: return .number(Double(primitive))
        case let primitive as Date: return .string(iso8601.string(from: primitive))
        case let primitive as URL: return .string(primitive.absoluteString)
        default: break
        }

        if let reportable = value as? any SimToolStateReportable {
            if visited.contains(ObjectIdentifier(reportable)) {
                return .string("<cycle: \(type(of: reportable))>")
            }
            // The generated snapshot method inserts the instance into `visited` itself.
            return reportable._simToolSnapshot(visited: &visited)
        }

        switch mirror.displayStyle {
        case .collection, .set:
            return .array(mirror.children.map { serialize($0.value, visited: &visited) })
        case .dictionary:
            var object: [String: SimToolStateValue] = [:]
            for child in mirror.children {
                let pair = Mirror(reflecting: child.value).children.map(\.value)
                guard pair.count == 2 else { continue }
                object[String(describing: pair[0])] = serialize(pair[1], visited: &visited)
            }
            return .object(object)
        case .enum:
            guard let child = mirror.children.first, let label = child.label else {
                return .string(String(describing: value))
            }
            return .object([label: serialize(child.value, visited: &visited)])
        default:
            break
        }

        if let encodable = value as? any Encodable,
           let encoded = try? encodeToStateValue(encodable) {
            return encoded
        }

        switch mirror.displayStyle {
        case .struct, .class, .tuple:
            if mirror.displayStyle == .class {
                let object = value as AnyObject
                if visited.contains(ObjectIdentifier(object)) {
                    return .string("<cycle: \(type(of: value))>")
                }
                visited.insert(ObjectIdentifier(object))
            }
            guard !mirror.children.isEmpty else { return .string(String(describing: value)) }
            var object: [String: SimToolStateValue] = [:]
            var index = 0
            for child in mirror.children {
                let rawLabel = child.label ?? ".\(index)"
                // @Observable rewrites storage to underscored properties; strip for display.
                let label = rawLabel.hasPrefix("_") ? String(rawLabel.dropFirst()) : rawLabel
                object[label] = serialize(child.value, visited: &visited)
                index += 1
            }
            return .object(object)
        default:
            return .string(String(describing: value))
        }
    }

    private static func encodeToStateValue(_ value: some Encodable) throws -> SimToolStateValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(SimToolStateValue.self, from: data)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateSerializerTests`
Expected: PASS (7 tests). If `testEnums` fails because Mirror reports the associated value differently on this toolchain, adjust the expectation to the actual shape (the point is: case name appears, payload is serialized).

- [ ] **Step 6: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Sources/SimToolStateLogger/StateReportable.swift StateLogger/Sources/SimToolStateLogger/StateSerializer.swift StateLogger/Tests/SimToolStateLoggerTests/StateSerializerTests.swift
git commit -m "feat(state): add SimToolStateReportable protocol and Mirror-based serializer"
```

---

### Task 5: `@SimToolDebugState` macro

**Files:**
- Create: `StateLogger/Sources/SimToolStateLoggerMacros/SimToolDebugStateMacro.swift`
- Modify: `StateLogger/Sources/SimToolStateLoggerMacros/Plugin.swift`
- Modify: `StateLogger/Sources/SimToolStateLogger/StateReportable.swift` (add macro declaration)
- Modify: `StateLogger/Tests/SimToolStateLoggerMacrosTests/SimToolDebugStateMacroTests.swift`

- [ ] **Step 1: Write the failing macro-expansion tests**

```swift
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
import SimToolStateLoggerMacros

final class SimToolDebugStateMacroTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["SimToolDebugState": SimToolDebugStateMacro.self]

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

                public func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateLogger.SimToolStateValue {
                    #if DEBUG
                    visited.insert(ObjectIdentifier(self))
                    return .object([
                        "count": SimToolStateLogger.SimToolStateSerializer.serialize(self.count, visited: &visited),
                        "id": SimToolStateLogger.SimToolStateSerializer.serialize(self.id, visited: &visited),
                    ])
                    #else
                    return .null
                    #endif
                }
            }

            extension AppModel: SimToolStateLogger.SimToolStateReportable {
            }
            """,
            macros: macros
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

                func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateLogger.SimToolStateValue {
                    #if DEBUG
                    visited.insert(ObjectIdentifier(self))
                    return .object([:])
                    #else
                    return .null
                    #endif
                }
            }

            extension Empty: SimToolStateLogger.SimToolStateReportable {
            }
            """,
            macros: macros
        )
    }

    func testDiagnosesMissingObservable() {
        assertMacroExpansion(
            """
            @SimToolDebugState
            final class AppModel {
                var count = 0
            }
            """,
            expandedSource:
            """
            final class AppModel {
                var count = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'@SimToolDebugState' requires the class to also apply '@Observable'",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }

    func testDiagnosesNonClass() {
        assertMacroExpansion(
            """
            @SimToolDebugState
            struct AppState {
                var count = 0
            }
            """,
            expandedSource:
            """
            struct AppState {
                var count = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'@SimToolDebugState' can only be applied to a class",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter SimToolDebugStateMacroTests`
Expected: FAIL — `cannot find 'SimToolDebugStateMacro' in scope`.

- [ ] **Step 3: Implement the macro**

```swift
// StateLogger/Sources/SimToolStateLoggerMacros/SimToolDebugStateMacro.swift
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct SimToolDebugStateMacro {}

enum SimToolDebugStateDiagnostic: String, DiagnosticMessage {
    case classOnly
    case requiresObservable

    var message: String {
        switch self {
        case .classOnly:
            return "'@SimToolDebugState' can only be applied to a class"
        case .requiresObservable:
            return "'@SimToolDebugState' requires the class to also apply '@Observable'"
        }
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
        guard validClass(declaration) != nil, !protocols.isEmpty else { return [] }
        return [
            try ExtensionDeclSyntax(
                "extension \(type.trimmed): SimToolStateLogger.SimToolStateReportable {}"
            )
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
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(node), message: SimToolDebugStateDiagnostic.classOnly)
            ])
        }
        guard hasObservableAttribute(classDecl) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(node), message: SimToolDebugStateDiagnostic.requiresObservable)
            ])
        }

        let access = classDecl.modifiers.first {
            $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.package)
        }.map { "\($0.name.text) " } ?? ""

        let names = storedPropertyNames(of: classDecl)
        let dictionary: String
        if names.isEmpty {
            dictionary = "[:]"
        } else {
            let entries = names
                .map { "\"\($0)\": SimToolStateLogger.SimToolStateSerializer.serialize(self.\($0), visited: &visited)" }
                .joined(separator: ",\n            ")
            dictionary = "[\n            \(entries),\n        ]"
        }

        return [
            """
            \(raw: access)func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateLogger.SimToolStateValue {
                #if DEBUG
                visited.insert(ObjectIdentifier(self))
                return .object(\(raw: dictionary))
                #else
                return .null
                #endif
            }
            """
        ]
    }
}

private func validClass(_ declaration: some DeclGroupSyntax) -> ClassDeclSyntax? {
    guard let classDecl = declaration.as(ClassDeclSyntax.self),
          hasObservableAttribute(classDecl) else { return nil }
    return classDecl
}

private func hasObservableAttribute(_ declaration: ClassDeclSyntax) -> Bool {
    declaration.attributes.contains { element in
        guard case .attribute(let attribute) = element else { return false }
        return attribute.attributeName.trimmedDescription.split(separator: ".").last == "Observable"
    }
}

/// Stored instance properties only: skips statics, computed properties (get/set
/// accessors), but keeps properties with willSet/didSet observers.
private func storedPropertyNames(of classDecl: ClassDeclSyntax) -> [String] {
    var names: [String] = []
    for member in classDecl.memberBlock.members {
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
```

Register it in `Plugin.swift`:

```swift
let providingMacros: [Macro.Type] = [SimToolDebugStateMacro.self]
```

- [ ] **Step 4: Declare the macro in the runtime target**

Append to `StateLogger/Sources/SimToolStateLogger/StateReportable.swift`:

```swift
/// Generates a `SimToolStateReportable` conformance plus a `_simToolSnapshot(visited:)`
/// member that reads every stored property through its accessor — which is what lets
/// `withObservationTracking` detect changes. Requires `@Observable` on the same class.
@attached(member, names: named(_simToolSnapshot))
@attached(extension, conformances: SimToolStateReportable)
public macro SimToolDebugState() =
    #externalMacro(module: "SimToolStateLoggerMacros", type: "SimToolDebugStateMacro")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter SimToolDebugStateMacroTests`
Expected: PASS (4 tests). Whitespace-only diffs: update expected strings (see Conventions).

- [ ] **Step 6: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Sources/SimToolStateLoggerMacros StateLogger/Sources/SimToolStateLogger/StateReportable.swift StateLogger/Tests/SimToolStateLoggerMacrosTests
git commit -m "feat(state): implement @SimToolDebugState macro with diagnostics"
```

---

### Task 6: Macro integration fixture (end-to-end snapshot)

**Files:**
- Create: `StateLogger/Tests/SimToolStateLoggerTests/MacroIntegrationTests.swift`

- [ ] **Step 1: Write the test** (this exercises the *compiled* macro through the real `@Observable` pipeline)

```swift
import Foundation
import Observation
import XCTest
@testable import SimToolStateLogger

@available(macOS 14.0, iOS 17.0, *)
@Observable
@SimToolDebugState
@MainActor
final class FixtureChild {
    var label = "child"
}

@available(macOS 14.0, iOS 17.0, *)
@Observable
@SimToolDebugState
@MainActor
final class FixtureModel {
    var count = 0
    var title = "hello"
    var child: FixtureChild?
    var tags: [String] = ["a"]
    var computedDoubled: Int { count * 2 }
}

final class MacroIntegrationTests: XCTestCase {
    @MainActor
    func testSnapshotReflectsStoredPropertiesOnly() throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation") }
        let model = FixtureModel()
        model.count = 3
        model.child = FixtureChild()

        let snapshot = model._simToolSnapshot()

        guard case .object(let object) = snapshot else { return XCTFail("expected object") }
        XCTAssertEqual(object["count"], .number(3))
        XCTAssertEqual(object["title"], .string("hello"))
        XCTAssertEqual(object["tags"], .array([.string("a")]))
        XCTAssertNil(object["computedDoubled"], "computed properties must be skipped")
        guard case .object(let child)? = object["child"] else { return XCTFail("expected child object") }
        XCTAssertEqual(child["label"], .string("child"))
    }
}
```

- [ ] **Step 2: Run the test**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter MacroIntegrationTests`
Expected: PASS. If it fails to *compile*, the macro expansion is wrong for real `@Observable` classes — fix the macro (Task 5), not the test. Likely culprits: access-level mismatch or the member colliding with `@Observable`'s generated members.

- [ ] **Step 3: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Tests/SimToolStateLoggerTests/MacroIntegrationTests.swift
git commit -m "test(state): end-to-end macro expansion against real @Observable classes"
```

---

### Task 7: `StateLoggerEventStore`

**Files:**
- Create: `StateLogger/Sources/SimToolStateLogger/StateEventStore.swift`
- Create: `StateLogger/Tests/SimToolStateLoggerTests/StateEventStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SimToolStateLogger

final class StateEventStoreTests: XCTestCase {
    private func makeEvent(modelId: String = "AppModel#0", seq: Int) -> StateLoggerEvent {
        StateLoggerEvent(
            modelId: modelId,
            name: "AppModel",
            seq: seq,
            timestamp: 1_700_000_000 + Double(seq),
            snapshot: .object(["count": .number(Double(seq))])
        )
    }

    func testAssignsCursorsAndQueriesIncrementally() {
        let store = StateLoggerEventStore()
        XCTAssertEqual(store.ingest([makeEvent(seq: 0), makeEvent(seq: 1)]).acceptedCount, 2)

        let all = store.query()
        XCTAssertEqual(all.events.map(\.cursor), [0, 1])
        XCTAssertEqual(all.nextCursor, 1)

        store.ingest([makeEvent(seq: 2)])
        let incremental = store.query(since: all.nextCursor)
        XCTAssertEqual(incremental.events.map(\.seq), [2])
        XCTAssertEqual(incremental.nextCursor, 2)

        // Nothing new: nextCursor must echo `since` so the client cursor doesn't reset.
        let empty = store.query(since: incremental.nextCursor)
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertEqual(empty.nextCursor, 2)
    }

    func testPerModelCapacityEvictsOldestOfThatModel() {
        let store = StateLoggerEventStore(perModelCapacity: 2, maxModels: 50)
        store.ingest([makeEvent(seq: 0), makeEvent(seq: 1), makeEvent(seq: 2)])
        XCTAssertEqual(store.query().events.map(\.seq), [1, 2])
    }

    func testModelCapEvictsLeastRecentlyUpdatedModel() {
        let store = StateLoggerEventStore(perModelCapacity: 10, maxModels: 2)
        store.ingest([makeEvent(modelId: "A#0", seq: 0)])
        store.ingest([makeEvent(modelId: "B#0", seq: 0)])
        store.ingest([makeEvent(modelId: "C#0", seq: 0)])
        let ids = Set(store.query().events.map(\.modelId))
        XCTAssertEqual(ids, ["B#0", "C#0"])
    }

    func testLimitKeepsOldestSoClientsPageForwardWithoutGaps() {
        let store = StateLoggerEventStore()
        store.ingest((0..<5).map { makeEvent(seq: $0) })
        let page = store.query(limit: 2)
        XCTAssertEqual(page.events.map(\.cursor), [0, 1])
        XCTAssertEqual(page.nextCursor, 1)
        let next = store.query(since: page.nextCursor, limit: 2)
        XCTAssertEqual(next.events.map(\.cursor), [2, 3])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateEventStoreTests`
Expected: FAIL — `cannot find 'StateLoggerEventStore' in scope`.

- [ ] **Step 3: Implement the store**

```swift
// StateLogger/Sources/SimToolStateLogger/StateEventStore.swift
import Foundation

/// Server-side buffer of ingested state events. Bounded two ways: a per-model ring
/// (oldest snapshots of a chatty model drop first) and a model cap (the least recently
/// updated model is evicted wholesale). Cursor semantics mirror the log capture buffer:
/// clients pass back `nextCursor` as `since` to read incrementally without gaps.
public final class StateLoggerEventStore: @unchecked Sendable {
    public let perModelCapacity: Int
    public let maxModels: Int

    private let lock = NSLock()
    private var eventsByModel: [String: [StateLoggerEvent]] = [:]
    /// Least recently updated first.
    private var modelRecency: [String] = []
    private var nextCursor = 0

    public init(perModelCapacity: Int = 200, maxModels: Int = 50) {
        self.perModelCapacity = max(1, perModelCapacity)
        self.maxModels = max(1, maxModels)
    }

    @discardableResult
    public func ingest(_ events: [StateLoggerEvent]) -> StateLoggerIngestionResponse {
        lock.lock()
        defer { lock.unlock() }
        for var event in events {
            event.cursor = nextCursor
            nextCursor += 1
            eventsByModel[event.modelId, default: []].append(event)
            if eventsByModel[event.modelId]!.count > perModelCapacity {
                eventsByModel[event.modelId]!.removeFirst()
            }
            modelRecency.removeAll { $0 == event.modelId }
            modelRecency.append(event.modelId)
            if eventsByModel.count > maxModels, let evicted = modelRecency.first {
                eventsByModel.removeValue(forKey: evicted)
                modelRecency.removeFirst()
            }
        }
        return StateLoggerIngestionResponse(acceptedCount: events.count)
    }

    public func query(since: Int? = nil, limit: Int = 500) -> StateLoggerEventsPayload {
        lock.lock()
        defer { lock.unlock() }
        var all = eventsByModel.values.flatMap { $0 }
        if let since {
            all.removeAll { ($0.cursor ?? -1) <= since }
        }
        all.sort { ($0.cursor ?? -1) < ($1.cursor ?? -1) }
        if all.count > limit {
            all.removeLast(all.count - limit)
        }
        return StateLoggerEventsPayload(
            events: all,
            nextCursor: all.last?.cursor ?? since ?? -1
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateEventStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Sources/SimToolStateLogger/StateEventStore.swift StateLogger/Tests/SimToolStateLoggerTests/StateEventStoreTests.swift
git commit -m "feat(state): add cursor-based StateLoggerEventStore with capacity bounds"
```

---

### Task 8: Transport sink + environment activation

**Files:**
- Create: `StateLogger/Sources/SimToolStateLogger/StateSinks.swift`
- Create: `StateLogger/Tests/SimToolStateLoggerTests/StateSinksTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import XCTest
@testable import SimToolStateLogger

final class StateSinksTests: XCTestCase {
    func testEndpointURLBuilding() {
        func endpoint(_ raw: String) -> String {
            StateLoggerServerSink.endpointURL(for: URL(string: raw)!).absoluteString
        }
        XCTAssertEqual(endpoint("http://127.0.0.1:3311"), "http://127.0.0.1:3311/api/v1/state/events")
        XCTAssertEqual(endpoint("http://127.0.0.1:3311/api/v1"), "http://127.0.0.1:3311/api/v1/state/events")
        XCTAssertEqual(
            endpoint("http://127.0.0.1:3311/api/v1/state/events"),
            "http://127.0.0.1:3311/api/v1/state/events"
        )
    }

    func testOversizedSnapshotIsTruncated() {
        let big = StateLoggerEvent(
            modelId: "M#0", name: "M", seq: 0, timestamp: 1,
            snapshot: .string(String(repeating: "x", count: 1_000))
        )
        let capped = StateLoggerServerSink.capped(big, maxBytes: 100)
        guard case .string(let marker) = capped.snapshot else { return XCTFail("expected marker") }
        XCTAssertTrue(marker.hasPrefix("<truncated"), "got: \(marker)")

        let small = StateLoggerServerSink.capped(big, maxBytes: 100_000)
        XCTAssertEqual(small.snapshot, big.snapshot)
    }

    func testEnvironmentResolutionRequiresBothVariables() {
        XCTAssertNil(StateLoggerEnvironment.resolveSink(environment: [:]))
        XCTAssertNil(StateLoggerEnvironment.resolveSink(environment: ["SIMTOOL_STATE_LOGGER": "1"]))
        XCTAssertNil(StateLoggerEnvironment.resolveSink(environment: [
            "SIMTOOL_SERVER_URL": "http://127.0.0.1:3311",
        ]))
        let sink = StateLoggerEnvironment.resolveSink(environment: [
            "SIMTOOL_STATE_LOGGER": "1",
            "SIMTOOL_SERVER_URL": "http://127.0.0.1:3311",
        ])
        XCTAssertNotNil(sink as? StateLoggerServerSink)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateSinksTests`
Expected: FAIL — `cannot find 'StateLoggerServerSink' in scope`.

- [ ] **Step 3: Implement sinks and activation**

```swift
// StateLogger/Sources/SimToolStateLogger/StateSinks.swift
import Foundation

public protocol StateLoggerSink: Sendable {
    func record(_ events: [StateLoggerEvent]) async
}

/// POSTs event batches to the SimTool server. Mirrors NetworkLoggerServerSink:
/// best-effort, never throws into the host app, short timeout.
public final class StateLoggerServerSink: StateLoggerSink, @unchecked Sendable {
    public let serverURL: URL
    public let timeout: TimeInterval
    public let maxEventBytes: Int

    private let session: URLSession

    public init(
        serverURL: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 2,
        maxEventBytes: Int = 256_000
    ) {
        self.serverURL = serverURL
        self.session = session
        self.timeout = timeout
        self.maxEventBytes = maxEventBytes
    }

    public func record(_ events: [StateLoggerEvent]) async {
        guard !events.isEmpty else { return }
        do {
            var request = URLRequest(url: Self.endpointURL(for: serverURL))
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(StateLoggerBatchPayload(
                events: events.map { Self.capped($0, maxBytes: maxEventBytes) },
                pid: Int(ProcessInfo.processInfo.processIdentifier)
            ))
            _ = try await session.data(for: request)
        } catch {
            // Live export is best-effort and must not affect the host app.
        }
    }

    static func endpointURL(for serverURL: URL) -> URL {
        let path = serverURL.path
        if path.hasSuffix("/api/v1/state/events") { return serverURL }
        if path.hasSuffix("/api/v1") { return serverURL.appendingPathComponent("state/events") }
        return serverURL.appendingPathComponent("api/v1/state/events")
    }

    /// Replaces snapshots whose encoded size exceeds `maxBytes` with a marker string,
    /// so one huge model can't flood the channel.
    static func capped(_ event: StateLoggerEvent, maxBytes: Int) -> StateLoggerEvent {
        guard maxBytes > 0,
              let size = try? JSONEncoder().encode(event.snapshot).count,
              size > maxBytes else { return event }
        var event = event
        event.snapshot = .string("<truncated: snapshot was \(size) bytes, cap is \(maxBytes)>")
        return event
    }
}

/// Arms the logger from the environment, following the SimToolNetworkLogger convention:
/// SimTool launches the app with SIMTOOL_STATE_LOGGER=1 and SIMTOOL_SERVER_URL set.
public enum StateLoggerEnvironment {
    public static let enabledKey = "SIMTOOL_STATE_LOGGER"
    public static let serverURLKey = "SIMTOOL_SERVER_URL"

    public static func resolveSink(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> StateLoggerSink? {
        guard environment[enabledKey] == "1",
              let raw = environment[serverURLKey],
              let url = URL(string: raw) else { return nil }
        return StateLoggerServerSink(serverURL: url)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateSinksTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Sources/SimToolStateLogger/StateSinks.swift StateLogger/Tests/SimToolStateLoggerTests/StateSinksTests.swift
git commit -m "feat(state): add server sink with payload cap and env activation"
```

---

### Task 9: `SimToolState` tracker (observation loop)

**Files:**
- Create: `StateLogger/Sources/SimToolStateLogger/StateTracker.swift`
- Create: `StateLogger/Tests/SimToolStateLoggerTests/StateTrackerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Observation
import XCTest
@testable import SimToolStateLogger

private final class RecordingSink: StateLoggerSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StateLoggerEvent] = []

    var events: [StateLoggerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ events: [StateLoggerEvent]) async {
        lock.lock()
        stored.append(contentsOf: events)
        lock.unlock()
    }
}

final class StateTrackerTests: XCTestCase {
    @MainActor
    override func tearDown() {
        if #available(macOS 14.0, *) { SimToolState.reset() }
        super.tearDown()
    }

    @MainActor
    func testEmitsInitialSnapshotAndDebouncedChangeEvents() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        let model = FixtureModel()
        SimToolState.track(model, name: "Fixture")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sink.events.count, 1, "initial snapshot")
        XCTAssertEqual(sink.events[0].modelId, "Fixture#0")
        XCTAssertEqual(sink.events[0].seq, 0)

        model.count = 1
        model.count = 2
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sink.events.count, 2, "burst must coalesce into one event")
        let last = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(last.seq, 1)
        guard case .object(let object) = last.snapshot else { return XCTFail("expected object") }
        XCTAssertEqual(object["count"], .number(2), "snapshot must hold the final value")
    }

    @MainActor
    func testSecondInstanceGetsDistinctModelId() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        SimToolState.track(FixtureModel(), name: "Fixture")
        SimToolState.track(FixtureModel(), name: "Fixture")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Set(sink.events.map(\.modelId)), ["Fixture#0", "Fixture#1"])
    }

    @MainActor
    func testDeallocatedModelEmitsFinalEvent() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        var model: FixtureModel? = FixtureModel()
        SimToolState.track(model!, name: "Fixture")
        try await Task.sleep(for: .milliseconds(100))

        model?.count = 1   // arm a refresh…
        model = nil        // …then release before the debounce fires
        try await Task.sleep(for: .milliseconds(200))

        let last = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(last.deallocated, true)
    }

    @MainActor
    func testTrackWithoutSinkIsInert() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation") }
        SimToolState.configure(sink: nil)
        SimToolState.track(FixtureModel(), name: "Fixture")
        // No crash, no retain: nothing to assert beyond clean completion.
    }
}
```

Note: `FixtureModel` comes from `MacroIntegrationTests.swift` (same test module). It is `private` there? No — it is file-scope but **not** private; if Task 6 declared it `private`, remove `private` so this file can use it.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateTrackerTests`
Expected: FAIL — `cannot find 'SimToolState' in scope`.

- [ ] **Step 3: Implement the tracker**

```swift
// StateLogger/Sources/SimToolStateLogger/StateTracker.swift
import Foundation
import Observation

/// Entry point apps call to stream a model's state to SimTool.
///
/// All tracking runs on the main actor: snapshots read model properties, and
/// `@Observable` UI models are typically main-actor-bound. Inert unless a sink is
/// armed (via SIMTOOL_STATE_LOGGER=1 + SIMTOOL_SERVER_URL, or `configure` in tests).
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public enum SimToolState {
    private static var sink: StateLoggerSink?
    private static var sinkResolved = false
    private static var debounce: Duration = .milliseconds(100)
    private static var observers: [StateModelObserver] = []
    private static var instanceCounters: [String: Int] = [:]

    public static func track(_ model: some SimToolStateReportable, name: String) {
        #if DEBUG
        if !sinkResolved {
            sink = StateLoggerEnvironment.resolveSink()
            sinkResolved = true
        }
        guard let sink else { return }
        let instance = instanceCounters[name, default: 0]
        instanceCounters[name] = instance + 1
        let observer = StateModelObserver(
            model: model,
            modelId: "\(name)#\(instance)",
            name: name,
            debounce: debounce,
            sink: sink
        )
        observers.append(observer)
        observer.start()
        #endif
    }

    /// Test hook: overrides the environment-resolved sink and debounce interval.
    public static func configure(sink: StateLoggerSink?, debounce: Duration = .milliseconds(100)) {
        self.sink = sink
        self.sinkResolved = true
        self.debounce = debounce
    }

    /// Test hook: stops all observers and clears configuration.
    public static func reset() {
        observers.forEach { $0.stop() }
        observers = []
        instanceCounters = [:]
        sink = nil
        sinkResolved = false
        debounce = .milliseconds(100)
    }
}

/// One re-arming `withObservationTracking` loop per tracked instance. Holds the model
/// weakly; when the model deallocates, the next armed refresh emits a final
/// `deallocated` event and stops.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class StateModelObserver {
    private weak var model: (any SimToolStateReportable)?
    private let modelId: String
    private let name: String
    private let debounce: Duration
    private let sink: StateLoggerSink
    private var seq = 0
    private var refreshTask: Task<Void, Never>?
    private var stopped = false

    init(
        model: any SimToolStateReportable,
        modelId: String,
        name: String,
        debounce: Duration,
        sink: StateLoggerSink
    ) {
        self.model = model
        self.modelId = modelId
        self.name = name
        self.debounce = debounce
        self.sink = sink
    }

    func start() {
        observe()
    }

    func stop() {
        stopped = true
        refreshTask?.cancel()
    }

    private func observe() {
        guard !stopped else { return }
        guard let model else {
            emit(snapshot: .null, deallocated: true)
            stopped = true
            return
        }
        let snapshot = withObservationTracking {
            model._simToolSnapshot()
        } onChange: { [weak self] in
            // onChange is willSet and may fire off-main; hop to the main actor and
            // debounce, then re-read so the event carries the *new* values.
            Task { @MainActor in self?.scheduleRefresh() }
        }
        emit(snapshot: snapshot, deallocated: false)
    }

    private func scheduleRefresh() {
        guard !stopped else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            self.observe()
        }
    }

    private func emit(snapshot: SimToolStateValue, deallocated: Bool) {
        let event = StateLoggerEvent(
            modelId: modelId,
            name: name,
            seq: seq,
            timestamp: Date().timeIntervalSince1970,
            snapshot: snapshot,
            deallocated: deallocated ? true : nil,
            pid: Int(ProcessInfo.processInfo.processIdentifier)
        )
        seq += 1
        let sink = self.sink
        Task { await sink.record([event]) }
    }
}
```

- [ ] **Step 4: Run all package tests**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test`
Expected: PASS. The tracker tests are timing-based; if flaky, raise the sleeps (debounce 10 ms / sleeps ≥ 100 ms gives ample margin).

- [ ] **Step 5: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Sources/SimToolStateLogger/StateTracker.swift StateLogger/Tests/SimToolStateLoggerTests/StateTrackerTests.swift
git commit -m "feat(state): add observation-driven SimToolState tracker with debounce"
```

---

### Task 10: Server routes + SimToolClient methods

**Files:**
- Modify: `Package.swift` (root)
- Modify: `Sources/SimToolServer/StreamServer.swift`
- Modify: `Sources/SimToolClient/SimToolClient.swift`
- Create: `Tests/SimToolServerTests/StateLoggerRouteTests.swift`

> `StreamServer.swift` already has unrelated uncommitted changes. Make your edits on top; when committing, `git add` it — the unrelated changes in this file will ride along, which is acceptable only for THIS file if they are part of the user's in-progress work. **Stop and ask the user** if `git diff Sources/SimToolServer/StreamServer.swift` shows changes unrelated to both state logging and the current working-tree baseline you started from. (Default expectation: the pre-existing diff stays as-is; your commit includes it. If the user prefers, they can commit their changes first.)

- [ ] **Step 1: Wire the package dependency**

In root `Package.swift`:
- In `dependencies:` add after `.package(path: "NetworkLogger"),`:

```swift
        .package(path: "StateLogger"),
```

- In the `SimToolServer` target dependencies add after the `SimToolNetworkLogger` product line:

```swift
                .product(name: "SimToolStateLogger", package: "StateLogger"),
```

- In the `SimToolClient` target, change dependencies to:

```swift
            dependencies: [
                "SimToolCore",
                .product(name: "SimToolNetworkLogger", package: "NetworkLogger"),
                .product(name: "SimToolStateLogger", package: "StateLogger"),
            ]
```

- In the `SimToolServerTests` test target dependencies add:

```swift
                .product(name: "SimToolStateLogger", package: "StateLogger"),
```

Run: `cd /Users/maksim/Workspace/SimTool && swift build --target SimToolServer`
Expected: builds (first build compiles swift-syntax for the macro plugin — slow once).

- [ ] **Step 2: Write the failing route tests**

```swift
// Tests/SimToolServerTests/StateLoggerRouteTests.swift
import Darwin
import Foundation
import XCTest
import SimToolClient
import SimToolCore
import SimToolStateLogger
import SimToolServer

final class StateLoggerRouteTests: XCTestCase {
    func testStateRoutesIngestAndPollIncrementally() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let client = SimToolClient(baseURL: baseURL)

        let response = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [
            makeEvent(seq: 0),
            makeEvent(seq: 1),
        ]))
        XCTAssertEqual(response.acceptedCount, 2)

        let all = try await client.stateLoggerEvents()
        XCTAssertEqual(all.events.map(\.seq), [0, 1])
        XCTAssertEqual(all.nextCursor, 1)

        _ = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [makeEvent(seq: 2)]))
        let incremental = try await client.stateLoggerEvents(since: all.nextCursor)
        XCTAssertEqual(incremental.events.map(\.seq), [2])

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/state/events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("not json".utf8)
        let (_, invalidResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((invalidResponse as? HTTPURLResponse)?.statusCode, 400)
    }

    func testStateBatchesAreTaggedWithLaunch() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        let client = SimToolClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        _ = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [makeEvent(seq: 0)], pid: 100))
        _ = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [makeEvent(seq: 1)], pid: 200))

        let launches = try await client.launches()
        XCTAssertEqual(launches.launches.map(\.pid), [100, 200])

        let events = try await client.stateLoggerEvents()
        XCTAssertEqual(events.events.map(\.launchId), [0, 1])
        XCTAssertEqual(events.events.first?.pid, 100)
    }

    private func makeEvent(seq: Int) -> StateLoggerEvent {
        StateLoggerEvent(
            modelId: "AppModel#0",
            name: "AppModel",
            seq: seq,
            timestamp: 1_700_000_000 + Double(seq),
            snapshot: .object(["count": .number(Double(seq))])
        )
    }

    private func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(descriptor, rebound, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return UInt16(bigEndian: address.sin_port)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /Users/maksim/Workspace/SimTool && swift test --filter StateLoggerRouteTests`
Expected: FAIL to compile — `SimToolClient` has no `ingestStateLoggerEvents`.

- [ ] **Step 4: Implement server routes**

In `Sources/SimToolServer/StreamServer.swift`:

1. Add import (after `import SimToolNetworkLogger`):

```swift
import SimToolStateLogger
```

2. Add the store property (after the `networkLoggerEvents` property, ~line 43):

```swift
    private let stateLoggerEvents = StateLoggerEventStore()
```

3. Add routes inside `installRoutes()`, right after the `server.GET["/api/v1/network/events"]` block:

```swift
        server.POST["/api/v1/state/events"] = { request in
            self.handleStateLoggerIngestion(request)
        }

        server.GET["/api/v1/state/events"] = { request in
            let since = request.queryInt("since")
            let limit = request.queryInt("limit") ?? 500
            do {
                return try self.jsonEncodedResponse(self.stateLoggerEvents.query(since: since, limit: limit))
            } catch {
                return self.errorResponse(error)
            }
        }
```

4. Add the handler + launch tagging, right after `networkLoggerFilter(from:)`:

```swift
    private func handleStateLoggerIngestion(_ request: HttpRequest) -> HttpResponse {
        do {
            let batch = try decodeJSON(StateLoggerBatchPayload.self, from: request)
            return try jsonEncodedResponse(stateLoggerEvents.ingest(stateEventsTaggedWithLaunch(batch)))
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// Mirrors `taggedWithLaunch(_:)` for state events: attributes a batch to an app
    /// launch by its pid and stamps each event with the resolved `launchId`.
    private func stateEventsTaggedWithLaunch(_ batch: StateLoggerBatchPayload) -> [StateLoggerEvent] {
        guard let pid = batch.pid, !batch.events.isEmpty else { return batch.events }
        let earliest = batch.events.map(\.timestamp).min() ?? batch.events[0].timestamp
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date(timeIntervalSince1970: earliest))
        let launchId = launches.observe(pid: pid, timestamp: timestamp)
        return batch.events.map { event in
            var event = event
            event.pid = event.pid ?? pid
            event.launchId = launchId
            return event
        }
    }
```

- [ ] **Step 5: Implement client methods**

In `Sources/SimToolClient/SimToolClient.swift`:

1. Add import (after `import SimToolNetworkLogger`):

```swift
import SimToolStateLogger
```

2. Add methods right after `ingestNetworkLoggerEvents`:

```swift
    public func stateLoggerEvents(since: Int? = nil, limit: Int = 500) async throws -> StateLoggerEventsPayload {
        var components = URLComponents(url: apiURL.appendingPathComponent("state/events"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let since { queryItems.append(URLQueryItem(name: "since", value: "\(since)")) }
        components.queryItems = queryItems
        return try await getJSON(StateLoggerEventsPayload.self, url: components.url!)
    }

    public func ingestStateLoggerEvents(_ batch: StateLoggerBatchPayload) async throws -> StateLoggerIngestionResponse {
        try await sendJSON(StateLoggerIngestionResponse.self, path: "state/events", payload: batch, method: "POST")
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/maksim/Workspace/SimTool && swift test --filter StateLoggerRouteTests`
Expected: PASS (2 tests).
Also run: `swift test --filter NetworkLoggerRouteTests` — must still PASS (no regression).

- [ ] **Step 7: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add Package.swift Package.resolved Sources/SimToolServer/StreamServer.swift Sources/SimToolClient/SimToolClient.swift Tests/SimToolServerTests/StateLoggerRouteTests.swift
git commit -m "feat(server): add /api/v1/state/events routes with launch tagging"
```

---

### Task 11: Web UI "State" tab

**Files:**
- Modify: `Sources/SimToolWeb/WebViewer.swift`
- Modify: `Tests/SimToolWebTests/SimToolWebTests.swift`

- [ ] **Step 1: Write the failing test** (append to `SimToolWebTests`)

```swift
    func testViewerEmbedsStateInspector() {
        let html = WebViewer.html()

        XCTAssertTrue(html.contains("id=\"tabState\""), "missing State tab")
        XCTAssertTrue(html.contains("id=\"statePane\""), "missing state pane")
        XCTAssertTrue(html.contains("id=\"stateModels\""), "missing model snapshot list")
        XCTAssertTrue(html.contains("id=\"stateHistory\""), "missing state change history")
        XCTAssertTrue(html.contains("/api/v1/state/events"), "state inspector must poll the state events endpoint")
        XCTAssertTrue(html.contains("function renderStateTree"), "missing snapshot tree renderer")
        XCTAssertTrue(html.contains("function diffStateValues"), "missing snapshot diff")
        XCTAssertTrue(html.contains("state-dead"), "deallocated models must be greyed out")
    }
```

Run: `cd /Users/maksim/Workspace/SimTool && swift test --filter SimToolWebTests/testViewerEmbedsStateInspector`
Expected: FAIL on every assertion.

- [ ] **Step 2: Add the tab button**

In `Sources/SimToolWeb/WebViewer.swift`, after the `tabLogs` button line (~line 48), add:

```html
                      <button id="tabState" class="insp-tab" type="button" data-tab="state">State <span id="stateCount" class="tab-count">0</span></button>
```

- [ ] **Step 3: Add the pane markup**

Locate `<div id="axPane" class="ax-pane" hidden>` (~line 63), find its matching closing `</div>`, and add the new pane as a sibling right after it:

```html
                    <div id="statePane" class="state-pane" hidden>
                      <div id="stateModels" class="state-models"></div>
                      <div id="stateHistory" class="state-history"></div>
                    </div>
```

- [ ] **Step 4: Add CSS**

After the `.insp-tab.active .tab-count` rule (~line 162), add:

```css
    .state-pane { display: flex; flex-direction: column; gap: 8px; padding: 8px; overflow: auto; flex: 1; min-height: 0; }
    .state-models { display: flex; flex-direction: column; gap: 6px; }
    .state-model { border: 1px solid rgba(255,255,255,0.08); border-radius: 6px; padding: 6px 8px; }
    .state-model.state-dead { opacity: 0.45; }
    .state-model summary { cursor: pointer; font: 12px ui-sans-serif, system-ui, sans-serif; color: #bae6fd; }
    .state-tree { margin: 4px 0 0 12px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: #cdd6e6; }
    .state-history { display: flex; flex-direction: column; gap: 4px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; }
    .state-change { border-top: 1px solid rgba(255,255,255,0.06); padding-top: 4px; }
    .state-change-title { color: rgba(244,247,251,0.55); }
    .state-diff-minus { color: #fda4af; }
    .state-diff-plus { color: #86efac; }
```

- [ ] **Step 5: Wire the tab into existing JS**

1. Element refs — near `const axPane = $("axPane");` (~line 292), add:

```js
    const statePane = $("statePane");
    const stateModelsEl = $("stateModels");
    const stateHistoryEl = $("stateHistory");
    const stateCountEl = $("stateCount");
```

2. `tabButtons` (~line 286): change to include the new tab:

```js
    const tabButtons = { network: $("tabNetwork"), logs: $("tabLogs"), state: $("tabState"), ax: $("tabAx") };
```

3. `filterByTab` (~line 1321): add `state: ""`:

```js
    const filterByTab = { network: "", logs: "", state: "", ax: "" };
```

4. `FILTER_PLACEHOLDER` (~line 1323): add a `state` key, matching the existing entries' style:

```js
      state: "Filter models…",
```

5. In `setActiveTab(tab)` (~line 1342): add the pane toggle next to `axPane.hidden = …`:

```js
      statePane.hidden = tab !== "state";
```

and extend the render/polling branches:

```js
      else if (tab === "state") renderState();
```

```js
      if (tab === "state") startStatePolling(); else stopStatePolling();
```

(Place these alongside the existing `tab === "ax"` equivalents.)

6. In the `inspectorFilter` input listener (~line 1388), add a branch:

```js
      else if (activeTab === "state") renderState();
```

- [ ] **Step 6: Add the state inspector JS block**

Add as a new section before the inspector-shell section (`// ---- Inspector shell: …`, ~line 1316):

```js
    // ---- State inspector: live model snapshots pushed by the app under test ----
    let stateCursor = null;
    let statePollTimer = null;
    const stateLatest = new Map();   // modelId -> latest event
    const stateChanges = [];          // { event, diffs }, oldest first
    const STATE_HISTORY_LIMIT = 300;

    function startStatePolling() {
      if (statePollTimer) return;
      pollStateEvents();
      statePollTimer = setInterval(pollStateEvents, 1000);
    }

    function stopStatePolling() {
      if (!statePollTimer) return;
      clearInterval(statePollTimer);
      statePollTimer = null;
    }

    async function pollStateEvents() {
      try {
        const since = stateCursor == null ? "" : "&since=" + stateCursor;
        const res = await fetch("/api/v1/state/events?limit=500" + since);
        if (!res.ok) return;
        const payload = await res.json();
        if (!payload.events || !payload.events.length) return;
        for (const event of payload.events) {
          const prev = stateLatest.get(event.modelId);
          const diffs = diffStateValues(prev ? prev.snapshot : undefined, event.snapshot, "", []);
          if (prev || event.deallocated) {
            stateChanges.push({ event, diffs });
            if (stateChanges.length > STATE_HISTORY_LIMIT) stateChanges.shift();
          }
          stateLatest.set(event.modelId, event);
        }
        stateCursor = payload.nextCursor;
        stateCountEl.textContent = String(stateLatest.size);
        if (activeTab === "state" && inspectorOpen) renderState();
      } catch (_) { /* server may be restarting; next poll retries */ }
    }

    function diffStateValues(prev, next, path, out) {
      if (JSON.stringify(prev) === JSON.stringify(next)) return out;
      const isPlainObject = (v) => v && typeof v === "object" && !Array.isArray(v);
      if (isPlainObject(prev) && isPlainObject(next)) {
        for (const key of new Set([...Object.keys(prev), ...Object.keys(next)])) {
          diffStateValues(prev[key], next[key], path ? path + "." + key : key, out);
        }
        return out;
      }
      out.push({ path, before: prev, after: next });
      return out;
    }

    function renderStateTree(value, container) {
      const appendBranch = (labelText, child) => {
        const details = document.createElement("details");
        details.open = true;
        const summary = document.createElement("summary");
        summary.textContent = labelText + (Array.isArray(child) ? " [" + child.length + "]" : "");
        details.appendChild(summary);
        const inner = document.createElement("div");
        inner.className = "state-tree";
        renderStateTree(child, inner);
        details.appendChild(inner);
        container.appendChild(details);
      };
      const appendLeaf = (labelText, child) => {
        const row = document.createElement("div");
        row.textContent = labelText + ": " + JSON.stringify(child);
        container.appendChild(row);
      };
      if (value && typeof value === "object" && !Array.isArray(value)) {
        for (const key of Object.keys(value).sort()) {
          const child = value[key];
          if (child && typeof child === "object") appendBranch(key, child);
          else appendLeaf(key, child);
        }
      } else if (Array.isArray(value)) {
        value.forEach((item, index) => {
          if (item && typeof item === "object") appendBranch("[" + index + "]", item);
          else appendLeaf("[" + index + "]", item);
        });
      } else {
        const row = document.createElement("div");
        row.textContent = JSON.stringify(value);
        container.appendChild(row);
      }
    }

    function renderState() {
      const query = (filterByTab.state || "").trim().toLowerCase();
      stateModelsEl.textContent = "";
      for (const id of [...stateLatest.keys()].sort()) {
        if (query && !id.toLowerCase().includes(query)) continue;
        const event = stateLatest.get(id);
        const card = document.createElement("details");
        card.className = "state-model" + (event.deallocated ? " state-dead" : "");
        card.open = true;
        const summary = document.createElement("summary");
        summary.textContent = id + (event.deallocated ? " (deallocated)" : "");
        card.appendChild(summary);
        const tree = document.createElement("div");
        tree.className = "state-tree";
        renderStateTree(event.snapshot, tree);
        card.appendChild(tree);
        stateModelsEl.appendChild(card);
      }
      stateHistoryEl.textContent = "";
      for (let i = stateChanges.length - 1; i >= 0; i--) {
        const { event, diffs } = stateChanges[i];
        if (query && !event.modelId.toLowerCase().includes(query)) continue;
        const block = document.createElement("div");
        block.className = "state-change";
        const title = document.createElement("div");
        title.className = "state-change-title";
        title.textContent = event.modelId + " · seq " + event.seq + " · "
          + new Date(event.timestamp * 1000).toLocaleTimeString()
          + (event.deallocated ? " · deallocated" : "");
        block.appendChild(title);
        for (const diff of diffs) {
          const minus = document.createElement("div");
          minus.className = "state-diff-minus";
          minus.textContent = "- " + diff.path + ": " + JSON.stringify(diff.before);
          block.appendChild(minus);
          const plus = document.createElement("div");
          plus.className = "state-diff-plus";
          plus.textContent = "+ " + diff.path + ": " + JSON.stringify(diff.after);
          block.appendChild(plus);
        }
        stateHistoryEl.appendChild(block);
      }
    }
```

Note: this block references `activeTab`, `inspectorOpen`, and `filterByTab`, which are declared in the inspector-shell section below it. That is fine — the references execute at call time, not load time — but the `const` declarations themselves must not be duplicated.

- [ ] **Step 7: Run tests**

Run: `cd /Users/maksim/Workspace/SimTool && swift test --filter SimToolWebTests`
Expected: PASS (all, including the new test).

- [ ] **Step 8: Manual smoke check**

Run the server against a booted simulator (or any device entry) and open the viewer:

```bash
cd /Users/maksim/Workspace/SimTool && swift run simtool serve 2>/dev/null &
sleep 5
curl -s -X POST http://127.0.0.1:3311/api/v1/state/events -H 'Content-Type: application/json' \
  -d '{"events":[{"modelId":"AppModel#0","name":"AppModel","seq":0,"timestamp":1718000000,"snapshot":{"count":1,"user":{"name":"Blob"}}}],"pid":42}'
curl -s "http://127.0.0.1:3311/api/v1/state/events" | head -c 400
```

Expected: `{"acceptedCount":1}` then the event JSON back. Open `http://127.0.0.1:3311`, switch to the **State** tab: the `AppModel#0` card shows the tree. POST a second event with `"count":2` and `"seq":1` — within a second the card updates and the history shows `- count: 1` / `+ count: 2`. Kill the server afterwards. (If `simtool serve` needs different arguments on this machine, check `swift run simtool --help`; if no simulator is available, the curl-level check plus the unit test is sufficient.)

- [ ] **Step 9: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add Sources/SimToolWeb/WebViewer.swift Tests/SimToolWebTests/SimToolWebTests.swift
git commit -m "feat(web): add State inspector tab with live snapshots and diff history"
```

---

### Task 12: Documentation + full verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document usage**

Find the section of `README.md` that documents the network logger (search for `SimToolNetworkLogger` or `SIMTOOL_NETWORK_LOGGER`) and add a parallel section after it, adapting heading level to match:

````markdown
## Model state inspector (`@SimToolDebugState`)

Stream your `@Observable` models' state to the SimTool web UI in debug builds.
Annotate the model and register the instance once:

```swift
import SimToolStateLogger

@Observable
@SimToolDebugState
final class AppModel {
    var count = 0
    var user: User?
}

// e.g. in your App setup:
SimToolState.track(model, name: "AppModel")
```

Add the package to your app (debug configurations only is fine):

```swift
.package(path: "path/to/SimTool/StateLogger"),
// target dependency:
.product(name: "SimToolStateLogger", package: "StateLogger"),
```

The logger is inert unless the app is launched with `SIMTOOL_STATE_LOGGER=1` and
`SIMTOOL_SERVER_URL` (SimTool's app-launch flow sets these). Every change — from
methods, SwiftUI bindings, or async tasks — is debounced (~100 ms) and pushed to
the **State** tab: latest snapshot per model as an expandable tree, plus a diff
history. Notes:

- Requires iOS 17+ (`@Observable`). The macro errors at compile time without `@Observable`.
- Snapshots include stored properties only. `@ObservationIgnored` properties appear
  in snapshots but do not trigger updates.
- No method attribution: events tell you *what* changed, not *which method* changed it.
- Snapshots over 256 KB are replaced with a truncation marker.
````

If the README has no network-logger section, append this at the end instead.

- [ ] **Step 2: Full test sweep**

```bash
cd /Users/maksim/Workspace/SimTool/StateLogger && swift test
cd /Users/maksim/Workspace/SimTool && swift test
```

Expected: all green. If pre-existing tests unrelated to this work fail identically on a clean checkout (`git stash` to verify, then `git stash pop`), report them but do not fix them here.

- [ ] **Step 3: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add README.md
git commit -m "docs: document the @SimToolDebugState model state inspector"
```

---

## Self-review checklist (run after writing, fixed inline)

- **Spec coverage:** macro + conformance (T5), accessor-reads for observation (T5/T6), tracker with debounce + dealloc (T9), serializer with cycles/fallback/cap (T4, T8), env activation (T8), server routes + store + launch tagging (T7, T10), web UI tab with tree + JS diffs + greyed-out dead models (T11), error handling (best-effort sinks T8, placeholder values T4, diagnostics T5), testing strategy (every task), docs (T12). One deliberate deviation from the spec: in release builds the generated method body returns `.null` instead of being compiled out entirely — the conformance must exist unconditionally; the runtime is inert either way.
- **Type consistency:** `SimToolStateValue`, `SimToolStateReportable._simToolSnapshot(visited:)`, `SimToolStateSerializer.serialize(_:visited:)`, `StateLoggerEvent/BatchPayload/EventsPayload/IngestionResponse`, `StateLoggerEventStore.ingest/query(since:limit:)`, `StateLoggerSink.record`, `StateLoggerServerSink.endpointURL/capped`, `SimToolState.track/configure/reset` — names match across tasks.
- **No placeholders:** every code step contains the actual code; the two "adjust if toolchain differs" notes are bounded escape hatches (whitespace in macro tests, Mirror enum shape), not open TODOs.
