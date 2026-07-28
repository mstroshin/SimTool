import Foundation
import XCTest
@testable import SimToolCore

final class TestReportRendererTests: XCTestCase {
    func testLeadsWithTheVerdictAndItsExitCode() {
        let report = TestReportRenderer.render(manifest: manifest(), sessions: [session()])

        XCTAssertTrue(report.hasPrefix("# Tab order\n"), report.prefix(80).description)
        XCTAssertTrue(report.contains("**Bug reproduced** — `unsatisfied`, exit code 1"), report)
    }

    func testMarksEachCriterionAndSaysWhereItFailed() {
        let report = TestReportRenderer.render(manifest: manifest(), sessions: [session()])

        XCTAssertTrue(report.contains("✗ **the Chat tab opens Chat** — step 6: no element matching id \"ChatScreen\""), report)
        XCTAssertTrue(report.contains("a `bug` test stops at the first criterion that does not hold"), report)
    }

    func testAFeatureReportSaysItCheckedEverything() {
        var subject = manifest()
        subject.kind = .feature
        subject.criteria = [
            TestCriterionResult(label: "AC-1", status: .met, step: 3),
            TestCriterionResult(label: "AC-2", status: .unmet, step: 5, detail: "still enabled"),
        ]
        subject.verdict = .unsatisfied
        subject.headline = TestVerdict.unsatisfied.headline(for: .feature)

        let report = TestReportRenderer.render(manifest: subject, sessions: [session()])

        XCTAssertTrue(report.contains("✓ **AC-1** — step 3"), report)
        XCTAssertTrue(report.contains("✗ **AC-2** — step 5: still enabled"), report)
        XCTAssertTrue(report.contains("checks all of its criteria in one run"), report)
    }

    func testAnUncheckedCriterionSaysTheRunNeverGotThere() {
        var subject = manifest()
        subject.verdict = .inconclusive
        subject.headline = TestVerdict.inconclusive.headline(for: .bug)
        subject.criteria = [TestCriterionResult(label: "the Chat tab opens Chat", status: .unchecked)]

        let report = TestReportRenderer.render(manifest: subject, sessions: [session()])

        XCTAssertTrue(report.contains("– **the Chat tab opens Chat** — the run never got this far"), report)
    }

    func testMockTableCountsWhatEachRuleAnswered() {
        let report = TestReportRenderer.render(manifest: manifest(), sessions: [session()])

        XCTAssertTrue(report.contains("| `*/GetTabBar` | 1 call | yes |"), report)
        XCTAssertTrue(report.contains("A strict rule that answers nothing makes the run `infra`"), report)
    }

    /// Wall-clock spans run longer than simctl's footage, so an unscaled offset
    /// sends the reader past the end of the video.
    func testTimelineOffsetsAreScaledOntoTheRealVideoLength() {
        let subject = session()
        let report = TestReportRenderer.render(manifest: manifest(), sessions: [subject])

        // 20s of wall clock, 10s of video: the entry at +10s lands at 0:05.
        XCTAssertTrue(report.contains("`0:05` ✓ 1/6 waitFor id=MainScreenV2View"), report)
        XCTAssertTrue(report.contains("video 0:10"), report)
    }

    func testTimelineNamesTheCriterionAStepChecked() {
        let report = TestReportRenderer.render(manifest: manifest(), sessions: [session()])

        XCTAssertTrue(report.contains("criterion: **the Chat tab opens Chat**"), report)
    }

    func testTimelineCapsNoteLinesAndSaysHowManyItDropped() {
        var subject = session()
        subject.entries.append(TestSessionEntry(
            kind: .log,
            at: Date(timeIntervalSince1970: 1_785_000_030),
            logs: (1...20).map { "line \($0)" }
        ))

        let report = TestReportRenderer.render(manifest: manifest(), sessions: [subject])

        XCTAssertTrue(report.contains("- line 12"), report)
        XCTAssertFalse(report.contains("- line 13"), report)
        XCTAssertTrue(report.contains("8 further note lines omitted here"), report)
    }

    func testEvidenceSectionExplainsEachPackagedFile() {
        let report = TestReportRenderer.render(manifest: manifest(), sessions: [session()])

        XCTAssertTrue(report.contains("`runs/2026-07-28-1955-vy1cu3/`"), report)
        XCTAssertTrue(report.contains("every HTTP and gRPC call the app reported"), report)
        XCTAssertTrue(report.contains("screenshot at the step that failed"), report)
        XCTAssertTrue(report.contains("screen recording of the run (0:10)"), report)
    }

    /// A report that points at evidence the export left behind is worse than one
    /// that admits the gap.
    func testEvidenceSectionFollowsWhatActuallyTravelled() {
        let report = TestReportRenderer.render(
            manifest: manifest(),
            sessions: [session()],
            includedFiles: ["2026-07-28-1955-vy1cu3": ["session.json"]]
        )

        XCTAssertTrue(report.contains("| `session.json` |"), report)
        XCTAssertFalse(report.contains("network.jsonl"), report)
    }

    func testRerunSectionNamesTheVariablesAndTheCommands() {
        let report = TestReportRenderer.render(manifest: manifest(), sessions: [session()], archiveName: "PROJ-42.simflow.zip")

        XCTAssertTrue(report.contains("these variables exported: `PYME_PHONE`"), report)
        XCTAssertTrue(report.contains("export PYME_PHONE=…"), report)
        XCTAssertTrue(report.contains("simtool test run PROJ-42.simflow.zip"), report)
        XCTAssertTrue(report.contains("`2` inconclusive"), report)
        XCTAssertTrue(report.contains("The launch profile `pyme-stable` does not have to exist"), report)
    }

