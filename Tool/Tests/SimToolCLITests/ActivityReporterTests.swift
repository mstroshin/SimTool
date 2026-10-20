import Foundation
@testable import SimToolCLI
@testable import SimToolCore
import XCTest

final class ActivityReporterTests: XCTestCase {
    private func session(_ id: String, udid: String, pid: Int32, api: String) -> SessionInfo {
        SessionInfo(
            sessionId: id,
            pid: pid,
            device: SimulatorDevice(udid: udid, name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true),
            url: api.replacingOccurrences(of: "/api/v1", with: ""),
            api: api,
            startedAt: Date()
        )
    }

    // Any live server streaming the device shows it, whichever project started it.
    func testReportsGoToEveryLiveServerOnTheDeviceOnce() {
        let sessions = [
            session("a", udid: "SIM-1", pid: 10, api: "http://127.0.0.1:3200/api/v1"),
            session("b", udid: "SIM-2", pid: 11, api: "http://127.0.0.1:3201/api/v1"),
            session("c", udid: "SIM-1", pid: 12, api: "http://127.0.0.1:3313/api/v1"),
            session("d", udid: "SIM-1", pid: 13, api: "http://127.0.0.1:3314/api/v1"),
            session("e", udid: "SIM-1", pid: 14, api: "http://127.0.0.1:3200/api/v1"),
        ]
        let servers = ActivityReporter.servers(watching: "SIM-1", among: sessions, isAlive: { $0 != 13 })
        XCTAssertEqual(servers.map(\.absoluteString), ["http://127.0.0.1:3200/api/v1", "http://127.0.0.1:3313/api/v1"])
    }

    func testWithNoServerWatchingTheCommandJustRuns() async throws {
        let reporter = ActivityReporter(device: SimulatorDevice(udid: "SIM-9", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true), sessions: [], isAlive: { _ in true })
        XCTAssertTrue(reporter.servers.isEmpty)
        let output = try await reporter.command(SimulatorInputPayload(action: "shake")) { ProcessOutput(status: 0, stdout: Data("ok".utf8)) }
        XCTAssertEqual(output.stdoutString, "ok")
    }
}
