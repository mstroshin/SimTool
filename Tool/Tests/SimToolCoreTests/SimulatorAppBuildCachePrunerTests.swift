import Foundation
import XCTest
@testable import SimToolCore

final class SimulatorAppBuildCachePrunerTests: XCTestCase {
    func testStaleEntriesGoAndOnlyWhenAsked() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent("project/.simtool"),
            derivedDataRoot: root.appendingPathComponent("Caches/SimTool/app-builds/DerivedData", isDirectory: true)
        )
        let now = Date()
        let workspace = root.appendingPathComponent("project/App.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let removedWorktree = root.appendingPathComponent("worktrees/gone/App.xcworkspace").path

        let live = try entry("live", in: cache, workspace: workspace.path, lastAccessed: now)
        let orphan = try entry("orphan", in: cache, workspace: removedWorktree, lastAccessed: now)
        let idle = try entry("idle", in: cache, workspace: workspace.path, lastAccessed: now.addingTimeInterval(-40 * 86_400))
        let unknown = try entry("unknown", in: cache, workspace: nil, lastAccessed: nil)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: unknown.path)
        let busy = try entry("busy", in: cache, workspace: removedWorktree, lastAccessed: now)
        try Data("stray".utf8).write(to: cache.derivedDataRoot.appendingPathComponent(".DS_Store"))
        let building = try await SimulatorAppBuildLock.acquire(paths: [busy.path], in: cache.lockRoot)
        defer { building.release() }

        // By default: entries whose workspace is gone, and not the one a build uses.
        let dryRun = SimulatorAppBuildCachePruner.prune(cache: cache, now: now)
        XCTAssertFalse(dryRun.deleted)
        XCTAssertEqual(dryRun.entries.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["busy", "idle", "live", "orphan", "unknown"])
        XCTAssertEqual(dryRun.removable.map(\.path), [orphan.path])
        XCTAssertEqual(dryRun.entries.first { $0.path == orphan.path }?.reason, "workspace gone")
        XCTAssertEqual(dryRun.entries.first { $0.path == busy.path }?.inUse, true)
        XCTAssertGreaterThan(dryRun.bytes, 0)
        XCTAssertEqual(dryRun.bytes, dryRun.entries.first { $0.path == orphan.path }?.bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), "a dry run removes nothing")

        // Unused for a while: xcodebuild's LastAccessedDate, else the directory's date.
        let aged = SimulatorAppBuildCachePruner.prune(cache: cache, olderThanDays: 30, now: now)
        XCTAssertEqual(Set(aged.removable.map(\.path)), [orphan.path, idle.path, unknown.path])
        XCTAssertEqual(aged.entries.first { $0.path == idle.path }?.reason, "unused for 40 days")
        XCTAssertEqual(aged.entries.first { $0.path == unknown.path }?.workspacePath, nil)

        XCTAssertEqual(Set(SimulatorAppBuildCachePruner.prune(cache: cache, all: true, now: now).removable.map(\.path)),
                       [live.path, orphan.path, idle.path, unknown.path])

        let pruned = SimulatorAppBuildCachePruner.prune(cache: cache, delete: true, now: now)
        XCTAssertTrue(pruned.deleted)
        XCTAssertEqual(pruned.entries.filter(\.deleted).map(\.path), [orphan.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: busy.path), "a build is using it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(SimulatorAppBuildLock.isHeld(path: orphan.path, in: cache.lockRoot), "the prune let go of what it removed")
    }

    func testAnEmptyOrMissingCacheHasNothingToPrune() {
        let cache = SimulatorAppBuildCache(
            simtoolDirectory: URL(fileURLWithPath: "/nonexistent/.simtool"),
            derivedDataRoot: URL(fileURLWithPath: "/nonexistent/DerivedData")
        )
        let payload = SimulatorAppBuildCachePruner.prune(cache: cache, delete: true)
        XCTAssertEqual(payload.entries, [])
        XCTAssertEqual(payload.bytes, 0)
    }

    /// A DerivedData directory as xcodebuild leaves it: an `info.plist`
    /// naming the workspace, and some products.
    private func entry(_ name: String, in cache: SimulatorAppBuildCache, workspace: String?, lastAccessed: Date?) throws -> URL {
        let url = cache.derivedDataRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("ModuleCache.noindex"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 10_000).write(to: url.appendingPathComponent("ModuleCache.noindex/Foundation.pcm"))
        var info: [String: Any] = [:]
        if let workspace { info["WorkspacePath"] = workspace }
        if let lastAccessed { info["LastAccessedDate"] = lastAccessed }
        if !info.isEmpty {
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("info.plist"))
        }
        return url
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
