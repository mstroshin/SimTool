import Foundation
import XCTest
@testable import SimToolCore

final class SimToolDirectoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-dir-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLocateFindsExistingDirectoryUpTheTree() throws {
        let simtool = root.appendingPathComponent(".simtool", isDirectory: true)
        try FileManager.default.createDirectory(at: simtool, withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(SimToolDirectory.locate(startDirectory: nested)?.path, simtool.standardizedFileURL.path)
    }

    func testLocateReturnsNilWhenAbsent() throws {
        XCTAssertNil(SimToolDirectory.locate(startDirectory: root))
    }

    func testLocateIgnoresAFileNamedDotSimtool() throws {
        // A stray *file* named .simtool must not be mistaken for the directory.
        try Data().write(to: root.appendingPathComponent(".simtool"))
        XCTAssertNil(SimToolDirectory.locate(startDirectory: root))
    }

    func testResolveFallsBackToStartDirectory() throws {
        let resolved = SimToolDirectory.resolve(startDirectory: root)
        XCTAssertEqual(resolved.path, root.standardizedFileURL.appendingPathComponent(".simtool").path)
        // Fallback must not create anything on disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
    }

    func testEnsureCreatesDirectoryAndGitignore() throws {
        let simtool = root.appendingPathComponent(".simtool", isDirectory: true)
        try SimToolDirectory.ensure(simtool)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: simtool.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let gitignore = simtool.appendingPathComponent(".gitignore")
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "*\n")
    }

    func testEnsureKeepsExistingGitignore() throws {
        let simtool = root.appendingPathComponent(".simtool", isDirectory: true)
        try FileManager.default.createDirectory(at: simtool, withIntermediateDirectories: true)
        let gitignore = simtool.appendingPathComponent(".gitignore")
        try Data("custom\n".utf8).write(to: gitignore)

        try SimToolDirectory.ensure(simtool)
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "custom\n")
    }

    func testEnsureEnclosingCreatesNearestSimtoolAncestor() throws {
        let nested = root.appendingPathComponent(".simtool/build", isDirectory: true)
        try SimToolDirectory.ensureEnclosing(nested)

        let gitignore = root.appendingPathComponent(".simtool/.gitignore")
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "*\n")
    }

    func testEnsureEnclosingIsNoOpOutsideSimtool() throws {
        let plain = root.appendingPathComponent("artifacts", isDirectory: true)
        try SimToolDirectory.ensureEnclosing(plain)
        // Nothing is created: no .gitignore anywhere, no directory.
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))
    }

    func testWellKnownSubdirectories() {
        let simtool = URL(fileURLWithPath: "/proj/.simtool", isDirectory: true)
        XCTAssertEqual(SimToolDirectory.buildMetadataDirectory(in: simtool).path, "/proj/.simtool/build")
        XCTAssertEqual(SimToolDirectory.testSessionsDirectory(in: simtool).path, "/proj/.simtool/test-sessions")
    }
}
