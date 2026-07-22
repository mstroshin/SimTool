import Foundation
import XCTest
import SimToolCore
@testable import SimToolServer

private final class MockRecorder: TestVideoRecorder, @unchecked Sendable {
    enum Behavior { case ok, failToStart, breakSessionDirectory, copyFixture(URL) }
    let behavior: Behavior
    private(set) var startedUdid: String?
    private(set) var outputFile: URL?
    private let lock = NSLock()
    private var _stopped = false
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

    init(behavior: Behavior = .ok) { self.behavior = behavior }

    func start(deviceUDID: String, outputFile: URL) throws {
        if case .failToStart = behavior { throw SimToolError("simctl unavailable") }
        if case .breakSessionDirectory = behavior {
            // Replace the session directory with a file so the subsequent
            // store.write(session) fails after a successful recorder start.
            let directory = outputFile.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: directory)
            FileManager.default.createFile(atPath: directory.path, contents: Data())
            startedUdid = deviceUDID
            self.outputFile = outputFile
            return
        }
        startedUdid = deviceUDID
        self.outputFile = outputFile
        if case let .copyFixture(source) = behavior {
            try FileManager.default.copyItem(at: source, to: outputFile)
            return
        }
        // Simulate simctl creating the file in the (pre-created) session directory.
        try Data("fake video".utf8).write(to: outputFile)
    }

    func stop() async { lock.lock(); _stopped = true; lock.unlock() }
}

