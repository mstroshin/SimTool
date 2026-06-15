import Foundation
import Observation
import XCTest
@testable import SimToolStateLogger

struct FixtureSettings {
    var theme = "dark"
}

@SimToolDebugState
struct FixtureCoords {
    var x = 1.0
    var y = 2.0
}

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
    var settings = FixtureSettings()
    var coords = FixtureCoords()
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
        XCTAssertEqual(
            object["settings"], .string("<FixtureSettings>"),
            "un-annotated nested structs must reduce to a type placeholder"
        )
        XCTAssertEqual(
            object["coords"], .object(["x": .number(1), "y": .number(2)]),
            "@SimToolDebugState structs must expand"
        )
        XCTAssertNil(object["computedDoubled"], "computed properties must be skipped")
        guard case .object(let child)? = object["child"] else { return XCTFail("expected child object") }
        XCTAssertEqual(child["label"], .string("child"))
    }
}
