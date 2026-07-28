import Foundation
import XCTest
@testable import SimToolCore

final class TestFlowArchiveTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-flow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - round trip

    func testPacksTheTestTheReportAndTheRunFiles() async throws {
        let run = try makeRunDirectory(id: "2026-07-28-1955-vy1cu3", files: [
            "session.json": "{}",
            "logs.jsonl": "{\"message\":\"hi\"}\n",
        ])
        let destination = workspace.appendingPathComponent("flow.simflow.zip")

        let result = try await TestFlowArchive.pack(
            TestFlowArchive.Contents(
                manifest: manifest(),
                testYAML: "name: Tab order\nsteps: []\n",
                report: "# Tab order\n",
                runs: [TestFlowArchive.Contents.Run(
                    id: "2026-07-28-1955-vy1cu3",
                    directory: run,
                    files: ["session.json", "logs.jsonl"]
                )]
            ),
            to: destination
        )

        XCTAssertEqual(result.url, destination)
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertTrue(result.entries.contains("manifest.json"))
        XCTAssertTrue(result.entries.contains("test.yml"))
        XCTAssertTrue(result.entries.contains("report.md"))
        XCTAssertTrue(result.entries.contains("runs/2026-07-28-1955-vy1cu3/logs.jsonl"))
    }

    func testManifestSurvivesTheRoundTrip() async throws {
        let destination = workspace.appendingPathComponent("flow.simflow.zip")
        var original = manifest()
        original.criteria = [TestCriterionResult(
            label: "the Chat tab opens Chat",
            status: .unmet,
            step: 6,
            detail: "no element matching id \"ChatScreen\" appeared within 25.0s"
        )]
        original.mocks = [TestMockOutcome(id: "mock-2", method: "*/GetTabBar", hits: 1, strict: true)]
        original.requires = TestFlowManifest.Requires(env: ["PYME_PHONE"], app: "com.example.app", simtool: "0.9.0")
        _ = try await TestFlowArchive.pack(
            TestFlowArchive.Contents(manifest: original, testYAML: "name: x\n", report: "# x\n"),
            to: destination
        )

        let decoded = try await TestFlowArchive.manifest(in: destination)

        XCTAssertEqual(decoded.schema, TestFlowManifest.currentSchema)
        XCTAssertEqual(decoded.kind, .bug)
        XCTAssertEqual(decoded.reference, "PROJ-42")
        XCTAssertEqual(decoded.verdict, .unsatisfied)
        XCTAssertEqual(decoded.criteria, original.criteria)
        XCTAssertEqual(decoded.mocks, original.mocks)
        XCTAssertEqual(decoded.requires, original.requires)
    }

    func testReadReturnsTheEntryBytesAndNilForAMissingOne() async throws {
        let destination = workspace.appendingPathComponent("flow.simflow.zip")
        _ = try await TestFlowArchive.pack(
            TestFlowArchive.Contents(manifest: manifest(), testYAML: "name: Tab order\n", report: "# Tab order\n"),
            to: destination
        )

        let test = try await TestFlowArchive.read("test.yml", in: destination)
        XCTAssertEqual(test.flatMap { String(data: $0, encoding: .utf8) }, "name: Tab order\n")
        let missing = try await TestFlowArchive.read("runs/nothing/session.json", in: destination)
        XCTAssertNil(missing)
    }

    func testUnpackRestoresOnlyTheSelectedPrefix() async throws {
        let run = try makeRunDirectory(id: "run-1", files: ["session.json": "{\"id\":\"run-1\"}"])
        let destination = workspace.appendingPathComponent("flow.simflow.zip")
        _ = try await TestFlowArchive.pack(
            TestFlowArchive.Contents(
                manifest: manifest(),
                testYAML: "name: x\n",
                report: "# x\n",
                runs: [TestFlowArchive.Contents.Run(id: "run-1", directory: run, files: ["session.json"])]
            ),
            to: destination
        )
        let target = workspace.appendingPathComponent("extracted", isDirectory: true)

        let extracted = try await TestFlowArchive.unpack(destination, into: target, only: "runs/")

        XCTAssertEqual(extracted, ["runs/run-1/session.json"])
        let restored = target.appendingPathComponent("runs/run-1/session.json")
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), "{\"id\":\"run-1\"}")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("test.yml").path))
    }

    /// `zip` appends to an archive that is already there, which would merge a
    /// previous export into this one.
    func testPackingTwiceReplacesRatherThanMerges() async throws {
        let first = try makeRunDirectory(id: "run-1", files: ["session.json": "{}"])
        let destination = workspace.appendingPathComponent("flow.simflow.zip")
        _ = try await TestFlowArchive.pack(
            TestFlowArchive.Contents(
                manifest: manifest(),
                testYAML: "name: x\n",
                report: "# x\n",
                runs: [TestFlowArchive.Contents.Run(id: "run-1", directory: first, files: ["session.json"])]
            ),
            to: destination
        )
        let second = try makeRunDirectory(id: "run-2", files: ["session.json": "{}"])

        let result = try await TestFlowArchive.pack(
            TestFlowArchive.Contents(
                manifest: manifest(),
                testYAML: "name: x\n",
                report: "# x\n",
                runs: [TestFlowArchive.Contents.Run(id: "run-2", directory: second, files: ["session.json"])]
            ),
            to: destination
        )

        XCTAssertTrue(result.entries.contains("runs/run-2/session.json"))
        XCTAssertFalse(result.entries.contains("runs/run-1/session.json"))
    }

    // MARK: - refusals

    func testManifestRefusesAnArchiveFromANewerSimtool() async throws {
        let destination = workspace.appendingPathComponent("flow.simflow.zip")
        var future = manifest()
        future.schema = TestFlowManifest.currentSchema + 1
        _ = try await TestFlowArchive.pack(
            TestFlowArchive.Contents(manifest: future, testYAML: "name: x\n", report: "# x\n"),
            to: destination
        )

        do {
            _ = try await TestFlowArchive.manifest(in: destination)
            XCTFail("expected a refusal")
        } catch let error as SimToolError {
            XCTAssertTrue(error.message.contains("newer simtool"), error.message)
        }
    }

    func testManifestRejectsSomethingThatIsNotAnArchive() async throws {
        let notAnArchive = workspace.appendingPathComponent("test.zip")
        try Data("name: not a zip\n".utf8).write(to: notAnArchive)

        do {
            _ = try await TestFlowArchive.manifest(in: notAnArchive)
            XCTFail("expected a refusal")
        } catch let error as SimToolError {
            XCTAssertTrue(error.message.contains("not a zip archive"), error.message)
        }
    }

    func testManifestRejectsAZipWithoutOne() async throws {
        let plain = workspace.appendingPathComponent("plain.zip")
        try Data("hello".utf8).write(to: workspace.appendingPathComponent("hello.txt"))
        let zipped = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", plain.path, "hello.txt"],
            currentDirectory: workspace
        )
        XCTAssertEqual(zipped.status, 0)

        do {
            _ = try await TestFlowArchive.manifest(in: plain)
            XCTFail("expected a refusal")
        } catch let error as SimToolError {
            XCTAssertTrue(error.message.contains("not a SimTool flow archive"), error.message)
        }
    }

    // MARK: - requirements and naming

    func testRequirementsNamesVariablesFromBothTheTestAndTheRecordedLaunch() {
        let requires = TestFlowArchive.requirements(
            testYAML: "setup:\n  - echo ${SEED_TOKEN}\n",
            launch: ResolvedLaunch(
                profile: "staging",
                arguments: ["-FastLoginPhone", "${PYME_PHONE}", "-Environment", "stable"],
                environment: ["API_KEY": "${SERVICE_KEY}"],
                deeplink: "app://open/${DEEPLINK_PATH}"
            ),
            app: "com.example.app",
            simtoolVersion: "0.9.0"
        )

        XCTAssertEqual(requires.env, ["DEEPLINK_PATH", "PYME_PHONE", "SEED_TOKEN", "SERVICE_KEY"])
        XCTAssertEqual(requires.app, "com.example.app")
        XCTAssertEqual(requires.simtool, "0.9.0")
    }

    func testRequirementsAreEmptyWhenNothingIsParameterised() {
        let requires = TestFlowArchive.requirements(
            testYAML: "name: plain\nsteps: []\n",
            launch: ResolvedLaunch(arguments: ["-UITesting"]),
            app: nil
        )
        XCTAssertTrue(requires.env.isEmpty)
        XCTAssertNil(requires.app)
    }

    func testSuggestedFileNamePrefersTheReferenceAndKeepsItAFileName() {
        XCTAssertEqual(
            TestFlowArchive.suggestedFileName(reference: "PROJ-42", name: "Tab order", sessionId: "s1"),
            "PROJ-42.simflow.zip"
        )
        XCTAssertEqual(
            TestFlowArchive.suggestedFileName(reference: nil, name: "Chat tab / opens: Chat!", sessionId: "s1"),
            "Chat-tab-opens-Chat.simflow.zip"
        )
        XCTAssertEqual(
            TestFlowArchive.suggestedFileName(reference: "  ", name: nil, sessionId: "2026-07-28-1955-vy1cu3"),
            "2026-07-28-1955-vy1cu3.simflow.zip"
        )
    }

    func testIsArchiveLooksAtTheExtensionOnly() {
        XCTAssertTrue(TestFlowArchive.isArchive(URL(fileURLWithPath: "/tmp/PROJ-42.simflow.zip")))
        XCTAssertTrue(TestFlowArchive.isArchive(URL(fileURLWithPath: "/tmp/whatever.ZIP")))
        XCTAssertFalse(TestFlowArchive.isArchive(URL(fileURLWithPath: "/tmp/test.yml")))
    }

    // MARK: - fixtures

    private func manifest() -> TestFlowManifest {
        TestFlowManifest(
            exportedAt: Date(timeIntervalSince1970: 1_785_000_000),
            name: "Tab order",
            kind: .bug,
            reference: "PROJ-42",
            verdict: .unsatisfied,
            headline: TestVerdict.unsatisfied.headline(for: .bug)
        )
    }

    private func makeRunDirectory(id: String, files: [String: String]) throws -> URL {
        let directory = workspace.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }
}
