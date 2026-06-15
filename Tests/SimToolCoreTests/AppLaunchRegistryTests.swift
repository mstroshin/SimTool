import Foundation
import XCTest
@testable import SimToolCore

final class AppLaunchRegistryTests: XCTestCase {
    func testSamePidResolvesToSameLaunch() {
        let registry = AppLaunchRegistry()
        let a = registry.observe(pid: 100, app: "x", timestamp: "t0")
        let b = registry.observe(pid: 100, app: "x", timestamp: "t1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(registry.snapshot().count, 1)
        XCTAssertNil(registry.snapshot()[0].endedAt)
    }

    func testPidChangeRegistersNewLaunchAndStampsEnded() {
        let registry = AppLaunchRegistry()
        _ = registry.observe(pid: 100, app: "x", timestamp: "t0")
        let second = registry.observe(pid: 200, app: "x", timestamp: "t1")
        XCTAssertEqual(second, 1)
        let launches = registry.snapshot()
        XCTAssertEqual(launches.map(\.launchId), [0, 1])
        XCTAssertEqual(launches[0].endedAt, "t1")
        XCTAssertEqual(launches[1].startedAt, "t1")
        XCTAssertEqual(launches[1].pid, 200)
        XCTAssertNil(launches[1].endedAt)
    }

    func testCurrentLaunchIdTracksMostRecent() {
        let registry = AppLaunchRegistry()
        XCTAssertNil(registry.currentLaunchId())
        _ = registry.observe(pid: 1, timestamp: "t0")
        _ = registry.observe(pid: 2, timestamp: "t1")
        XCTAssertEqual(registry.currentLaunchId(), 1)
    }

    func testReusedPidAfterDifferentLaunchRegistersNewLaunch() {
        let registry = AppLaunchRegistry()
        _ = registry.observe(pid: 100, timestamp: "t0")          // launch 0
        _ = registry.observe(pid: 200, timestamp: "t1")          // launch 1
        let third = registry.observe(pid: 100, timestamp: "t2")  // pid reused, but a new launch
        XCTAssertEqual(third, 2)
        XCTAssertEqual(registry.snapshot().count, 3)
    }

    func testPrecedingLaunchId() {
        let registry = AppLaunchRegistry()
        _ = registry.observe(pid: 100, timestamp: "t0")  // launch 0
        _ = registry.observe(pid: 200, timestamp: "t1")  // launch 1
        _ = registry.observe(pid: 300, timestamp: "t2")  // launch 2
        XCTAssertNil(registry.launchId(preceding: 0))
        XCTAssertEqual(registry.launchId(preceding: 1), 0)
        XCTAssertEqual(registry.launchId(preceding: 2), 1)
        XCTAssertNil(registry.launchId(preceding: 99))
    }

    func testLaunchesPayloadRoundTrips() throws {
        let payload = AppLaunchesPayload(launches: [
            AppLaunchInfo(launchId: 0, pid: 100, app: "x", startedAt: "t0", endedAt: "t1"),
            AppLaunchInfo(launchId: 1, pid: 200, app: "x", startedAt: "t1"),
        ])
        let data = try JSON.data(payload)
        XCTAssertEqual(try JSON.decoder.decode(AppLaunchesPayload.self, from: data), payload)
    }
}
