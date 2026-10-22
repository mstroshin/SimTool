import Foundation
import XCTest
@testable import SimToolCore

final class SimulatorAppInputHashCacheTests: XCTestCase {
    func testTheCacheSkipsReadsButNeverChangesTheChecksum() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let hashes = root.appendingPathComponent(".simtool/build/input-hashes.tsv")

        let plain = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        XCTAssertEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, hashCache: hashes), plain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hashes.path))
        XCTAssertEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, hashCache: hashes), plain)

        // A recorded hash is used, not re-read: a planted one shows through.
        let source = root.appendingPathComponent("Sources/App.swift")
        var planted = SimulatorAppInputHashCache()
        let status = try XCTUnwrap(SimulatorAppInputHashCache.Status(path: source.path))
        planted.record(source.path, status: status, hash: "planted")
        planted.writtenAt = Date().addingTimeInterval(60)
        planted.write(to: hashes)
        XCTAssertNotEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, hashCache: hashes), plain)
        // …and the fingerprint replaced it with the real one.
        XCTAssertEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, hashCache: hashes), plain)
    }

    // Content rewritten with the same size and its old modification time
    // restored still changes the change time, which no tool can set back.
    func testAFileRewrittenBehindItsTimestampsIsReadAgain() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        let source = root.appendingPathComponent("Sources/App.swift")
        try write("Sources/App.swift", contents: "let a = 1", root: root)
        let old = Date(timeIntervalSinceNow: -3_600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: source.path)
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let hashes = root.appendingPathComponent(".simtool/build/input-hashes.tsv")
        // Taken well after the file's last change, so the hash is trusted.
        var cache = SimulatorAppInputHashCache.load(from: hashes)
        XCTAssertNil(cache.writtenAt, "no cache yet")
        let before = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, hashCache: hashes)
        cache = SimulatorAppInputHashCache.load(from: hashes)
        cache.writtenAt = Date().addingTimeInterval(60)
        cache.write(to: hashes)

        try write("Sources/App.swift", contents: "let b = 2", root: root)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: source.path)
        XCTAssertNotEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, hashCache: hashes).checksum, before.checksum)
    }

    func testAHashTakenAsTheFileChangedIsNotTrusted() {
        let now = Date()
        let nanos = Int64(now.timeIntervalSince1970 * 1_000_000_000)
        let settled = SimulatorAppInputHashCache.Status(size: 10, modified: nanos - 10_000_000_000, changed: nanos - 10_000_000_000, inode: 7)
        let racy = SimulatorAppInputHashCache.Status(size: 10, modified: nanos - 500_000_000, changed: nanos - 500_000_000, inode: 8)
        var cache = SimulatorAppInputHashCache()
        cache.record("/p/settled.swift", status: settled, hash: "a")
        cache.record("/p/racy.swift", status: racy, hash: "b")
        cache.writtenAt = now
        XCTAssertEqual(cache.hash(of: "/p/settled.swift", status: settled), "a")
        XCTAssertNil(cache.hash(of: "/p/racy.swift", status: racy), "changed within the window: maybe twice in one tick")
        var moved = settled
        moved.inode = 9
        XCTAssertNil(cache.hash(of: "/p/settled.swift", status: moved), "another file now")
        XCTAssertNil(cache.hash(of: "/p/unknown.swift", status: settled))
    }

    func testTheCacheFileRoundTripsAndToleratesDamage() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".simtool/build/input-hashes.tsv")
        let status = SimulatorAppInputHashCache.Status(size: 3, modified: 1_000, changed: 2_000, inode: 42)
        var cache = SimulatorAppInputHashCache()
        cache.record("/p/With\tTab/File.swift", status: status, hash: "h1")
        cache.writtenAt = Date(timeIntervalSince1970: 1_800_000_000.5)
        cache.write(to: url)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".simtool/.gitignore"), encoding: .utf8), "*\n")

        let loaded = SimulatorAppInputHashCache.load(from: url)
        XCTAssertEqual(loaded.writtenAt, cache.writtenAt)
        XCTAssertEqual(loaded.hash(of: "/p/With\tTab/File.swift", status: status), "h1")

        try Data("garbage\nnot\ta\tcache\n".utf8).write(to: url)
        XCTAssertNil(SimulatorAppInputHashCache.load(from: url).writtenAt)
        XCTAssertNil(SimulatorAppInputHashCache.load(from: root.appendingPathComponent("missing.tsv")).writtenAt)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ relativePath: String, contents: String, root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
