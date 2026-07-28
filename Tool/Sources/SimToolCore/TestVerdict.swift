import Foundation

/// What a run concluded about the claim its test makes. One vocabulary for both
/// kinds of claim, because the machinery is the same; only the wording differs
/// (see `headline(for:)`).
///
/// The distinction that matters is between `unsatisfied` and `inconclusive`. A
/// run that fell over while staging the scenario proves nothing — reporting it
/// as "the bug reproduces" or "the feature is broken" sends someone to fix the
/// wrong thing.
public enum TestVerdict: String, Codable, Equatable, Sendable, CaseIterable {
    /// Every criterion held. The bug does not reproduce (or is fixed); the
    /// feature is confirmed.
    case satisfied
    /// A criterion did not hold. The bug reproduces; the feature is not done.
    case unsatisfied
    /// The run failed before it could check any criterion, so the claim was
    /// never tested. Fix the test, not the product.
    case inconclusive
    /// The run could not be trusted: a strict mock never fired, a stream the
    /// test asserts on was never armed, the app never picked up its mock rules.
    /// Never reported as a pass.
    case infra

    /// Process exit code. Distinct per verdict so an agent can branch on it
    /// without parsing output: 0 satisfied, 1 unsatisfied, 2 inconclusive,
    /// 3 infra.
    public var exitCode: Int32 {
        switch self {
        case .satisfied: 0
        case .unsatisfied: 1
        case .inconclusive: 2
        case .infra: 3
        }
    }

    /// The session status a run with this verdict is stored under.
    public var sessionStatus: TestSessionStatus {
        self == .satisfied ? .passed : .failed
    }

    /// One line, phrased for what the test is verifying.
    public func headline(for kind: TestKind?) -> String {
        switch (self, kind) {
        case (.satisfied, .bug): "Not reproduced — the expected behaviour holds"
        case (.satisfied, .feature): "Feature confirmed"
        case (.satisfied, nil): "Test passed"
        case (.unsatisfied, .bug): "Bug reproduced"
        case (.unsatisfied, .feature): "Feature not confirmed"
        case (.unsatisfied, nil): "Test failed"
        case (.inconclusive, _): "Inconclusive — the run never reached what it checks"
        case (.infra, _): "Infrastructure problem — the run cannot be trusted"
        }
    }
}

extension TestVerdict {
    /// Decides a run's verdict from what happened. Kept here, pure, because it
    /// is the one rule in the system that must never drift: everything else is
    /// plumbing around this decision.
    ///
    /// - Parameters:
    ///   - kind: nil for a plain test, which has no claim and so keeps the old
    ///     pass/fail behaviour.
    ///   - criteria: the claim's criteria, as the run left them.
    ///   - stagingFailed: a step that was not checking a criterion failed, so
    ///     the scenario never reached the state under test.
    ///   - anyFailure: any step failed at all — the only signal a plain test has.
    ///   - infra: the run could not be trusted.
    public static func decide(
        kind: TestKind?,
        criteria: [TestCriterionResult],
        stagingFailed: Bool,
        anyFailure: Bool,
        infra: Bool
    ) -> TestVerdict {
        // An untrustworthy run must never be reported as a reproduction or a
        // confirmation, in either direction.
        if infra { return .infra }
        guard kind != nil else { return anyFailure ? .unsatisfied : .satisfied }
        // A criterion that was checked and did not hold is a definitive answer,
        // and outranks a staging failure that happened later.
        if criteria.contains(where: { $0.status == .unmet }) { return .unsatisfied }
        if stagingFailed || criteria.contains(where: { $0.status == .unchecked }) { return .inconclusive }
        return .satisfied
    }
}

/// Whether one criterion of the claim held.
public struct TestCriterionResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case met
        case unmet
        /// The run never got as far as this criterion's assertion.
        case unchecked
    }

    public var label: String
    public var status: Status
    /// 1-based index of the step that decided it, when one did.
    public var step: Int?
    /// Why it did not hold.
    public var detail: String?

    public init(label: String, status: Status, step: Int? = nil, detail: String? = nil) {
        self.label = label
        self.status = status
        self.step = step
        self.detail = detail
    }
}

/// A step that did not do what it said.
public struct TestStepFailure: Codable, Equatable, Sendable {
    /// 1-based step index.
    public var step: Int
    public var description: String
    public var message: String
    /// The criterion this step was checking, when it was checking one.
    public var criterion: String?