    func testWarnsAboutForwardingWhenTheAccountsTrafficTravels() {
        let report = TestReportRenderer.render(manifest: manifest(), sessions: [session()])

        XCTAssertTrue(report.contains("## Before you forward this"), report)
        XCTAssertTrue(report.contains("`logs.jsonl` and `network.jsonl`"), report)
    }

    func testNoForwardingWarningWithoutEvidenceButTheOmissionIsStated() {
        var subject = manifest()
        subject.runs = [TestFlowManifest.Run(
            session: "2026-07-28-1955-vy1cu3",
            status: .failed,
            verdict: .unsatisfied,
            startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            files: ["session.json"]
        )]
        subject.notes = ["Evidence omitted (`--no-evidence`): logs.jsonl, network.jsonl."]

        let report = TestReportRenderer.render(manifest: subject, sessions: [session()])

        XCTAssertFalse(report.contains("Before you forward this"), report)
        XCTAssertTrue(report.contains("## What is not here"), report)
        XCTAssertTrue(report.contains("Evidence omitted"), report)
    }

    func testAnUnrunTestSaysSoInsteadOfClaimingAVerdict() {
        var subject = manifest()
        subject.verdict = nil
        subject.headline = nil
        subject.runs = []

        let report = TestReportRenderer.render(manifest: subject, sessions: [])

        XCTAssertTrue(report.contains("_This archive carries a test that has not been run._"), report)
        XCTAssertFalse(report.contains("## Evidence"), report)
    }

    /// A typed string or a label can contain a pipe, which would otherwise
    /// break out of the cell it is rendered in.
    func testPipesInStepTextAreEscaped() {
        var subject = session()
        subject.entries = [TestSessionEntry(
            kind: .step,
            at: Date(timeIntervalSince1970: 1_785_000_010),
            text: "✓ 1/1 type \"a|b\""
        )]

        let report = TestReportRenderer.render(manifest: manifest(), sessions: [subject])

        XCTAssertTrue(report.contains("type \"a\\|b\""), report)
    }

    // MARK: - fixtures

    private func manifest() -> TestFlowManifest {
        TestFlowManifest(
            exportedAt: Date(timeIntervalSince1970: 1_785_000_100),
            name: "Tab order",
            description: "The Chat tab must open Chat, not Invite.",
            kind: .bug,
            reference: "PROJ-42",
            verdict: .unsatisfied,
            headline: TestVerdict.unsatisfied.headline(for: .bug),
            criteria: [TestCriterionResult(
                label: "the Chat tab opens Chat",
                status: .unmet,
                step: 6,
                detail: "no element matching id \"ChatScreen\" appeared within 25.0s"
            )],
            mocks: [TestMockOutcome(id: "mock-2", method: "*/GetTabBar", hits: 1, strict: true)],
            runs: [TestFlowManifest.Run(
                session: "2026-07-28-1955-vy1cu3",
                status: .failed,
                verdict: .unsatisfied,
                startedAt: Date(timeIntervalSince1970: 1_785_000_000),
                files: ["session.json", "logs.jsonl", "network.jsonl", "failure-step-6.png", "video.mp4"]
            )],
            requires: TestFlowManifest.Requires(env: ["PYME_PHONE"], app: "com.example.app", simtool: "0.9.0"),
            provenance: TestRunProvenance(
                testFile: "tab_order.yml",
                appBundleId: "com.example.app",
                appVersion: "3.20.0",
                appBuild: "4398",
                commit: "982b9170cc",
                deviceName: "iPhone 16 Pro",
                runtime: "iOS 18.2",
                simtoolVersion: "0.9.0",
                launch: ResolvedLaunch(profile: "pyme-stable", arguments: ["-Environment", "stable"])
            )
        )
    }

    private func session() -> TestSession {
        TestSession(
            id: "2026-07-28-1955-vy1cu3",
            title: "Tab order",
            deviceUdid: "UDID",
            deviceName: "iPhone 16 Pro",
            startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            endedAt: Date(timeIntervalSince1970: 1_785_000_020),
            recordingStartedAt: Date(timeIntervalSince1970: 1_785_000_000),
            status: .failed,
            videoDurationSeconds: 10,
            entries: [
                TestSessionEntry(
                    kind: .step,
                    at: Date(timeIntervalSince1970: 1_785_000_010),
                    text: "✓ 1/6 waitFor id=MainScreenV2View"
                ),
                TestSessionEntry(
                    kind: .step,
                    at: Date(timeIntervalSince1970: 1_785_000_016),
                    text: "✗ 6/6 assertVisible id=ChatScreen — no element appeared",
                    criterion: "the Chat tab opens Chat"
                ),
            ],
            kind: .bug,
            reference: "PROJ-42",
            criteria: [TestCriterionResult(label: "the Chat tab opens Chat", status: .unmet, step: 6)],
            verdict: .unsatisfied,
            mocks: [TestMockOutcome(id: "mock-2", method: "*/GetTabBar", hits: 1, strict: true)],
            evidence: ["logs.jsonl", "network.jsonl", "failure-step-6.png"]
        )
    }
}
