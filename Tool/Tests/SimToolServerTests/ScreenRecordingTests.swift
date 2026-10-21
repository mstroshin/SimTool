import AVFoundation
import Foundation
import SimToolCore
@testable import SimToolServer
import XCTest

/// Writes a small mp4 where simctl would, or nothing at all.
private final class FakeRecorder: TestVideoRecorder, @unchecked Sendable {
    let masked: Bool
    let writes: Bool
    private(set) var started: URL?
    private(set) var stopped = false

    init(masked: Bool, writes: Bool = true) {
        self.masked = masked
        self.writes = writes
    }

    func start(deviceUDID: String, outputFile: URL) throws { started = outputFile }

    func stop() async {
        stopped = true
        if writes, let started { try? await VideoFixtures.writeTrailingGapVideo(to: started) }
    }
}

private final class Recorders: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeRecorder] = []
    var writes = true
    var all: [FakeRecorder] { lock.withLock { made } }
    func make(masked: Bool) -> FakeRecorder {
        let recorder = FakeRecorder(masked: masked, writes: writes)
        lock.withLock { made.append(recorder) }
        return recorder
    }
}

private final class Topics: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [RecordingTopicPayload] = []
    func append(_ payload: RecordingTopicPayload) { lock.withLock { sent.append(payload) } }
    var states: [String] { lock.withLock { sent.map { "\($0.current?.state.rawValue ?? "-")/\($0.last?.state.rawValue ?? "-")" } } }
}

final class ScreenRecordingControllerTests: XCTestCase {
    private var directory: URL!
    private let recorders = Recorders()
    private let topics = Topics()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController() -> ScreenRecordingController {
        let recorders = recorders, topics = topics
        return ScreenRecordingController(
            directory: directory,
            deviceUDID: "U",
            display: { "primary-1" },
            makeRecorder: { recorders.make(masked: $0) },
            onChange: { topics.append($0) }
        )
    }

    func testOneRecordingAtATimeSavedWhenStoppedAndOfferedToDownload() async throws {
        let controller = makeController()
        let started = try controller.start()
        XCTAssertEqual(started.state, .recording)
        XCTAssertEqual(started.display, "primary-1", "a foldable's recording names its lit panel")
        XCTAssertEqual(started.bezel, false)
        XCTAssertFalse(try XCTUnwrap(recorders.all.first).masked, "the screen alone is recorded unmasked, as a screenshot is")
        XCTAssertThrowsError(try controller.start()) { XCTAssertEqual($0 as? ScreenRecordingError, .alreadyRecording) }

        let saved = try await controller.stop()
        XCTAssertEqual(saved.state, .ready)
        XCTAssertEqual(saved.id, started.id)
        XCTAssertNotNil(saved.endedAt)
        XCTAssertGreaterThan(try XCTUnwrap(saved.byteCount), 0)
        XCTAssertEqual(try XCTUnwrap(saved.durationSeconds), 5.1, accuracy: 0.05, "the duration is aligned to the whole recording")
        let file = try controller.videoFile(id: saved.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(file.lastPathComponent, saved.id + ".mp4")
        XCTAssertEqual(topics.states, ["recording/-", "saving/-", "-/ready"], "every viewer hears each step")
        await assertThrowsAsync(try await controller.stop()) { XCTAssertEqual($0 as? ScreenRecordingError, .notRecording) }
    }

    func testARecordingForTheBezelIsMaskedAndFramedWhenSaved() async throws {
        let controller = makeController()
        let framed = Topics()
        _ = try controller.start { input, output in
            XCTAssertTrue(input.lastPathComponent.hasSuffix(".raw.mp4"))
            try FileManager.default.copyItem(at: input, to: output)
            framed.append(RecordingTopicPayload())
        }
        XCTAssertTrue(try XCTUnwrap(recorders.all.first).masked, "the glass is recorded for the bezel")
        let saved = try await controller.stop()
        XCTAssertEqual(saved.state, .ready)
        XCTAssertEqual(saved.bezel, true)
        XCTAssertEqual(framed.states.count, 1, "the bezel is put on once, when saving")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, [saved.id + ".mp4"], "the raw recording does not stay")
    }

    func testARecordingWithNoVideoFailsWithTheReason() async throws {
        recorders.writes = false
        let controller = makeController()
        _ = try controller.start()
        let saved = try await controller.stop()
        XCTAssertEqual(saved.state, .failed)
        XCTAssertNotNil(saved.error)
        XCTAssertThrowsError(try controller.videoFile(id: saved.id))
    }

    func testOnlyTheNewestRecordingIsKept() async throws {
        let controller = makeController()
        let first = try await { _ = try controller.start(); return try await controller.stop() }()
        _ = try controller.start()
        XCTAssertThrowsError(try controller.videoFile(id: first.id), "a new recording replaces the last")
        XCTAssertNil(controller.topic.last)
        await controller.shutdown()
        XCTAssertTrue(try XCTUnwrap(recorders.all.last).stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "the server's recordings go with it")
    }

    func testTheBezelGoesAroundEveryFrame() async throws {
        let input = directory.appendingPathComponent("in.mp4"), output = directory.appendingPathComponent("out.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await VideoFixtures.writeTrailingGapVideo(to: input)
        try await BezelVideo.frame(input: input, output: output) { pixels in
            XCTAssertEqual(pixels, CGSize(width: 64, height: 64))
            return DeviceBezel(screen: CGSize(width: 32, height: 32), cornerRadii: [4, 4, 4, 4], chrome: nil, searchRoots: [])
        }
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        // 32 pt + 18 pt a side at 2 px a point.
        XCTAssertEqual(size, CGSize(width: 136, height: 136))
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 5.1, accuracy: 0.1)
    }

    private func assertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, _ check: (Error) -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("expected an error", file: file, line: line)
        } catch {
            check(error)
        }
    }
}