    public init(step: Int, description: String, message: String, criterion: String? = nil) {
        self.step = step
        self.description = description
        self.message = message
        self.criterion = criterion
    }
}

/// What a declared mock rule did during the run — the answer to "was my mock
/// actually applied?", which otherwise costs a reading of every network event.
public struct TestMockOutcome: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var hits: Int
    public var strict: Bool

    public init(id: String, method: String, hits: Int, strict: Bool) {
        self.id = id
        self.method = method
        self.hits = hits
        self.strict = strict
    }
}

/// How much evidence a run collects.
public enum TestEvidenceLevel: String, Codable, Equatable, Sendable, CaseIterable {
    /// Steps and video only.
    case none
    /// The run's log, network and state streams plus mock outcomes, and a
    /// screenshot and accessibility dump at the point of failure.
    case failure
    /// Also a screenshot and accessibility dump after every step.
    case full
}

/// The machine-readable answer of `simtool test run`: what the run concluded,
/// which criteria decided it, and where the evidence is. Printed with `--json`
/// so an agent never has to parse prose.
public struct TestRunReport: Codable, Equatable, Sendable {
    /// How many runs `--repeat` performed, and how many held the claim.
    public struct Runs: Codable, Equatable, Sendable {
        public var total: Int
        public var satisfied: Int

        public init(total: Int, satisfied: Int) {
            self.total = total
            self.satisfied = satisfied
        }

        /// The claim held in some runs and not others — a fact worth reporting
        /// loudly: an intermittent defect that passes once looks fixed.
        public var isFlaky: Bool { satisfied > 0 && satisfied < total }
    }

    public var verdict: TestVerdict
    public var headline: String
    public var kind: TestKind?
    public var reference: String?
    public var name: String?
    public var file: String?
    public var criteria: [TestCriterionResult]
    public var failures: [TestStepFailure]
    public var mocks: [TestMockOutcome]
    public var completedSteps: Int
    public var totalSteps: Int
    public var runs: Runs?
    /// Recorded session ids, oldest first.
    public var sessions: [String]
    /// Evidence file names written into the last run's session directory.
    public var evidence: [String]
    public var infraReason: String?

    public init(
        verdict: TestVerdict,
        headline: String,
        kind: TestKind? = nil,
        reference: String? = nil,
        name: String? = nil,
        file: String? = nil,
        criteria: [TestCriterionResult] = [],
        failures: [TestStepFailure] = [],
        mocks: [TestMockOutcome] = [],
        completedSteps: Int = 0,
        totalSteps: Int = 0,
        runs: Runs? = nil,
        sessions: [String] = [],
        evidence: [String] = [],
        infraReason: String? = nil
    ) {
        self.verdict = verdict
        self.headline = headline
        self.kind = kind
        self.reference = reference
        self.name = name
        self.file = file
        self.criteria = criteria
        self.failures = failures
        self.mocks = mocks
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.runs = runs
        self.sessions = sessions
        self.evidence = evidence
        self.infraReason = infraReason
    }
}

/// Everything needed to tell where a recorded run came from, so a session can
/// be packaged and replayed elsewhere without guessing.
public struct TestRunProvenance: Codable, Equatable, Sendable {
    /// Verbatim copy of the test file, so the session is readable and runnable
    /// even if the original moves or changes.
    public var testYAML: String?
    public var testFile: String?
    public var appBundleId: String?
    public var appVersion: String?
    public var appBuild: String?
    /// Commit of the project checkout the run happened in, when it is a git
    /// work tree.
    public var commit: String?
    /// A simulator's name *is* its model ("iPhone 16 Pro"), so one field covers
    /// both.
    public var deviceName: String?
    /// The device's iOS runtime, e.g. "iOS 18.2".
    public var runtime: String?
    public var simtoolVersion: String?
    /// The launch actually used, after the profile and inline overrides were
    /// folded together — with `${VAR}` left unexpanded so it carries no secrets.
    public var launch: ResolvedLaunch?

    public init(
        testYAML: String? = nil,
        testFile: String? = nil,
        appBundleId: String? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        commit: String? = nil,
        deviceName: String? = nil,
        runtime: String? = nil,
        simtoolVersion: String? = nil,
        launch: ResolvedLaunch? = nil
    ) {
        self.testYAML = testYAML
        self.testFile = testFile
        self.appBundleId = appBundleId
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.commit = commit
        self.deviceName = deviceName
        self.runtime = runtime
        self.simtoolVersion = simtoolVersion
        self.launch = launch
    }
}
