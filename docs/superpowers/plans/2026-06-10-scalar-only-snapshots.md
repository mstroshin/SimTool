# Scalar-Only Snapshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `SimToolStateSerializer` emits only scalars and collections of scalars; un-annotated nested structs/classes become `"<TypeName>"` placeholders, while `@SimToolDebugState` models keep expanding.

**Architecture:** All changes live in the `StateLogger/` package: one serializer rewrite (deleting the Encodable path and Mirror struct/class expansion), updated serializer tests, one new integration-fixture assertion, and a README note. Wire format, macro, tracker, server, and web UI are untouched. Spec: `docs/superpowers/specs/2026-06-10-scalar-only-snapshots-design.md`.

**Tech Stack:** Swift, XCTest, SwiftPM (`cd /Users/maksim/Workspace/SimTool/StateLogger && swift test`).

**Conventions:** Never `git add -A`/`git add .` — stage named files only. Commit messages end with:
`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Rewrite the serializer to the scalar-only rule

**Files:**
- Modify: `StateLogger/Sources/SimToolStateLogger/StateSerializer.swift` (full rewrite of the body)
- Modify: `StateLogger/Tests/SimToolStateLoggerTests/StateSerializerTests.swift` (full rewrite)

- [ ] **Step 1: Rewrite the tests to the new rule** — replace the file content with:

```swift
import Foundation
import XCTest
@testable import SimToolStateLogger

// File-scope fixtures (local types can't reliably conform).
private struct PlainUser: Encodable {
    var name = "Blob"
}

private final class PlainService {}

private enum Status {
    case idle
    case loading(Double)
    case failed(PlainUser)
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

    func testScalars() {
        XCTAssertEqual(serialize(true), .bool(true))
        XCTAssertEqual(serialize(42), .number(42))
        XCTAssertEqual(serialize(1.5), .number(1.5))
        XCTAssertEqual(serialize("hi"), .string("hi"))
        XCTAssertEqual(serialize(URL(string: "https://example.test")!), .string("https://example.test"))
    }

    func testOptionals() {
        XCTAssertEqual(serialize(Optional<Int>.none as Any), .null)
        XCTAssertEqual(serialize(Optional<Int>.some(7) as Any), .number(7))
        XCTAssertEqual(serialize(Optional<PlainUser>.some(PlainUser()) as Any), .string("<PlainUser>"))
    }

    func testScalarCollectionsStayFull() {
        XCTAssertEqual(serialize([1, 2]), .array([.number(1), .number(2)]))
        XCTAssertEqual(serialize(["a": 1]), .object(["a": .number(1)]))
    }

    func testNestedStructBecomesPlaceholder() {
        // Even Encodable structs no longer expand — the JSONEncoder path is gone.
        XCTAssertEqual(serialize(PlainUser()), .string("<PlainUser>"))
    }

    func testNestedClassBecomesPlaceholder() {
        XCTAssertEqual(serialize(PlainService()), .string("<PlainService>"))
    }

    func testCollectionsOfNonScalarsKeepShape() {
        XCTAssertEqual(
            serialize([PlainUser(), PlainUser()]),
            .array([.string("<PlainUser>"), .string("<PlainUser>")])
        )
        XCTAssertEqual(
            serialize(["u": PlainUser()]),
            .object(["u": .string("<PlainUser>")])
        )
    }

    func testEnums() {
        XCTAssertEqual(serialize(Status.idle), .string("idle"))
        XCTAssertEqual(serialize(Status.loading(0.5)), .object(["loading": .number(0.5)]))
        XCTAssertEqual(serialize(Status.failed(PlainUser())), .object(["failed": .string("<PlainUser>")]))
    }

