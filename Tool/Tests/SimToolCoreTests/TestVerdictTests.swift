import SimToolCore
import XCTest

final class TestVerdictTests: XCTestCase {
    private func criterion(_ label: String, _ status: TestCriterionResult.Status) -> TestCriterionResult {
        TestCriterionResult(label: label, status: status)
    }

    func testExitCodesAreDistinctPerVerdict() {
        XCTAssertEqual(TestVerdict.satisfied.exitCode, 0)
        XCTAssertEqual(TestVerdict.unsatisfied.exitCode, 1)
        XCTAssertEqual(TestVerdict.inconclusive.exitCode, 2)
        XCTAssertEqual(TestVerdict.infra.exitCode, 3)
        XCTAssertEqual(Set(TestVerdict.allCases.map(\.exitCode)).count, TestVerdict.allCases.count)
    }

    func testOnlySatisfiedIsAPassingSession() {
        XCTAssertEqual(TestVerdict.satisfied.sessionStatus, .passed)
        for verdict in TestVerdict.allCases where verdict != .satisfied {
            XCTAssertEqual(verdict.sessionStatus, .failed, "\(verdict) must not be recorded as passed")
        }
    }

    func testHeadlineReadsForWhatIsVerified() {
        XCTAssertEqual(TestVerdict.unsatisfied.headline(for: .bug), "Bug reproduced")
        XCTAssertEqual(TestVerdict.unsatisfied.headline(for: .feature), "Feature not confirmed")
        XCTAssertEqual(TestVerdict.satisfied.headline(for: .feature), "Feature confirmed")
        XCTAssertEqual(TestVerdict.satisfied.headline(for: nil), "Test passed")
    }

    func testAllCriteriaMetIsSatisfied() {
        XCTAssertEqual(
            TestVerdict.decide(
                kind: .feature,
                criteria: [criterion("AC-1", .met), criterion("AC-2", .met)],
                stagingFailed: false,
                anyFailure: false,
                infra: false
            ),
            .satisfied
        )
    }

    func testUnmetCriterionIsUnsatisfied() {
        XCTAssertEqual(
            TestVerdict.decide(
                kind: .bug,
                criteria: [criterion("AC-1", .unmet)],
                stagingFailed: false,
                anyFailure: true,
                infra: false
            ),
            .unsatisfied
        )
    }

    /// The distinction the whole model exists for: a run that fell over while
    /// staging never tested the claim, so it must not be reported as a
    /// reproduction.
    func testStagingFailureIsInconclusiveNotUnsatisfied() {
        XCTAssertEqual(
            TestVerdict.decide(
                kind: .bug,
                criteria: [criterion("AC-1", .unchecked)],
                stagingFailed: true,
                anyFailure: true,
                infra: false
            ),
            .inconclusive
        )
    }

    func testUncheckedCriterionIsInconclusive() {
        XCTAssertEqual(
            TestVerdict.decide(
                kind: .feature,
                criteria: [criterion("AC-1", .met), criterion("AC-2", .unchecked)],
                stagingFailed: false,
                anyFailure: false,
                infra: false
            ),
            .inconclusive
        )
    }

    /// A definitive negative outranks a later staging failure: the claim was
    /// checked and it did not hold.
    func testUnmetOutranksStagingFailure() {
        XCTAssertEqual(
            TestVerdict.decide(
                kind: .feature,
                criteria: [criterion("AC-1", .unmet), criterion("AC-2", .unchecked)],
                stagingFailed: true,
                anyFailure: true,
                infra: false
            ),
            .unsatisfied
        )
    }

    /// An untrustworthy run must never come out as a reproduction — nor as a
    /// pass, which is the direction that would let a fixing agent believe the
    /// bug is gone.
    func testInfraOutranksEverything() {
        for criteria in [[criterion("AC-1", .met)], [criterion("AC-1", .unmet)], [criterion("AC-1", .unchecked)]] {
            XCTAssertEqual(
                TestVerdict.decide(
                    kind: .bug,
                    criteria: criteria,
                    stagingFailed: false,
                    anyFailure: false,
                    infra: true
                ),
                .infra
            )
        }
    }

    func testPlainTestKeepsPassFailBehaviour() {
        XCTAssertEqual(
            TestVerdict.decide(kind: nil, criteria: [], stagingFailed: false, anyFailure: false, infra: false),
            .satisfied
        )
        XCTAssertEqual(
            TestVerdict.decide(kind: nil, criteria: [], stagingFailed: true, anyFailure: true, infra: false),
            .unsatisfied
        )
    }

    func testFlakyRunsAreReportedAsSuch() {
        XCTAssertTrue(TestRunReport.Runs(total: 10, satisfied: 3).isFlaky)
        XCTAssertFalse(TestRunReport.Runs(total: 10, satisfied: 0).isFlaky)
        XCTAssertFalse(TestRunReport.Runs(total: 10, satisfied: 10).isFlaky)
    }
}
