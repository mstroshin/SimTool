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
