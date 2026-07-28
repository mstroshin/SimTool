import Foundation
import XCTest
@testable import SimToolCLI
import SimToolCore

final class TestFlowCommandTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-flow-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - choosing the run to package

    func testSelectsTheNewestFinishedRunOfTheNamedTest() throws {
        let sessions = [
            session(id: "c", startedAt: 300, status: .running, testFile: "tab_order.yml"),
            session(id: "b", startedAt: 200, status: .failed, testFile: "tab_order.yml"),
            session(id: "a", startedAt: 100, status: .passed, testFile: "other.yml"),
        ]

        let chosen = try TestCommand.Export.select(sessionId: nil, test: "/tests/tab_order.yml", from: sessions)

        XCTAssertEqual(chosen.id, "b")
    }

    func testSelectingAnExplicitSessionWins() throws {
        let sessions = [session(id: "b", startedAt: 200, status: .failed), session(id: "a", startedAt: 100, status: .passed)]

        XCTAssertEqual(try TestCommand.Export.select(sessionId: "a", test: nil, from: sessions).id, "a")
    }

    func testUnknownSessionErrorNamesTheNewestOnes() {
        let sessions = [session(id: "b", startedAt: 200, status: .failed), session(id: "a", startedAt: 100, status: .passed)]

        XCTAssertThrowsError(try TestCommand.Export.select(sessionId: "nope", test: nil, from: sessions)) { error in
            XCTAssertTrue(message(error).contains("Newest: b, a"), message(error))
        }
    }

    func testNoRunOfThatTestErrorSaysWhatIsRecorded() {
        let sessions = [session(id: "a", startedAt: 100, status: .passed, testFile: "other.yml")]

        XCTAssertThrowsError(try TestCommand.Export.select(sessionId: nil, test: "tab_order.yml", from: sessions)) { error in
            XCTAssertTrue(message(error).contains("No recorded run of tab_order.yml"), message(error))
            XCTAssertTrue(message(error).contains("other.yml"), message(error))
        }
    }

    /// A run still going has half-written evidence and no verdict.
    func testARunStillGoingIsNotPackaged() {
        let sessions = [session(id: "a", startedAt: 100, status: .running)]

        XCTAssertThrowsError(try TestCommand.Export.select(sessionId: nil, test: nil, from: sessions)) { error in
            XCTAssertTrue(message(error).contains("still going"), message(error))
        }
    }

    // MARK: - what travels

    func testPackagesTheSessionAndTheEvidenceThatExists() throws {
        let directory = try makeSessionDirectory(files: ["logs.jsonl", "network.jsonl", "video.mp4"])
        var subject = session(id: "a", startedAt: 100, status: .failed)
        subject.evidence = ["logs.jsonl", "network.jsonl"]
        var notes: [String] = []

        let files = TestCommand.Export.filesToPackage(
            session: subject,
            directory: directory,
            includeEvidence: true,
            includeVideo: true,
            notes: &notes
        )

        XCTAssertEqual(files.sorted(), ["logs.jsonl", "network.jsonl", "session.json", "video.mp4"])
        XCTAssertTrue(notes.isEmpty, "\(notes)")
    }

    func testOmissionsAreStatedRatherThanSilent() throws {
        let directory = try makeSessionDirectory(files: ["logs.jsonl", "video.mp4"])
        var subject = session(id: "a", startedAt: 100, status: .failed)
        subject.evidence = ["logs.jsonl", "network.jsonl"]
        var notes: [String] = []

        let files = TestCommand.Export.filesToPackage(
            session: subject,
            directory: directory,
            includeEvidence: false,
            includeVideo: false,
            notes: &notes
        )

        XCTAssertEqual(files, ["session.json"])
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes.contains { $0.contains("Missing from the session directory") && $0.contains("network.jsonl") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("--no-evidence") && $0.contains("logs.jsonl") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("--no-video") }, "\(notes)")
    }

    func testARunWithoutAVideoSaysWhy() throws {
        let directory = try makeSessionDirectory(files: [])
        var subject = session(id: "a", startedAt: 100, status: .failed)
        subject.videoError = "simctl recording died"
        var notes: [String] = []

        _ = TestCommand.Export.filesToPackage(
            session: subject,
            directory: directory,
            includeEvidence: true,
            includeVideo: true,
            notes: &notes
        )

        XCTAssertEqual(notes, ["This run has no screen recording: simctl recording died"])
    }

    func testDestinationIsNamedAfterTheReferenceAndNeverOverwrittenSilently() throws {
        let manifest = TestFlowManifest(name: "Tab order", reference: "PROJ-42")

        let url = try TestCommand.Export.destination(output: nil, manifest: manifest, sessionId: "a", force: false)
        XCTAssertEqual(url.lastPathComponent, "PROJ-42.simflow.zip")

        let existing = workspace.appendingPathComponent("taken.simflow.zip")
        try Data("x".utf8).write(to: existing)
        XCTAssertThrowsError(try TestCommand.Export.destination(output: existing.path, manifest: manifest, sessionId: "a", force: false)) { error in
            XCTAssertTrue(message(error).contains("--force"), message(error))
        }
        XCTAssertNoThrow(try TestCommand.Export.destination(output: existing.path, manifest: manifest, sessionId: "a", force: true))
    }

    // MARK: - running what arrived

    func testLoadingAPlainYAMLFileCarriesNoManifest() async throws {
        let file = workspace.appendingPathComponent("plain.yml")
        try Data("name: Plain\nsteps:\n  - wait: 1\n".utf8).write(to: file)

        let prepared = try await TestSourceLoader.load(path: file.path, config: nil)

        XCTAssertEqual(prepared.definition.name, "Plain")
        XCTAssertEqual(prepared.file, file)
        XCTAssertNil(prepared.manifest)
        XCTAssertTrue(prepared.extraProfiles.isEmpty)
        XCTAssertTrue(prepared.notes.isEmpty)
    }

    func testLoadingAnArchiveRestoresTheTestUnderItsOriginalName() async throws {
        setenv("SIMTOOL_FLOW_TEST_ACCOUNT", "+34600000000", 1)
        defer { unsetenv("SIMTOOL_FLOW_TEST_ACCOUNT") }
        let archive = try await makeArchive()

        let prepared = try await TestSourceLoader.load(path: archive.path, config: nil)

        XCTAssertEqual(prepared.definition.name, "Tab order")
        XCTAssertEqual(prepared.file.lastPathComponent, "tab_order.yml")
        XCTAssertEqual(prepared.manifest?.reference, "PROJ-42")
        XCTAssertEqual(try String(contentsOf: prepared.file, encoding: .utf8), Self.archivedYAML)
    }

    /// The values behind `${VAR}` are the account the run used, so they never
    /// travel — and finding that out before the simulator is touched is worth a
    /// dedicated error.
    func testAnArchiveMissingItsVariablesFailsBeforeAnythingRuns() async throws {
        unsetenv("SIMTOOL_FLOW_TEST_ACCOUNT")
        let archive = try await makeArchive()

        do {
            _ = try await TestSourceLoader.load(path: archive.path, config: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(message(error).contains("SIMTOOL_FLOW_TEST_ACCOUNT"), message(error))
            XCTAssertTrue(message(error).contains("never carries its value"), message(error))
        }
    }

    /// The receiver's config has no `pyme-stable`, so the archive's recorded
    /// launch stands in for it — minus the parts this test contributes itself.
    func testAMissingLaunchProfileIsRebuiltFromTheRecordedLaunch() async throws {
        setenv("SIMTOOL_FLOW_TEST_ACCOUNT", "+34600000000", 1)
        defer { unsetenv("SIMTOOL_FLOW_TEST_ACCOUNT") }
        let archive = try await makeArchive()

        let prepared = try await TestSourceLoader.load(path: archive.path, config: nil)

        XCTAssertEqual(prepared.extraProfiles.count, 1)
        let profile = try XCTUnwrap(prepared.extraProfiles.first)
        XCTAssertEqual(profile.name, "pyme-stable")
        XCTAssertEqual(profile.arguments, ["-Environment", "stable", "-FastLoginPhone", "${SIMTOOL_FLOW_TEST_ACCOUNT}"])
        XCTAssertEqual(profile.environment, ["SEED": "1"])
        XCTAssertTrue(prepared.notes.contains { $0.contains("not in this project's config") }, "\(prepared.notes)")
    }

    func testAKnownLaunchProfileIsLeftToTheProjectConfig() async throws {
        setenv("SIMTOOL_FLOW_TEST_ACCOUNT", "+34600000000", 1)
        defer { unsetenv("SIMTOOL_FLOW_TEST_ACCOUNT") }
        let archive = try await makeArchive()
        let config = try projectConfig(withProfile: "pyme-stable")

        let prepared = try await TestSourceLoader.load(path: archive.path, config: config)

        XCTAssertTrue(prepared.extraProfiles.isEmpty)
        XCTAssertTrue(prepared.notes.isEmpty, "\(prepared.notes)")
    }

    // MARK: - build drift

    func testBuildDriftSaysWhenTheBuildIsTheSame() {
        var manifest = TestFlowManifest()
        manifest.provenance = TestRunProvenance(appVersion: "3.20.0", appBuild: "4398")

        let lines = BuildDrift.lines(
            manifest: manifest,
            installed: InstalledAppBundle(path: URL(fileURLWithPath: "/app"), version: "3.20.0", build: "4398"),
            app: "com.example.app"
        )

        XCTAssertEqual(lines, ["Same build as the packaged run: 3.20.0 (4398)."])
    }

    func testBuildDriftNamesBothBuildsWhenTheyDiffer() {
        var manifest = TestFlowManifest()
        manifest.provenance = TestRunProvenance(appVersion: "3.20.0", appBuild: "4398")

        let lines = BuildDrift.lines(
            manifest: manifest,
            installed: InstalledAppBundle(path: URL(fileURLWithPath: "/app"), version: "3.20.0", build: "4412"),
            app: "com.example.app"
        )

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("3.20.0 (4398)"), lines[0])
        XCTAssertTrue(lines[0].contains("3.20.0 (4412)"), lines[0])
    }

    func testBuildDriftSaysWhenTheAppIsNotThere() {
        let lines = BuildDrift.lines(manifest: TestFlowManifest(), installed: nil, app: "com.example.app")

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("is not installed"), lines[0])
    }

    // MARK: - fixtures

    private static let archivedYAML = """
        name: Tab order
        kind: bug
        reference: "PROJ-42"
        app: com.example.app
        launch:
          profile: pyme-stable
          arguments: [-UITesting]
        reset:
          locale: es_ES
        steps:
          - assertVisible: { id: ChatScreen, criterion: "the Chat tab opens Chat" }
        """

    /// Packs an archive whose recorded launch is what a real run would have
    /// recorded: reset arguments, then the profile's, then the test's inline
    /// ones, with `${VAR}` left unexpanded.
    private func makeArchive() async throws -> URL {
        let definition = try TestDefinitionParser.parse(Self.archivedYAML)
        let recorded = ResolvedLaunch(
            profile: "pyme-stable",
            arguments: definition.reset.launchArguments
                + ["-Environment", "stable", "-FastLoginPhone", "${SIMTOOL_FLOW_TEST_ACCOUNT}"]
                + definition.launch.arguments,
            environment: ["SEED": "1"],
            deeplink: nil
        )
        let manifest = TestFlowManifest(
            name: definition.name,
            kind: definition.kind,
            reference: definition.reference,
            verdict: .unsatisfied,
            requires: TestFlowArchive.requirements(
                testYAML: Self.archivedYAML,
                launch: recorded,
                app: definition.app
            ),
            provenance: TestRunProvenance(
                testFile: "tab_order.yml",
                appBundleId: definition.app,
                launch: recorded
            )
        )
        let destination = workspace.appendingPathComponent("PROJ-42.simflow.zip")
        _ = try await TestFlowArchive.pack(
            TestFlowArchive.Contents(manifest: manifest, testYAML: Self.archivedYAML, report: "# Tab order\n"),
            to: destination
        )
        return destination
    }

    private func projectConfig(withProfile name: String) throws -> ProjectConfig {
        let directory = workspace.appendingPathComponent("project/.simtool", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The loader validates that the build target exists.
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("project/App.xcworkspace", isDirectory: true),
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("config.yml")
        try Data("""
            simulator: iPhone 16 Pro
            bundleId: com.example.app
            build:
              workspace: App.xcworkspace
              scheme: App
            profiles:
              \(name):
                arguments: [-Environment, stable]
            """.utf8).write(to: file)
        return try ProjectConfigLoader.load(explicitPath: file.path)
    }

    private func session(
        id: String,
        startedAt: TimeInterval,
        status: TestSessionStatus,
        testFile: String? = nil
    ) -> TestSession {
        TestSession(
            id: id,
            title: "Tab order",
            deviceUdid: "UDID",
            deviceName: "iPhone 16 Pro",
            startedAt: Date(timeIntervalSince1970: startedAt),
            status: status,
            provenance: testFile.map { TestRunProvenance(testFile: $0) }
        )
    }

    private func makeSessionDirectory(files: [String]) throws -> URL {
        let directory = workspace.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data("x".utf8).write(to: directory.appendingPathComponent(file))
        }
        return directory
    }

    private func message(_ error: Error) -> String {
        (error as? SimToolError)?.message ?? error.localizedDescription
    }
}
