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
