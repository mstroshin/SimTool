import XCTest
@testable import SimToolCore

final class SessionReaperTests: XCTestCase {
    private func device(_ udid: String) -> SimulatorDevice {
        SimulatorDevice(udid: udid, name: "iPhone", runtime: "iOS-18-0", state: "Booted", isAvailable: true)
    }

    private func session(_ id: String, pid: Int32, booted: [String]) -> SessionInfo {
        SessionInfo(
            sessionId: id,
            pid: pid,
            device: device(booted.first ?? "X"),
            url: "http://127.0.0.1:3200",
            api: "http://127.0.0.1:3200/api/v1",
            startedAt: Date(timeIntervalSince1970: 0),
            bootedDevices: booted
        )
    }

    // MARK: - Whether a session's server is still running

    // A session file outlives its server, and the PID may belong to another
    // process by now — one that started after the session did.
    func testASessionIsServingOnlyWhileItsOwnProcessRuns() {
        let mine = SessionInfo(sessionId: "s", pid: getpid(), device: device("A"), url: "", api: "", startedAt: Date())
        XCTAssertTrue(mine.isServing)
        var reused = mine
        reused.startedAt = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(reused.isServing, "this process started long after that session")
        var gone = mine
        gone.pid = Int32.max
        XCTAssertFalse(gone.isServing)
        XCTAssertNotNil(SessionInfo.startTime(pid: getpid()))
        XCTAssertNil(SessionInfo.startTime(pid: Int32.max))
    }

    // MARK: - SessionInfo persistence

    func testSessionInfoRoundTripsBootedDevices() throws {
        let original = session("s1", pid: 100, booted: ["A", "B"])
        let data = try JSON.data(original)
        let decoded = try JSON.decoder.decode(SessionInfo.self, from: data)
        XCTAssertEqual(decoded.bootedDevices, ["A", "B"])
    }

    func testSessionInfoDecodesLegacyJSONWithoutBootedDevices() throws {
        // A session file written by an older SimTool has no bootedDevices key.
        let legacy = #"""
        {
          "sessionId": "old",
          "pid": 42,
          "device": { "udid": "A", "name": "iPhone", "runtime": "iOS-18-0", "state": "Booted", "isAvailable": true },
          "url": "http://127.0.0.1:3200",
          "api": "http://127.0.0.1:3200/api/v1",
          "startedAt": "2026-01-01T00:00:00Z"
        }
        """#.data(using: .utf8)!
        let decoded = try JSON.decoder.decode(SessionInfo.self, from: legacy)
        XCTAssertEqual(decoded.bootedDevices, [])
    }

    // MARK: - Reaper selection

    func testReapsBootedDevicesOfDeadSessions() {
        let dead = [session("s1", pid: 100, booted: ["A", "B"])]
        XCTAssertEqual(SessionReaper.devicesToReap(dead: dead, live: []), ["A", "B"])
    }

    func testDoesNotReapDeviceStillClaimedByALiveSession() {
        let dead = [session("s1", pid: 100, booted: ["A", "B"])]
        let live = [session("s2", pid: 200, booted: ["A"])]
        // A is still in use by a live session; only B is safe to shut down.
        XCTAssertEqual(SessionReaper.devicesToReap(dead: dead, live: live), ["B"])
    }

    func testDeduplicatesAcrossMultipleDeadSessions() {
        let dead = [
            session("s1", pid: 100, booted: ["A", "B"]),
            session("s2", pid: 101, booted: ["B", "C"]),
        ]
        XCTAssertEqual(SessionReaper.devicesToReap(dead: dead, live: []), ["A", "B", "C"])
    }

    func testReturnsEmptyWhenNoDeadSessionsBootedAnything() {
        let dead = [session("s1", pid: 100, booted: [])]
        XCTAssertEqual(SessionReaper.devicesToReap(dead: dead, live: []), [])
    }
}