final class TestSessionControllerTests: XCTestCase {
    private var root: URL!
    private var store: TestSessionStore!
    private let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone 16 Pro", runtime: "iOS", state: "Booted", isAvailable: true)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-test-controller-\(UUID().uuidString)", isDirectory: true)
        store = TestSessionStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController(recorder: @escaping @Sendable () -> TestVideoRecorder = { MockRecorder() }) -> TestSessionController {
        TestSessionController(store: store, device: device, makeRecorder: recorder)
    }

    func testStartCreatesRunningSessionAndStartsRecorder() throws {
        let recorder = MockRecorder()
        let controller = makeController(recorder: { recorder })
        let session = try controller.start(title: "Verify preference editing")

        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.title, "Verify preference editing")
        XCTAssertEqual(session.deviceUdid, "TEST-UDID")
        XCTAssertNotNil(session.recordingStartedAt)
        XCTAssertNil(session.videoError)
        XCTAssertEqual(recorder.startedUdid, "TEST-UDID")
        XCTAssertEqual(recorder.outputFile, store.videoFile(for: session.id))
        // Persisted immediately.
        XCTAssertEqual(try store.session(id: session.id)?.status, .running)
    }

    func testSecondStartThrowsAlreadyActive() throws {
        let controller = makeController()
        let first = try controller.start(title: "First")
        XCTAssertThrowsError(try controller.start(title: "Second")) { error in
            XCTAssertEqual(error as? TestSessionError, .alreadyActive(id: first.id))
        }
    }

    func testStartWithoutVideoSkipsRecorderAndAllowsInterruptedStop() async throws {
        let recorder = MockRecorder()
        let controller = makeController(recorder: { recorder })
        let session = try controller.start(title: "No video, please", video: false)

        XCTAssertEqual(session.status, .running)
        XCTAssertNil(session.recordingStartedAt)
        XCTAssertNotNil(session.videoError)
        XCTAssertNil(recorder.startedUdid, "recorder must not be spawned when video is disabled")

        let stopped = try await controller.stop(status: .interrupted)
        XCTAssertEqual(stopped.status, .interrupted)
        XCTAssertFalse(recorder.stopped)
        XCTAssertEqual(try store.session(id: session.id)?.status, .interrupted)
    }

    func testRecorderSpawnFailureSetsVideoErrorButSessionRuns() throws {
        let controller = makeController(recorder: { MockRecorder(behavior: .failToStart) })
        let session = try controller.start(title: "No video")
        XCTAssertEqual(session.status, .running)
        XCTAssertNotNil(session.videoError)
        XCTAssertNil(session.recordingStartedAt)
        // Steps still work without a recorder.
        let updated = try controller.append(TestSessionEntryRequest(kind: .step, text: "Opened preferences"))
        XCTAssertEqual(updated.entries.count, 1)
    }

    func testAppendStepAndLogEntriesPersist() throws {
        let controller = makeController()
        let session = try controller.start(title: "Verify")
        _ = try controller.append(TestSessionEntryRequest(kind: .step, text: "Tapped Save", logs: ["[Settings] save OK"]))
        _ = try controller.append(TestSessionEntryRequest(kind: .log, logs: ["[Sync] cache refreshed"]))

        let stored = try XCTUnwrap(store.session(id: session.id))
        XCTAssertEqual(stored.entries.count, 2)
        XCTAssertEqual(stored.entries[0].kind, .step)
        XCTAssertEqual(stored.entries[0].text, "Tapped Save")
        XCTAssertEqual(stored.entries[0].logs, ["[Settings] save OK"])
        XCTAssertEqual(stored.entries[1].kind, .log)
        XCTAssertEqual(stored.entries[1].logs, ["[Sync] cache refreshed"])
    }

    func testAppendWithoutActiveSessionThrows() {
        let controller = makeController()
        XCTAssertThrowsError(try controller.append(TestSessionEntryRequest(kind: .step, text: "x"))) { error in
            XCTAssertEqual(error as? TestSessionError, .noActiveSession)
        }
    }

    func testEmptyEntriesAreRejected() throws {
        let controller = makeController()
        _ = try controller.start(title: "Verify")
        XCTAssertThrowsError(try controller.append(TestSessionEntryRequest(kind: .step, text: "   "))) { error in
            XCTAssertEqual(error as? TestSessionError, .emptyEntry)
        }
        XCTAssertThrowsError(try controller.append(TestSessionEntryRequest(kind: .log, logs: []))) { error in
            XCTAssertEqual(error as? TestSessionError, .emptyEntry)
        }
    }

    func testOversizedEntryIsRejected() throws {
        let controller = makeController()
        _ = try controller.start(title: "Verify")
        let huge = String(repeating: "x", count: TestSessionController.maxEntryBytes + 1)
        XCTAssertThrowsError(try controller.append(TestSessionEntryRequest(kind: .step, text: huge))) { error in
            XCTAssertEqual(error as? TestSessionError, .entryTooLarge(limitBytes: TestSessionController.maxEntryBytes))
        }
    }

    func testStopFinalizesSessionAndStopsRecorder() async throws {
        let recorder = MockRecorder()
        let controller = makeController(recorder: { recorder })
        let session = try controller.start(title: "Verify")
        let stopped = try await controller.stop(status: .passed)

        XCTAssertEqual(stopped.id, session.id)
        XCTAssertEqual(stopped.status, .passed)
        XCTAssertNotNil(stopped.endedAt)
        XCTAssertTrue(recorder.stopped)
        XCTAssertEqual(try store.session(id: session.id)?.status, .passed)
        // A new session can start afterwards.
        _ = try controller.start(title: "Next")
    }

    func testStopRejectsNonTerminalStatus() async throws {
        let controller = makeController()
        _ = try controller.start(title: "Verify")
        do {
            _ = try await controller.stop(status: .running)
            XCTFail("expected badStatus")
        } catch {
            XCTAssertEqual(error as? TestSessionError, .badStatus(.running))
        }
    }

    func testStopWithoutActiveSessionThrows() async {
        let controller = makeController()
        do {
            _ = try await controller.stop(status: .passed)
            XCTFail("expected noActiveSession")
        } catch {
            XCTAssertEqual(error as? TestSessionError, .noActiveSession)
        }
    }

    func testShutdownMarksActiveSessionInterrupted() async throws {
        let recorder = MockRecorder()
        let controller = makeController(recorder: { recorder })
        let session = try controller.start(title: "Verify")
        await controller.shutdown()

        XCTAssertTrue(recorder.stopped)
        XCTAssertEqual(try store.session(id: session.id)?.status, .interrupted)
    }

    func testFirstUseSweepsStaleRunningSessions() throws {
        // A previous server died with this session open.
        var stale = TestSession(
            id: "2026-06-12-0900-stale1", title: "Old", deviceUdid: "TEST-UDID",
            deviceName: "iPhone", startedAt: Date(timeIntervalSinceNow: -3600), status: .running
        )
        stale.entries.append(TestSessionEntry(kind: .step, at: Date(), text: "step"))
        try store.write(stale)

        let controller = makeController()
        let sessions = controller.list().sessions
        XCTAssertEqual(sessions.first?.id, "2026-06-12-0900-stale1")
        XCTAssertEqual(sessions.first?.status, .interrupted)
    }

    func testVideoFileChecks() async throws {
        let controller = makeController()
        // Unknown id.
        XCTAssertThrowsError(try controller.videoFile(id: "nope")) { error in
            XCTAssertEqual(error as? TestSessionError, .sessionNotFound(id: "nope"))
        }
        // Running session: still being written.
        let session = try controller.start(title: "Verify")
        XCTAssertThrowsError(try controller.videoFile(id: session.id)) { error in
            XCTAssertEqual(error as? TestSessionError, .videoNotReady(id: session.id))
        }
        // Finished with a file (MockRecorder wrote one): resolves.
        _ = try await controller.stop(status: .passed)
        XCTAssertEqual(try controller.videoFile(id: session.id), store.videoFile(for: session.id))
        // Finished but the file is gone.
        try FileManager.default.removeItem(at: store.videoFile(for: session.id))
        XCTAssertThrowsError(try controller.videoFile(id: session.id)) { error in
            XCTAssertEqual(error as? TestSessionError, .videoMissing(id: session.id))
        }
    }

    func testStartStopsRecorderWhenPersistFails() throws {
        let recorder = MockRecorder(behavior: .breakSessionDirectory)
        let controller = makeController(recorder: { recorder })
        XCTAssertThrowsError(try controller.start(title: "Doomed"))
        // The spawned recorder must not be left running.
        let stopped = expectation(description: "recorder stopped")
        Task {
            while !recorder.stopped { try? await Task.sleep(for: .milliseconds(10)) }
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
        // No active session remains: a fresh start succeeds once the path is usable.
        XCTAssertThrowsError(try controller.append(TestSessionEntryRequest(kind: .step, text: "x")))
    }

    func testStepUsesFirstInputTimeSincePreviousStep() throws {
        let controller = makeController()
        _ = try controller.start(title: "Verify")
        let firstInput = Date(timeIntervalSinceNow: -30)
        controller.noteInput(at: firstInput)
        // A multi-input action (e.g. several swipes): later inputs must not override.
        controller.noteInput(at: Date(timeIntervalSinceNow: -10))

        let session = try controller.append(TestSessionEntryRequest(kind: .step, text: "Scrolled to Learn"))

        XCTAssertEqual(session.entries[0].at, firstInput)
    }

    func testStepWithoutInputsFallsBackToAppendTime() throws {
        let controller = makeController()
        _ = try controller.start(title: "Verify")

        let session = try controller.append(TestSessionEntryRequest(kind: .step, text: "Waited for sync"))

        XCTAssertLessThan(abs(session.entries[0].at.timeIntervalSinceNow), 5)
    }

    func testInputMarkerResetsAfterEachStep() throws {
        let controller = makeController()
        _ = try controller.start(title: "Verify")
        let firstInput = Date(timeIntervalSinceNow: -30)
        controller.noteInput(at: firstInput)
        _ = try controller.append(TestSessionEntryRequest(kind: .step, text: "Tapped Settings"))

        let session = try controller.append(TestSessionEntryRequest(kind: .step, text: "No inputs in between"))

        XCTAssertLessThan(abs(session.entries[1].at.timeIntervalSinceNow), 5)
    }

    func testLogEntriesDoNotConsumeInputMarker() throws {
        let controller = makeController()
        _ = try controller.start(title: "Verify")
        let firstInput = Date(timeIntervalSinceNow: -30)
        controller.noteInput(at: firstInput)

        var session = try controller.append(TestSessionEntryRequest(kind: .log, logs: ["[Sync] cache refreshed"]))
        XCTAssertLessThan(abs(session.entries[0].at.timeIntervalSinceNow), 5)

        session = try controller.append(TestSessionEntryRequest(kind: .step, text: "Tapped Settings"))
        XCTAssertEqual(session.entries[1].at, firstInput)
    }

    func testNoteInputOutsideSessionIsIgnored() async throws {
        let controller = makeController()
        // Before any session.
        controller.noteInput(at: Date(timeIntervalSinceNow: -300))
        _ = try controller.start(title: "First")
        // Leaked from a previous session: stop without a step, then restart.
        controller.noteInput(at: Date(timeIntervalSinceNow: -200))
        _ = try await controller.stop(status: .passed)
        _ = try controller.start(title: "Second")

        let session = try controller.append(TestSessionEntryRequest(kind: .step, text: "Fresh step"))

        XCTAssertLessThan(abs(session.entries[0].at.timeIntervalSinceNow), 5)
    }

    /// A recording shaped like simctl output: the media duration stops well
    /// before the movie ends, hiding the trailing frames from browsers.
    private func makeTruncatedVideoFixture() async throws -> URL {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-truncated-\(UUID().uuidString).mp4")
        try await VideoFixtures.writeTrailingGapVideo(to: fixture)
        try VideoFixtures.patchMediaDuration(of: fixture, toSeconds: 1.0)
        let durations = try VideoFixtures.durations(of: fixture)
        XCTAssertGreaterThan(durations.movieSeconds - durations.mediaSeconds, 2.0)
        return fixture
    }

    func testStopNormalizesRecordedVideoDurations() async throws {
        let fixture = try await makeTruncatedVideoFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let controller = makeController(recorder: { MockRecorder(behavior: .copyFixture(fixture)) })
        let session = try controller.start(title: "Verify")

        _ = try await controller.stop(status: .passed)

        let durations = try VideoFixtures.durations(of: store.videoFile(for: session.id))
        XCTAssertGreaterThanOrEqual(durations.mediaSeconds, durations.movieSeconds - 0.1)
    }

    func testShutdownNormalizesRecordedVideoDurations() async throws {
        let fixture = try await makeTruncatedVideoFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let controller = makeController(recorder: { MockRecorder(behavior: .copyFixture(fixture)) })
        let session = try controller.start(title: "Verify")

        await controller.shutdown()

        let durations = try VideoFixtures.durations(of: store.videoFile(for: session.id))
        XCTAssertGreaterThanOrEqual(durations.mediaSeconds, durations.movieSeconds - 0.1)
    }

    func testStopRecordsFinalizedVideoDuration() async throws {
        let fixture = try await makeTruncatedVideoFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let controller = makeController(recorder: { MockRecorder(behavior: .copyFixture(fixture)) })
        let session = try controller.start(title: "Verify")

        let stopped = try await controller.stop(status: .passed)

        // The fixture spans ~5.1s; the timeline anchors step offsets to this.
        let duration = try XCTUnwrap(stopped.videoDurationSeconds)
        let expected = try VideoFixtures.durations(of: store.videoFile(for: session.id)).movieSeconds
        XCTAssertEqual(duration, expected, accuracy: 0.2)
        XCTAssertEqual(try store.session(id: session.id)?.videoDurationSeconds, duration)
    }

    func testStopWithoutRecorderLeavesVideoDurationNil() async throws {
        let controller = makeController(recorder: { MockRecorder(behavior: .failToStart) })
        _ = try controller.start(title: "No video")
        let stopped = try await controller.stop(status: .passed)
        XCTAssertNil(stopped.videoDurationSeconds)
    }

    func testShutdownRecordsFinalizedVideoDuration() async throws {
        let fixture = try await makeTruncatedVideoFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let controller = makeController(recorder: { MockRecorder(behavior: .copyFixture(fixture)) })
        let session = try controller.start(title: "Verify")

        await controller.shutdown()

        XCTAssertNotNil(try store.session(id: session.id)?.videoDurationSeconds)
    }

    func testVideoFileRejectsPathTraversalIds() {
        let controller = makeController()
        XCTAssertThrowsError(try controller.videoFile(id: "../escape")) { error in
            XCTAssertEqual(error as? TestSessionError, .sessionNotFound(id: "../escape"))
        }
    }

    func testDeleteRemovesSessionFilesFromDisk() async throws {
        let controller = makeController()
        let session = try controller.start(title: "Verify")
        _ = try await controller.stop(status: .passed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFile(for: session.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.videoFile(for: session.id).path))

        try controller.delete(id: session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: session.id).path))
        XCTAssertTrue(controller.list().sessions.isEmpty)
    }

    func testDeleteUnknownSessionThrows() {
        let controller = makeController()
        XCTAssertThrowsError(try controller.delete(id: "nope")) { error in
            XCTAssertEqual(error as? TestSessionError, .sessionNotFound(id: "nope"))
        }
    }

    func testDeleteRunningSessionIsRefused() throws {
        let controller = makeController()
        let session = try controller.start(title: "Verify")
        XCTAssertThrowsError(try controller.delete(id: session.id)) { error in
            XCTAssertEqual(error as? TestSessionError, .sessionRunning(id: session.id))
        }
        XCTAssertNotNil(try store.session(id: session.id))
    }

    func testDeleteRejectsPathTraversalIds() {
        let controller = makeController()
        XCTAssertThrowsError(try controller.delete(id: "../escape")) { error in
            XCTAssertEqual(error as? TestSessionError, .sessionNotFound(id: "../escape"))
        }
    }
}
