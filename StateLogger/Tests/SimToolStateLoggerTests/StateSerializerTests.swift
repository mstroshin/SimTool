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

private struct ExpandableCoords: SimToolStateExpandable {
    var x = 1.0
    var y = 2.0

    @MainActor
    func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateValue {
        .object([
            "x": SimToolStateSerializer.serialize(x, visited: &visited),
            "y": SimToolStateSerializer.serialize(y, visited: &visited),
        ])
    }
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
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(serialize(date), .string("1970-01-01T00:00:00.000Z"))
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

    func testExpandableStructExpands() {
        XCTAssertEqual(
            serialize(ExpandableCoords()),
            .object(["x": .number(1), "y": .number(2)])
        )
    }

    func testExpandableStructInsideCollectionsExpands() {
        XCTAssertEqual(
            serialize([ExpandableCoords()]),
            .array([.object(["x": .number(1), "y": .number(2)])])
        )
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
