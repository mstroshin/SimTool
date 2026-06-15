import Foundation
import XCTest
@testable import SimToolCore

final class TestSessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-test-sessions-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> TestSessionStore { TestSessionStore(root: root) }

    private func makeSession(
        id: String = "2026-06-12-1430-abc123",
        status: TestSessionStatus = .running,
        startedAt: Date = Date()
    ) -> TestSession {
        TestSession(
            id: id,
            title: "Verify preference editing",
            deviceUdid: "TEST-UDID",
            deviceName: "iPhone 16 Pro",
            startedAt: startedAt,
            status: status
        )
    }

    func testMakeIdHasSortableDatePrefixAndRandomSuffix() {
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone.current,
            year: 2026, month: 6, day: 12, hour: 14, minute: 30
        )
        let id = TestSessionStore.makeId(now: components.date!)
        XCTAssertTrue(id.hasPrefix("2026-06-12-1430-"), "unexpected id: \(id)")
        XCTAssertEqual(id.count, "2026-06-12-1430-".count + 6)
        XCTAssertNotEqual(TestSessionStore.makeId(), TestSessionStore.makeId(), "suffix must be random")
    }

    func testWriteAndReadRoundTrip() throws {
        let store = makeStore()
        var session = makeSession()
        session.entries.append(TestSessionEntry(kind: .step, at: Date(), text: "Opened preferences"))
        session.entries.append(TestSessionEntry(kind: .log, at: Date(), logs: ["[Sync] cache refreshed"]))
        try store.write(session)

        let loaded = try XCTUnwrap(store.session(id: session.id))
        XCTAssertEqual(loaded.title, "Verify preference editing")
        XCTAssertEqual(loaded.status, .running)
        XCTAssertEqual(loaded.entries.count, 2)
        XCTAssertEqual(loaded.entries[0].kind, .step)
        XCTAssertEqual(loaded.entries[0].text, "Opened preferences")
        XCTAssertEqual(loaded.entries[1].logs, ["[Sync] cache refreshed"])
        // Files live in the spec'd per-session layout.
        XCTAssertEqual(store.sessionFile(for: session.id).lastPathComponent, "session.json")
        XCTAssertEqual(store.videoFile(for: session.id).lastPathComponent, "video.mp4")
        XCTAssertEqual(store.videoFile(for: session.id).deletingLastPathComponent(), store.directory(for: session.id))
    }

    func testListIsNewestFirstAndSkipsCorruptSessions() throws {
        let store = makeStore()
        try store.write(makeSession(id: "2026-06-12-1000-aaaaaa", startedAt: Date(timeIntervalSinceNow: -3600)))
        try store.write(makeSession(id: "2026-06-12-1100-bbbbbb", startedAt: Date()))
        // A corrupt directory must not break the list.
        let corrupt = store.directory(for: "2026-06-12-1050-cccccc")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: corrupt.appendingPathComponent("session.json"))

        let sessions = store.list()
        XCTAssertEqual(sessions.map(\.id), ["2026-06-12-1100-bbbbbb", "2026-06-12-1000-aaaaaa"])
    }

    func testListOnMissingRootIsEmpty() {
        XCTAssertEqual(makeStore().list(), [])
    }

    func testMarkInterruptedFlagsStaleRunningSessions() throws {
        let store = makeStore()
        try store.write(makeSession(id: "2026-06-12-1000-aaaaaa", status: .running))
        try store.write(makeSession(id: "2026-06-12-1100-bbbbbb", status: .passed))
        try store.write(makeSession(id: "2026-06-12-1200-cccccc", status: .running))

        let marked = store.markInterrupted(except: "2026-06-12-1200-cccccc")
        XCTAssertEqual(marked, ["2026-06-12-1000-aaaaaa"])
        XCTAssertEqual(try store.session(id: "2026-06-12-1000-aaaaaa")?.status, .interrupted)
        XCTAssertNotNil(try store.session(id: "2026-06-12-1000-aaaaaa")?.endedAt)
        XCTAssertEqual(try store.session(id: "2026-06-12-1100-bbbbbb")?.status, .passed)
        XCTAssertEqual(try store.session(id: "2026-06-12-1200-cccccc")?.status, .running)
    }

    func testWriteInsideSimtoolDirectoryCreatesGitignore() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let simtoolDir = projectRoot.appendingPathComponent(".simtool", isDirectory: true)
        let store = TestSessionStore(root: SimToolDirectory.testSessionsDirectory(in: simtoolDir))

        let session = TestSession(
            id: TestSessionStore.makeId(),
            title: "t",
            deviceUdid: "UDID",
            deviceName: "iPhone 16 Pro",
            startedAt: Date(),
            status: .running
        )
        try store.write(session)

        XCTAssertEqual(
            try String(contentsOf: simtoolDir.appendingPathComponent(".gitignore"), encoding: .utf8),
            "*\n"
        )
    }

    func testPayloadJSONShape() throws {
        var session = makeSession()
        session.videoError = nil
        let json = try JSON.string(TestSessionListPayload(sessions: [session]), pretty: false)
        XCTAssertTrue(json.contains("\"sessions\""))
        XCTAssertTrue(json.contains("\"status\":\"running\""))
        XCTAssertTrue(json.contains("\"deviceName\":\"iPhone 16 Pro\""))
        // Optional fields are omitted, not null.
        XCTAssertFalse(json.contains("\"videoError\""))
        XCTAssertFalse(json.contains("\"endedAt\""))
    }
}
