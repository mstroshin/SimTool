import Foundation
import XCTest
@testable import SimToolCore

final class SimulatorAppBuildLockTests: XCTestCase {
    func testASecondBuildOfTheSameDirectoryWaitsAndSaysForWhom() async throws {
        let locks = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: locks) }
        let first = try await SimulatorAppBuildLock.acquire(paths: ["/work/App/DerivedData"], in: locks, owner: "simtool test run")
        XCTAssertTrue(SimulatorAppBuildLock.isHeld(path: "/work/App/DerivedData", in: locks))

        let messages = MessageLog()
        let waiting = expectation(description: "the second build waits")
        let acquired = MessageLog()
        let second = Task {
            let lock = try await SimulatorAppBuildLock.acquire(paths: ["/work/App/DerivedData"], in: locks, owner: "simtool run") { message in
                messages.append(message)
                waiting.fulfill()
            }
            acquired.append("acquired")
            return lock
        }
        await fulfillment(of: [waiting], timeout: 5)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(acquired.all, [], "not while the first holds it")
        let message = try XCTUnwrap(messages.all.first)
        XCTAssertTrue(message.contains("/work/App/DerivedData"), message)
        XCTAssertTrue(message.contains("simtool test run, pid \(getpid())"), message)

        first.release()
        let lock = try await second.value
        XCTAssertEqual(acquired.all, ["acquired"])
        XCTAssertTrue(SimulatorAppBuildLock.isHeld(path: "/work/App/DerivedData", in: locks))
        lock.release()
        XCTAssertFalse(SimulatorAppBuildLock.isHeld(path: "/work/App/DerivedData", in: locks))
        first.release()
    }

    func testBuildsOfOtherDirectoriesDoNotWait() async throws {
        let locks = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: locks) }
        let first = try await SimulatorAppBuildLock.acquire(paths: ["/work/A", "/work/A/DerivedData"], in: locks)
        let second = try await SimulatorAppBuildLock.acquire(paths: ["/work/B", "/work/B/DerivedData"], in: locks) { message in
            XCTFail("waited: \(message)")
        }
        second.release()
        first.release()
        XCTAssertFalse(SimulatorAppBuildLock.isHeld(path: "/work/A", in: locks))
        XCTAssertFalse(SimulatorAppBuildLock.isHeld(path: "/never/locked", in: locks))
    }

    // A build that dies never leaves its lock behind: the kernel drops it.
    func testALockDiesWithItsProcess() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"), "perl not available")
        let locks = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: locks) }
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let file = SimulatorAppBuildLock.lockFile(for: "/work/App", in: locks)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", "use Fcntl ':flock'; open(F, '>>', $ARGV[0]) or die; flock(F, LOCK_EX) or die; print \"locked\\n\"; $| = 1; sleep 30", file.path]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        _ = output.fileHandleForReading.availableData // "locked"
        XCTAssertTrue(SimulatorAppBuildLock.isHeld(path: "/work/App", in: locks))
        holder.terminate()
        holder.waitUntilExit()
        let lock = try await SimulatorAppBuildLock.acquire(paths: ["/work/App"], in: locks) { message in
            XCTFail("waited for a dead process: \(message)")
        }
        lock.release()
    }

    // `test run` and `run` started together both miss the cache; the one
    // that waited reuses what the other built of the same sources.
    func testABuildThatWaitedReusesWhatTheOtherBuilt() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("project".utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("managed/DerivedData", isDirectory: true)
        )
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let plan = try SimulatorAppLifecycleClient.plan(selection: selection, cache: cache)
        XCTAssertFalse(plan.isCacheHit)

        let other = try await SimulatorAppBuildLock.acquire(paths: [selection.projectRoot.standardizedFileURL.path], in: cache.lockRoot)
        let waiting = expectation(description: "the build waits for the other one")
        let build = Task {
            try await SimulatorAppLifecycleClient.build(plan: plan, cache: cache) { message in
                if message.hasPrefix("Waiting for another build") { waiting.fulfill() }
            }
        }
        await fulfillment(of: [waiting], timeout: 5)
        // The other build finishes: these sources, built.
        let app = root.appendingPathComponent("Products/Debug-iphonesimulator/Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try cache.write(SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: plan.fingerprint.checksum,
            inputFileCount: plan.fingerprint.inputFileCount,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app",
            product: SimulatorAppProductStamp(appBundleURL: app)
        ))
        other.release()

        // No xcodebuild ran — this project could not have built.
        let payload = try await build.value
        XCTAssertTrue(payload.cacheHit)
        XCTAssertFalse(payload.xcodebuildRan)
        XCTAssertEqual(payload.appBundlePath, app.path)
        XCTAssertFalse(SimulatorAppBuildLock.isHeld(path: selection.projectRoot.standardizedFileURL.path, in: cache.lockRoot), "released")
    }

    func testTheLockRootSitsBesideTheManagedDerivedData() {
        let cache = SimulatorAppBuildCache(
            simtoolDirectory: URL(fileURLWithPath: "/work/App/.simtool"),
            derivedDataRoot: URL(fileURLWithPath: "/Caches/SimTool/app-builds/DerivedData")
        )
        XCTAssertEqual(cache.lockRoot.path, "/Caches/SimTool/app-builds/locks")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
