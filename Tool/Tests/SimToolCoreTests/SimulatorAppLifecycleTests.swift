import Foundation
import XCTest
@testable import SimToolCore

final class SimulatorAppLifecycleTests: XCTestCase {
    func testBuildSelectionValidationAndXcodebuildArguments() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: nil, scheme: "App"))
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: workspace.path, projectPath: "Example.xcodeproj", scheme: "App"))
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: workspace.path, projectPath: nil, scheme: nil))

        // Nonexistent paths fail fast: fingerprinting a selection whose parent
        // resolves to "/" would otherwise hash the entire filesystem.
        let missingWorkspace = root.appendingPathComponent("Missing.xcworkspace").path
        let missingProject = root.appendingPathComponent("Missing.xcodeproj").path
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: missingWorkspace, projectPath: nil, scheme: "App")) { error in
            XCTAssertTrue("\(error)".contains("Missing.xcworkspace"))
        }
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: missingProject, scheme: "App")) { error in
            XCTAssertTrue("\(error)".contains("Missing.xcodeproj"))
        }

        let selection = try SimulatorAppBuildSelection.validated(
            workspacePath: workspace.path,
            projectPath: nil,
            scheme: "Example",
            configuration: nil,
            derivedDataPath: root.appendingPathComponent("DerivedData", isDirectory: true).path
        )

        XCTAssertEqual(selection.identity.configuration, "Debug")
        let arguments = SimulatorAppLifecycleClient.xcodebuildArguments(selection: selection, derivedDataPath: selection.identity.derivedDataPath)
        XCTAssertEqual(arguments, [
            "xcodebuild",
            "-workspace", workspace.path,
            "-scheme", "Example",
            "-configuration", "Debug",
            "-sdk", "iphonesimulator",
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", selection.identity.derivedDataPath!,
            "build",
        ])
    }

    func testFingerprintIsDeterministicChangesWithInputsAndSeparatesSchemes() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)

        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let first = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        let second = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.inputFileCount, 2)

        try write("Sources/App.swift", contents: "struct App { let value = 1 }", root: root)
        let changed = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        XCTAssertNotEqual(first.checksum, changed.checksum)

        let otherScheme = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Other")
        let otherSchemeFingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: otherScheme)
        XCTAssertNotEqual(changed.checksum, otherSchemeFingerprint.checksum)
    }

    func testFingerprintInGitRepoIgnoresGitIgnoredFilesButTracksSource() throws {
        try XCTSkipUnless(gitIsAvailable(), "git not available")
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        // A generated, gitignored project file (e.g. a Tuist-managed pbxproj that
        // xcodebuild rewrites on every build) plus a tracked source file.
        try write("Example.xcodeproj/project.pbxproj", contents: "objects v1", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)
        try write(".gitignore", contents: "*.xcodeproj\n", root: root)
        runGit(["init"], in: root)
        runGit(["add", "-A"], in: root)

        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let before = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)

        // Mutating the gitignored generated file must NOT change the checksum —
        // this is exactly what broke cache reuse on Tuist projects.
        try write("Example.xcodeproj/project.pbxproj", contents: "objects v2 CHANGED BY BUILD", root: root)
        let afterIgnoredChange = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        XCTAssertEqual(before.checksum, afterIgnoredChange.checksum, "gitignored generated files must not affect the source checksum")

        // Mutating a tracked source file MUST change the checksum.
        try write("Sources/App.swift", contents: "struct App { let value = 1 }", root: root)
        let afterTrackedChange = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        XCTAssertNotEqual(before.checksum, afterTrackedChange.checksum, "tracked source changes must change the checksum")
    }

    // What a test run asks before it records anything: is the build on the
    // device the one we are about to judge?
    func testInstallIsNeededOnlyWhenTheDeviceHasSomethingElse() {
        let record = SimulatorAppInstallRecord(
            deviceUDID: "UDID",
            checksum: "abc",
            bundleIdentifier: "com.example.app"
        )

        XCTAssertFalse(SimulatorAppLifecycleClient.needsInstall(
            checksum: "abc", bundleIdentifier: "com.example.app", installed: record, xcodebuildRan: false, force: false
        ))
        XCTAssertTrue(SimulatorAppLifecycleClient.needsInstall(
            checksum: "def", bundleIdentifier: "com.example.app", installed: record, xcodebuildRan: false, force: false
        ), "a changed checksum is a different build")
        XCTAssertTrue(SimulatorAppLifecycleClient.needsInstall(
            checksum: "abc", bundleIdentifier: "com.example.other", installed: record, xcodebuildRan: false, force: false
        ), "a different bundle id is a different app")
        XCTAssertTrue(SimulatorAppLifecycleClient.needsInstall(
            checksum: "abc", bundleIdentifier: "com.example.app", installed: record, xcodebuildRan: true, force: false
        ), "a fresh xcodebuild means the bundle on the device is stale")
        XCTAssertTrue(SimulatorAppLifecycleClient.needsInstall(
            checksum: "abc", bundleIdentifier: "com.example.app", installed: SimulatorAppInstallRecord?.none, xcodebuildRan: false, force: false
        ), "nothing recorded means nothing installed")
        XCTAssertTrue(SimulatorAppLifecycleClient.needsInstall(
            checksum: "abc", bundleIdentifier: "com.example.app", installed: record, xcodebuildRan: false, force: true
        ))
    }

    func testCacheMetadataReadWriteValidationCorruptMissesAndInstallRecords() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let simtoolDir = root.appendingPathComponent(".simtool", isDirectory: true)
        let cache = SimulatorAppBuildCache(
            simtoolDirectory: simtoolDir,
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Build/Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let metadata = SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: "abc",
            inputFileCount: 2,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app"
        )

        try cache.write(metadata)
        // Metadata lands in `.simtool/build/<identityKey>.json`, and writing
        // creates the self-ignoring .gitignore.
        XCTAssertTrue(
            try cache.metadataURL(for: selection.identity).path
                .hasPrefix(simtoolDir.appendingPathComponent("build").path)
        )
        XCTAssertEqual(
            try String(contentsOf: simtoolDir.appendingPathComponent(".gitignore"), encoding: .utf8),
            "*\n"
        )
        let read = try XCTUnwrap(cache.readMetadata(for: selection.identity))
        XCTAssertEqual(read.identity, metadata.identity)
        XCTAssertEqual(read.checksum, metadata.checksum)
        XCTAssertEqual(read.appBundlePath, metadata.appBundlePath)
        XCTAssertEqual(read.bundleIdentifier, metadata.bundleIdentifier)
        XCTAssertEqual(cache.validMetadata(for: selection.identity, checksum: "abc")?.checksum, "abc")

        try cache.recordInstall(identity: selection.identity, checksum: "abc", bundleIdentifier: "com.example.app", deviceUDID: "DEVICE")
        let updated = try XCTUnwrap(cache.readMetadata(for: selection.identity))
        XCTAssertEqual(updated.installRecords["DEVICE"]?.checksum, "abc")

        try FileManager.default.removeItem(at: app)
        XCTAssertNil(cache.validMetadata(for: selection.identity, checksum: "abc"))

        let url = try cache.metadataURL(for: selection.identity)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(cache.readMetadata(for: selection.identity))
    }

    func testBundleIdentifierDiscovery() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.app"],
            format: .xml,
            options: 0
        )
        try plist.write(to: app.appendingPathComponent("Info.plist"))

        XCTAssertEqual(try SimulatorAppLifecycleClient.bundleIdentifier(appBundleURL: app), "com.example.app")

        let missing = root.appendingPathComponent("Missing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let missingPlist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Missing"], format: .xml, options: 0)
        try missingPlist.write(to: missing.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try SimulatorAppLifecycleClient.bundleIdentifier(appBundleURL: missing)) { error in
            XCTAssertTrue(error.localizedDescription.contains(missing.path))
        }
    }

    func testRecordExternalBuildWritesCacheHitMetadataAndPrunesStaleInstalls() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)

        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")

        // The external .app lives under Build/, which the fingerprinter excludes,
        // so its Info.plist never perturbs the source checksum.
        let app = root.appendingPathComponent("Build/Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))

        // A pre-existing install record for a different checksum must be pruned.
        try cache.write(SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: "stale",
            inputFileCount: 0,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app",
            installRecords: ["DEVICE": SimulatorAppInstallRecord(deviceUDID: "DEVICE", checksum: "stale", bundleIdentifier: "com.example.app")]
        ))

        let expected = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, cacheRoot: cache.derivedDataRoot)
        let payload = try SimulatorAppLifecycleClient.recordExternalBuild(selection: selection, appBundleURL: app, cache: cache)

        XCTAssertEqual(payload.checksum, expected.checksum)
        XCTAssertEqual(payload.bundleIdentifier, "com.example.app")
        XCTAssertFalse(payload.cacheHit)
        XCTAssertFalse(payload.xcodebuildRan)

        // run's cache-hit predicate now matches the recorded checksum, and the
        // stale install record is gone.
        let valid = try XCTUnwrap(cache.validMetadata(for: selection.identity, checksum: expected.checksum))
        XCTAssertEqual(valid.appBundlePath, app.standardizedFileURL.path)
        XCTAssertTrue(valid.installRecords.isEmpty)

        // A missing bundle is a hard error.
        try FileManager.default.removeItem(at: app)
        XCTAssertThrowsError(try SimulatorAppLifecycleClient.recordExternalBuild(selection: selection, appBundleURL: app, cache: cache))
    }

    func testPlanDetectsCacheHitAndBuildFromPlanReusesWithoutXcodebuild() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)

        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let app = root.appendingPathComponent("Build/Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, cacheRoot: cache.derivedDataRoot)
        try cache.write(SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app"
        ))

        // Planning is the checksum stage: it fingerprints sources and resolves
        // the cache, without touching xcodebuild.
        let plan = try SimulatorAppLifecycleClient.plan(selection: selection, cache: cache)
        XCTAssertEqual(plan.fingerprint.checksum, fingerprint.checksum)
        XCTAssertTrue(plan.isCacheHit)
        XCTAssertEqual(plan.cachedMetadata?.appBundlePath, app.path)

        // Building from a cache-hit plan reuses the bundle, never running xcodebuild.
        let payload = try await SimulatorAppLifecycleClient.build(plan: plan, cache: cache)
        XCTAssertTrue(payload.cacheHit)
        XCTAssertFalse(payload.xcodebuildRan)
        XCTAssertEqual(payload.appBundlePath, app.path)
        XCTAssertEqual(payload.bundleIdentifier, "com.example.app")
        XCTAssertEqual(payload.checksum, fingerprint.checksum)
    }

    func testPlanForceIgnoresValidCache() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)

        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let app = root.appendingPathComponent("Build/Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, cacheRoot: cache.derivedDataRoot)
        try cache.write(SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app"
        ))

        XCTAssertTrue(try SimulatorAppLifecycleClient.plan(selection: selection, cache: cache).isCacheHit)
        XCTAssertFalse(try SimulatorAppLifecycleClient.plan(selection: selection, force: true, cache: cache).isCacheHit)
    }

    func testBuildAndLaunchPayloadJSONFields() throws {
        let identity = SimulatorAppBuildIdentity(projectPath: "/tmp/App.xcodeproj", scheme: "App")
        let build = SimulatorAppBuildPayload(
            identity: identity,
            checksum: "abc",
            inputFileCount: 3,
            cacheHit: true,
            xcodebuildRan: false,
            appBundlePath: "/tmp/App.app",
            bundleIdentifier: "com.example.app",
            xcodebuild: SimulatorAppProcessStepSummary(name: "xcodebuild", ran: false)
        )
        let launch = SimulatorAppLaunchPayload(
            build: build,
            device: SimulatorDevice(udid: "DEVICE", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true),
            launchEnvironment: ["SIMTOOL_NETWORK_LOGGER": "1"],
            launchArguments: ["-DebugFlag", "1234"],
            installed: true,
            launched: true,
            installRan: false,
            launchRan: true,
            install: SimulatorAppProcessStepSummary(name: "simctl install", ran: false),
            launch: SimulatorAppProcessStepSummary(name: "simctl launch", ran: true, status: 0, stdout: "ok")
        )

        let json = try JSON.string(launch, pretty: false)
        XCTAssertTrue(json.contains("\"checksum\":\"abc\""))
        XCTAssertTrue(json.contains("\"cacheHit\":true"))
        XCTAssertTrue(json.contains("\"installed\":true"))
        XCTAssertTrue(json.contains("\"installRan\":false"))
        XCTAssertTrue(json.contains("\"launchRan\":true"))
        XCTAssertTrue(json.contains("\"launchEnvironment\":{"))
        XCTAssertTrue(json.contains("\"SIMTOOL_NETWORK_LOGGER\":\"1\""))
        XCTAssertTrue(json.contains("\"launchArguments\":[\"-DebugFlag\",\"1234\"]"))
        XCTAssertTrue(json.contains("\"bundleIdentifier\":\"com.example.app\""))
    }

    func testSimctlLaunchArgumentsTerminateRunningAndForwardLaunchArguments() {
        let withArgs = SimulatorAppLifecycleClient.simctlLaunchArguments(
            deviceUDID: "DEVICE",
            bundleIdentifier: "com.example.app",
            launchArguments: ["-DebugFlag", "1234", "-AnotherFlag", "value"]
        )
        XCTAssertEqual(withArgs, [
            "simctl", "launch", "--terminate-running-process",
            "DEVICE", "com.example.app",
            "-DebugFlag", "1234", "-AnotherFlag", "value",
        ])

        let withoutArgs = SimulatorAppLifecycleClient.simctlLaunchArguments(
            deviceUDID: "DEVICE",
            bundleIdentifier: "com.example.app"
        )
        XCTAssertEqual(withoutArgs, [
            "simctl", "launch", "--terminate-running-process",
            "DEVICE", "com.example.app",
        ])
    }

    func testLaunchEnvironmentParsingValidationAndSimctlChildEnvironment() throws {
        let environment = try SimulatorAppLifecycleClient.parseLaunchEnvironment([
            "SIMTOOL_NETWORK_LOGGER=1",
            "SIMTOOL_SERVER_URL=http://127.0.0.1:3311/path?token=a=b",
            "EMPTY=",
        ])

        XCTAssertEqual(environment["SIMTOOL_NETWORK_LOGGER"], "1")
        XCTAssertEqual(environment["SIMTOOL_SERVER_URL"], "http://127.0.0.1:3311/path?token=a=b")
        XCTAssertEqual(environment["EMPTY"], "")

        XCTAssertThrowsError(try SimulatorAppLifecycleClient.parseLaunchEnvironment(["INVALID"]))
        XCTAssertThrowsError(try SimulatorAppLifecycleClient.parseLaunchEnvironment(["=value"]))
        XCTAssertThrowsError(try SimulatorAppLifecycleClient.parseLaunchEnvironment(["BAD-KEY=value"]))

        let simctlEnvironment = SimulatorAppLifecycleClient.simctlChildEnvironment(
            launchEnvironment: environment,
            base: ["BASE": "value"]
        )
        XCTAssertEqual(simctlEnvironment["BASE"], "value")
        XCTAssertEqual(simctlEnvironment["SIMCTL_CHILD_SIMTOOL_NETWORK_LOGGER"], "1")
        XCTAssertEqual(simctlEnvironment["SIMCTL_CHILD_SIMTOOL_SERVER_URL"], "http://127.0.0.1:3311/path?token=a=b")
        XCTAssertEqual(simctlEnvironment["SIMCTL_CHILD_EMPTY"], "")
    }

    func testLaunchEnvironmentDoesNotAffectBuildFingerprint() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")

        let first = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        _ = try SimulatorAppLifecycleClient.parseLaunchEnvironment(["SIMTOOL_NETWORK_LOGGER=1"])
        let second = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)

        XCTAssertEqual(first, second)
    }

    func testXcodebuildTestArgumentsAndPayloadJSONFields() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let derivedData = root.appendingPathComponent("DerivedData", isDirectory: true).path
        let selection = try SimulatorAppBuildSelection.validated(
            workspacePath: workspace.path,
            projectPath: nil,
            scheme: "ExampleUITests",
            configuration: "Debug",
            derivedDataPath: derivedData
        )
        let device = SimulatorDevice(udid: "DEVICE", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)

        XCTAssertEqual(SimulatorAppLifecycleClient.xcodebuildTestArguments(selection: selection, device: device, derivedDataPath: derivedData), [
            "xcodebuild",
            "-workspace", workspace.path,
            "-scheme", "ExampleUITests",
            "-configuration", "Debug",
            "-sdk", "iphonesimulator",
            "-destination", "platform=iOS Simulator,id=DEVICE",
            "-derivedDataPath", derivedData,
            "test",
        ])

        let payload = SimulatorAppTestPayload(
            identity: selection.identity,
            device: device,
            passed: false,
            xcodebuildRan: true,
            xcodebuild: SimulatorAppProcessStepSummary(name: "xcodebuild test", ran: true, status: 65, stdout: "failed")
        )
        let json = try JSON.string(payload, pretty: false)
        XCTAssertTrue(json.contains("\"passed\":false"))
        XCTAssertTrue(json.contains("\"xcodebuildRan\":true"))
        XCTAssertTrue(json.contains("\"scheme\":\"ExampleUITests\""))
        XCTAssertTrue(json.contains("\"status\":65"))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func gitIsAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Avoid leaking the test runner's identity/hooks into the throwaway repo.
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "HOME": directory.path]
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func write(_ relativePath: String, contents: String, root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
