import Foundation
import XCTest
@testable import SimToolCore

final class TestReportWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TestReportWriterTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWritesTheReportIntoADirectoryItCreates() throws {
        let url = try TestReportWriter.write(session: session(), definition: nil, into: directory)

        XCTAssertEqual(url.lastPathComponent, "report.md")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("# Tab order\n"), contents.prefix(60).description)
    }

    // A re-run of the same session id is the same run being re-recorded; a stale
    // report next to fresh evidence is worse than no report.
    func testOverwritesAnExistingReport() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale\n".utf8).write(to: directory.appendingPathComponent("report.md"))

        let url = try TestReportWriter.write(session: session(), definition: nil, into: directory)

        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("stale"))
    }

    func testCarriesTheVariablesTheReceiverMustSupply() throws {
        let url = try TestReportWriter.write(
            session: session(),
            definition: nil,
            requiredVariables: ["ACCOUNT"],
            into: directory
        )

        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("export ACCOUNT=…"))
    }

    private func session() -> TestSession {
        TestSession(
            id: "2026-07-28-1955-vy1cu3",
            title: "Tab order",
            deviceUdid: "UDID",
            deviceName: "iPhone 16 Pro",
            startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            endedAt: Date(timeIntervalSince1970: 1_785_000_020),
            status: .failed,
            kind: .bug,
            criteria: [TestCriterionResult(label: "the Chat tab opens Chat", status: .unmet, step: 6)],
            verdict: .unsatisfied
        )
    }
}
