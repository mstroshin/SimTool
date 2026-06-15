import Foundation
import XCTest
@testable import SimToolServer

final class VideoDurationNormalizerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-video-normalizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNormalizeMakesMediaDurationCoverTheMovie() async throws {
        let file = directory.appendingPathComponent("video.mp4")
        try await VideoFixtures.writeTrailingGapVideo(to: file)
        try VideoFixtures.patchMediaDuration(of: file, toSeconds: 1.0)
        let before = try VideoFixtures.durations(of: file)
        // The simctl bug shape: the media duration (what browsers report) stops
        // well before the movie ends, so trailing frames are unreachable.
        XCTAssertGreaterThan(before.movieSeconds - before.mediaSeconds, 2.0)

        try await VideoDurationNormalizer.normalize(file: file)

        let after = try VideoFixtures.durations(of: file)
        XCTAssertGreaterThanOrEqual(after.mediaSeconds, after.movieSeconds - 0.1)
        XCTAssertEqual(after.movieSeconds, before.movieSeconds, accuracy: 0.1)
        XCTAssertEqual(after.sampleCount, before.sampleCount)
    }

    func testNormalizeFailsOnInvalidFileAndKeepsItIntact() async throws {
        let file = directory.appendingPathComponent("video.mp4")
        let original = Data("not a video".utf8)
        try original.write(to: file)

        do {
            try await VideoDurationNormalizer.normalize(file: file)
            XCTFail("expected normalize to throw on a non-mp4 file")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
