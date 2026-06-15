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
