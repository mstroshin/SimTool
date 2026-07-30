import Foundation
import XCTest
@testable import SimToolCore

final class TestReportRendererTests: XCTestCase {
    func testLeadsWithTheVerdictAndItsExitCode() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.hasPrefix("# Tab order\n"), report.prefix(80).description)
        XCTAssertTrue(report.contains("**Bug reproduced** — `unsatisfied`, exit code 1"), report)
        XCTAssertTrue(report.contains("The Chat tab must open Chat, not Invite."), report)
    }

    // A session is enough to render: the test file may be gone, renamed, or on
    // another machine by the time anyone reads the report.
    func testRendersWithoutTheTestDefinition() {
        let report = TestReportRenderer.render(session: session())

        XCTAssertTrue(report.hasPrefix("# Tab order\n"), report.prefix(80).description)
        XCTAssertFalse(report.contains("The Chat tab must open Chat"), report)
    }

    func testASessionWithoutAVerdictSaysItMakesNoClaim() {
        var subject = session()
        subject.kind = nil
        subject.verdict = nil
        subject.criteria = []
        subject.status = .passed

        let report = TestReportRenderer.render(session: subject, definition: nil)

        XCTAssertTrue(report.contains("declares no `kind:`"), report)
        XCTAssertTrue(report.contains("passed"), report)
    }

    func testMarksEachCriterionAndSaysWhereItFailed() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains("✗ **the Chat tab opens Chat** — step 6: no element matching id \"ChatScreen\""), report)
        XCTAssertTrue(report.contains("a `bug` test stops at the first criterion that does not hold"), report)
    }

    func testAFeatureReportSaysItCheckedEverything() {
        var subject = session()
        subject.kind = .feature
        subject.criteria = [
            TestCriterionResult(label: "AC-1", status: .met, step: 3),
            TestCriterionResult(label: "AC-2", status: .unmet, step: 5, detail: "still enabled"),
        ]

        let report = TestReportRenderer.render(session: subject, definition: definition())

        XCTAssertTrue(report.contains("✓ **AC-1** — step 3"), report)
        XCTAssertTrue(report.contains("✗ **AC-2** — step 5: still enabled"), report)
        XCTAssertTrue(report.contains("checks all of its criteria in one run"), report)
    }

    func testAnUncheckedCriterionSaysTheRunNeverGotThere() {
        var subject = session()
        subject.verdict = .inconclusive
        subject.criteria = [TestCriterionResult(label: "the Chat tab opens Chat", status: .unchecked)]

        let report = TestReportRenderer.render(session: subject, definition: definition())

        XCTAssertTrue(report.contains("– **the Chat tab opens Chat** — the run never got this far"), report)
    }

    func testMockTableCountsWhatEachRuleAnswered() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains("| `*/GetTabBar` | 1 call | yes |"), report)
        XCTAssertTrue(report.contains("A strict rule that answers nothing makes the run `infra`"), report)
    }

    /// Wall-clock spans run longer than simctl's footage, so an unscaled offset
    /// sends the reader past the end of the video.
    func testTimelineOffsetsAreScaledOntoTheRealVideoLength() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains("`0:05` ✓ 1/6 waitFor id=MainScreenV2View"), report)
        XCTAssertTrue(report.contains("`0:08` ✗ 6/6 assertVisible id=ChatScreen"), report)
    }

    func testFactsNameTheBuildDeviceAndCommit() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains("| App | com.example.app 3.20.0 (4398) |"), report)
        XCTAssertTrue(report.contains("| Commit | `982b9170cc` |"), report)
        XCTAssertTrue(report.contains("| Device | iPhone 16 Pro · iOS 18.2 |"), report)
        XCTAssertTrue(report.contains("| Reference | PROJ-42 |"), report)
    }

    // The files are in the same directory as the report, so nothing may point at
    // an archive path that no longer exists.
    func testEvidenceListsTheSessionDirectoryItSitsIn() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains(".simtool/test-sessions/2026-07-28-1955-vy1cu3/"), report)
        XCTAssertTrue(report.contains("| `session.json` |"), report)
        XCTAssertTrue(report.contains("| `network.jsonl` |"), report)
        XCTAssertTrue(report.contains("| `video.mp4` |"), report)
        XCTAssertFalse(report.contains("runs/"), report)
    }

    func testRerunSectionNamesWhatTheReceiverSupplies() {
        let report = TestReportRenderer.render(
            session: session(),
            definition: definition(),
            requiredVariables: ["ACCOUNT"]
        )

        XCTAssertTrue(report.contains("`simtool` 0.9.0 or newer"), report)
        XCTAssertTrue(report.contains("`com.example.app` installed on a booted simulator"), report)
        XCTAssertTrue(report.contains("these variables exported: `ACCOUNT`"), report)
        XCTAssertTrue(report.contains("export ACCOUNT=…"), report)
        XCTAssertTrue(report.contains("simtool test run tab_order.yml"), report)
        XCTAssertTrue(report.contains("starts a server itself when none is running"), report)
    }

    // The prerequisites are a list, so an aside folded into one of the items came
    // out as "…your own build, which is the point when verifying a fix and these
    // variables exported: `ACCOUNT`" — a sentence that reads as nonsense to the
    // one person the report is written for.
    func testRerunPrerequisitesKeepTheBuildAsideOutOfTheList() {
        let report = TestReportRenderer.render(
            session: session(),
            definition: definition(),
            requiredVariables: ["ACCOUNT"]
        )

        XCTAssertFalse(report.contains("which is the point when verifying a fix and these variables exported"), report)
        XCTAssertTrue(report.contains("Use your own build of the app"), report)
    }

    // "`simtool` 0.9.0-dev or newer" sends the receiver looking for a version no
    // release ever carries. The requirement is the release it was built from; the
    // fact that this run used a local build belongs next to it, not inside it.
    func testADevBuildAsksForTheReleaseItIsBasedOn() {
        var subject = session()
        subject.provenance?.simtoolVersion = "0.9.0-dev"

        let report = TestReportRenderer.render(session: subject, definition: definition())

        XCTAssertTrue(report.contains("`simtool` 0.9.0 or newer"), report)
        XCTAssertFalse(report.contains("0.9.0-dev or newer"), report)
        XCTAssertTrue(report.contains("recorded with a 0.9.0-dev build"), report)
    }

    // A bare file name does not resolve from the project root, which is where
    // whoever re-runs the test stands — the snippet has to be paste-ready.
    func testRerunSnippetNamesTheTestWhereItLives() {
        var subject = session()
        subject.provenance?.testFile = ".simtool/tests/tab_order.yml"

        let report = TestReportRenderer.render(session: subject, definition: definition())

        XCTAssertTrue(report.contains("simtool test run .simtool/tests/tab_order.yml"), report)
    }

    // The truncation note used to send the reader to `logs.jsonl`, which holds
    // the app's log lines and none of these notes. The screen dump at the failing
    // step is in the ax file; every note is in the session.
    func testTruncatedNotesPointAtWhereTheFullCaptureIs() {
        var subject = session()
        subject.evidence = ["logs.jsonl", "failure-step-6.png", "failure-step-6-ax.txt"]
        subject.entries.append(TestSessionEntry(
            kind: .log,
            at: Date(timeIntervalSince1970: 1_785_000_017),
            logs: (1...20).map { "On screen line \($0)" }
        ))

        let report = TestReportRenderer.render(session: subject, definition: definition())

        XCTAssertTrue(report.contains("8 further note lines omitted here"), report)
        XCTAssertTrue(report.contains("`failure-step-6-ax.txt`"), report)
        XCTAssertTrue(report.contains("`session.json`"), report)
        XCTAssertFalse(report.contains("the full capture is in the run's `logs.jsonl`"), report)
    }

    // With no failure dump to point at, the session file is still the honest
    // answer — and it is never `logs.jsonl`.
    func testTruncatedNotesWithoutAFailureDumpPointAtTheSession() {
        var subject = session()
        subject.evidence = ["logs.jsonl"]
        subject.entries.append(TestSessionEntry(
            kind: .log,
            at: Date(timeIntervalSince1970: 1_785_000_017),
            logs: (1...20).map { "note \($0)" }
        ))

        let report = TestReportRenderer.render(session: subject, definition: definition())

        XCTAssertTrue(report.contains("8 further note lines omitted here"), report)
        XCTAssertTrue(report.contains("`session.json`"), report)
        XCTAssertFalse(report.contains("`logs.jsonl`._"), report)
    }

    func testRerunSectionSaysWhatTheTestDefinesItself() {
        var subject = definition()
        subject.variables = ["ACCOUNT": "+34600000000"]

        let report = TestReportRenderer.render(session: session(), definition: subject)

        XCTAssertTrue(report.contains("The test defines `ACCOUNT` itself"), report)
        XCTAssertTrue(report.contains("`--var NAME=value`"), report)
    }

    func testForwardingWarnsAboutRealAccountDataAndInlineValues() {
        var subject = definition()
        subject.variables = ["ACCOUNT": "+34600000000"]

        let report = TestReportRenderer.render(session: session(), definition: subject)

        XCTAssertTrue(report.contains("Before you forward this"), report)
        XCTAssertTrue(report.contains("`logs.jsonl`"), report)
        XCTAssertTrue(report.contains("team-internal"), report)
        XCTAssertTrue(report.contains("goes wherever this file goes"), report)
    }

    // MARK: - fixtures

    private func definition() -> TestDefinition {
        TestDefinition(
            name: "Tab order",
            description: "The Chat tab must open Chat, not Invite.",
            kind: .bug,
            reference: "PROJ-42",
            app: "com.example.app",
            launch: TestLaunch(profile: "staging-account1"),
            steps: [TestStep(action: .waitFor(TestTarget(kind: .id, query: "ChatScreen"), timeout: nil), criterion: "the Chat tab opens Chat")]
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
            criteria: [TestCriterionResult(
                label: "the Chat tab opens Chat",
                status: .unmet,
                step: 6,
                detail: "no element matching id \"ChatScreen\" appeared within 25.0s"
            )],
            verdict: .unsatisfied,
            mocks: [TestMockOutcome(id: "mock-2", method: "*/GetTabBar", hits: 1, strict: true)],
            evidence: ["logs.jsonl", "network.jsonl", "failure-step-6.png"],
            provenance: TestRunProvenance(
                testFile: "tab_order.yml",
                appBundleId: "com.example.app",
                appVersion: "3.20.0",
                appBuild: "4398",
                commit: "982b9170cc",
                deviceName: "iPhone 16 Pro",
                runtime: "iOS 18.2",
                simtoolVersion: "0.9.0",
                launch: ResolvedLaunch(profile: "staging-account1", arguments: ["-Environment", "stable"])
            )
        )
    }
}