    func testReportableRecursesAndCutsCycles() {
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

    func testDataBecomesPlaceholder() {
        XCTAssertEqual(serialize(Data([1, 2, 3])), .string("<Data>"))
    }

    func testClosureAndTupleBecomePlaceholders() {
        let closure: () -> Void = {}
        guard case .string(let closurePlaceholder) = serialize(closure) else {
            return XCTFail("expected placeholder for closure")
        }
        XCTAssertTrue(closurePlaceholder.hasPrefix("<"), "got: \(closurePlaceholder)")

        guard case .string(let tuplePlaceholder) = serialize((1, "a")) else {
            return XCTFail("expected placeholder for tuple")
        }
        XCTAssertTrue(tuplePlaceholder.hasPrefix("<"), "got: \(tuplePlaceholder)")
    }
}
```

- [ ] **Step 2: Run tests to verify the new expectations fail**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateSerializerTests`
Expected: FAIL — `testNestedStructBecomesPlaceholder` (old code expands `PlainUser` via JSONEncoder), `testNestedClassBecomesPlaceholder`, `testCollectionsOfNonScalarsKeepShape`, `testEnums` (failed case), `testDataBecomesPlaceholder`. Scalar/optional/cycle tests still pass.

- [ ] **Step 3: Rewrite the serializer** — replace the content of `StateSerializer.swift` with:

```swift
// StateLogger/Sources/SimToolStateLogger/StateSerializer.swift
import Foundation

/// Converts property values into `SimToolStateValue` JSON, emitting ONLY scalars and
/// collections of scalars. Un-annotated nested structs/classes reduce to a
/// `"<TypeName>"` placeholder; `@SimToolDebugState` models (`SimToolStateReportable`)
/// expand via their own generated snapshot, cycle-guarded. Resolution order:
/// passthrough → optional unwrap → scalars → reportable → collections/dictionaries/enums
/// (elements by the same rule) → placeholder. Serialization never throws out of a
/// snapshot; placeholders are stable strings, so hidden objects produce no diff noise.
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
        case let primitive as Int: return .number(Double(primitive))
        case let primitive as Int8: return .number(Double(primitive))
        case let primitive as Int16: return .number(Double(primitive))
        case let primitive as Int32: return .number(Double(primitive))
        case let primitive as Int64: return .number(Double(primitive))
        case let primitive as UInt: return .number(Double(primitive))
        case let primitive as UInt8: return .number(Double(primitive))
        case let primitive as UInt16: return .number(Double(primitive))
        case let primitive as UInt32: return .number(Double(primitive))
        case let primitive as UInt64: return .number(Double(primitive))
        case let primitive as Double: return .number(primitive)
        case let primitive as Float: return .number(Double(primitive))
        case let primitive as Date: return .string(iso8601.string(from: primitive))
        case let primitive as URL: return .string(primitive.absoluteString)
        case is Data: return placeholder(for: value)  // Mirror may report Data as a collection of bytes
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
            return placeholder(for: value)
        }
    }

    private static func placeholder(for value: Any) -> SimToolStateValue {
        .string("<\(type(of: value))>")
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
```

Deleted relative to the previous version: the `any Encodable` → `JSONEncoder` path (and the `encodeToStateValue` helper), the Mirror `.struct/.class/.tuple` expansion with its class-side cycle guard and leading-underscore label stripping. The enum branch is unchanged — its payload now flows through the new rule naturally.

- [ ] **Step 4: Run the serializer tests**

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter StateSerializerTests`
Expected: PASS (10 tests). If `testDataBecomesPlaceholder` reports a different placeholder, keep the explicit `case is Data` and make it produce exactly `"<Data>"` — do not let `Data` fall through to the collection branch (it would dump raw bytes).

- [ ] **Step 5: Run the whole package** — `swift test` from `StateLogger/`.
Expected: `MacroIntegrationTests.testSnapshotReflectsStoredPropertiesOnly` now FAILS — the fixture asserts `child` expands as an object, and `FixtureChild` IS `@SimToolDebugState`, so it still expands; but check the `tags` and nested assertions. If the only failures are in tests whose expectations Task 2 updates (integration fixture), note them and proceed to Task 2 BEFORE committing — Tasks 1 and 2 land as one commit if needed to keep the suite green per commit. If `MacroIntegrationTests` still passes (it may — `FixtureChild` is reportable and `tags` is a scalar array), just continue.

- [ ] **Step 6: Commit** (only if the full suite is green; otherwise commit together with Task 2)

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Sources/SimToolStateLogger/StateSerializer.swift StateLogger/Tests/SimToolStateLoggerTests/StateSerializerTests.swift
git commit -m "feat(state)!: serializer emits only scalars; nested types become placeholders"
```

---

### Task 2: Integration fixture — non-reportable struct property

**Files:**
- Modify: `StateLogger/Tests/SimToolStateLoggerTests/MacroIntegrationTests.swift`

- [ ] **Step 1: Extend the fixture and assertions.** Add a file-scope struct and a property to `FixtureModel`:

```swift
struct FixtureSettings {
    var theme = "dark"
}
```

In `FixtureModel`, add after `var tags: [String] = ["a"]`:

```swift
    var settings = FixtureSettings()
```

In `testSnapshotReflectsStoredPropertiesOnly`, add after the `tags` assertion:

```swift
        XCTAssertEqual(
            object["settings"], .string("<FixtureSettings>"),
            "un-annotated nested structs must reduce to a type placeholder"
        )
```

Keep the existing `child` assertions unchanged — `FixtureChild` is `@SimToolDebugState`, so it must STILL expand to `.object(["label": .string("child")])`.

- [ ] **Step 2: Run the integration + tracker tests** (tracker reuses `FixtureModel`)

Run: `cd /Users/maksim/Workspace/SimTool/StateLogger && swift test --filter "MacroIntegrationTests|StateTrackerTests"`
Expected: PASS (5 tests). The tracker tests assert on `code`-like scalar fields only and are unaffected by the new property.

- [ ] **Step 3: Run the whole package** — `swift test`: all green (the suite should total 31 tests: 10 serializer + 2 integration-related changes keep counts at 1 integration + 4 tracker + the rest unchanged; trust the "0 failures" line over the count).

- [ ] **Step 4: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add StateLogger/Tests/SimToolStateLoggerTests/MacroIntegrationTests.swift
git commit -m "test(state): nested un-annotated struct renders as placeholder in real macro expansion"
```

(If Task 1 Step 6 was deferred, commit both tasks' files together here with the Task 1 message plus this test file.)

---

### Task 3: README note + full verification

**Files:**
- Modify: `README.md` (the "Model state inspector (`@SimToolDebugState`)" section)

- [ ] **Step 1: Update the notes list.** In the section's Notes bullets, replace the bullet
`- Snapshots include stored properties only. ...` with:

```markdown
- Snapshots include stored properties only, and only **scalars and collections of
  scalars** (Bool/numbers/String/Date/URL). Nested structs and classes render as a
  `"<TypeName>"` placeholder — annotate the nested class with `@SimToolDebugState`
  too if you want its contents. `@ObservationIgnored` properties appear in
  snapshots (as scalars or placeholders) but do not trigger updates.
```

- [ ] **Step 2: Full sweep**

```bash
cd /Users/maksim/Workspace/SimTool/StateLogger && swift test
cd /Users/maksim/Workspace/SimTool && swift test
```

Expected: all green in both packages (the main package's `StateLoggerRouteTests` use scalar-only snapshots already and are unaffected).

- [ ] **Step 3: Commit**

```bash
cd /Users/maksim/Workspace/SimTool
git add README.md
git commit -m "docs: scalar-only snapshot rule for @SimToolDebugState"
```

---

## Self-review

- **Spec coverage:** rule items 1–6 → Task 1 serializer; deleted behaviors → Task 1 Step 3 note; integration fixture → Task 2; README → Task 3; "unchanged" items need no tasks (verified by the full sweep).
- **Type consistency:** `placeholder(for:)`, `PlainUser`/`PlainService`/`FixtureSettings` names consistent across tasks.
- **No placeholders:** all steps carry complete code/commands.
