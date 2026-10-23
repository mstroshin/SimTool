import Foundation
import XCTest
import SimToolCore
@testable import SimToolServer

// What tells a server someone works with from one left running for nobody:
// a tab left open polls and streams by itself, and the app's loggers post
// and poll while it runs — none of that is anyone using it.
final class ServerUsageTests: XCTestCase {
    func testWhatCountsAsUse() {
        XCTAssertTrue(ServerUsage.counts(method: "POST", path: "/api/v1/input", headers: [:]), "the CLI, an agent's curl")
        XCTAssertTrue(ServerUsage.counts(method: "GET", path: "/api/v1/ax/tree", headers: ["user-agent": "curl/8"]))
        XCTAssertTrue(ServerUsage.counts(method: "POST", path: "/api/v1/activity", headers: [:]), "a CLI command on the device")
        XCTAssertFalse(ServerUsage.counts(method: "GET", path: "/api/v1/activity", headers: ["sec-fetch-mode": "cors"]), "the viewer's poll")
        XCTAssertFalse(ServerUsage.counts(method: "GET", path: "/stream.avcc", headers: ["sec-fetch-mode": "cors"]), "the viewer's stream")
        XCTAssertFalse(ServerUsage.counts(method: "POST", path: "/api/v1/logs/capture", headers: ["origin": "http://127.0.0.1:3200"]), "the viewer asking by itself")
        XCTAssertFalse(ServerUsage.counts(method: "POST", path: "/api/v1/network/events", headers: [:]), "the app's network logger")
        XCTAssertFalse(ServerUsage.counts(method: "POST", path: "/api/v1/state/events", headers: [:]), "the app's state logger")
        XCTAssertFalse(ServerUsage.counts(method: "GET", path: "/api/v1/mocks", headers: [:]), "the app polling for mock rules")
        XCTAssertTrue(ServerUsage.counts(method: "POST", path: "/api/v1/mocks", headers: [:]), "arming a mock")
    }

    func testUseOnlyMovesForward() {
        let start = Date(timeIntervalSince1970: 1_000)
        let usage = ServerUsage(now: start)
        usage.note(at: start.addingTimeInterval(10))
        usage.note(at: start.addingTimeInterval(5))
        XCTAssertEqual(usage.lastUse, start.addingTimeInterval(10))
    }
}

final class ServerUsageRouteTests: XCTestCase {
    private var server: StreamServer!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    func testTheViewerPollingIsNotUseButAPersonOnThePageIs() throws {
        let before = server.usageState().lastUse
        Thread.sleep(forTimeInterval: 0.02)
        let poll = try rawHTTP(port: port, "/api/v1/activity", headers: ["Sec-Fetch-Mode": "cors", "Sec-Fetch-Site": "same-origin"])
        XCTAssertEqual(poll.status, 200)
        XCTAssertEqual(server.usageState().lastUse, before, "a tab polling by itself")

        let presence = try rawHTTP(port: port, "POST", "/api/v1/presence", headers: [
            "Origin": "http://127.0.0.1:\(port)", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Site": "same-origin",
        ])
        XCTAssertEqual(presence.status, 200)
        XCTAssertGreaterThan(server.usageState().lastUse, before, "a hand on the page")
    }

    func testACommandFromTheCLIIsUse() throws {
        let before = server.usageState().lastUse
        Thread.sleep(forTimeInterval: 0.02)
        _ = try rawHTTP(port: port, "/api/v1/activity")
        XCTAssertGreaterThan(server.usageState().lastUse, before)
        XCTAssertFalse(server.usageState().busy, "nothing runs on its own")
    }
}
