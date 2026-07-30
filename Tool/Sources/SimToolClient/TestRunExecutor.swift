import Foundation
import SimToolCore
import SimToolNetworkLogger
import SimToolStateLogger

/// Everything a run needs that the test file itself does not carry.
public struct TestRunOptions: Sendable {
    /// Session title; defaults to the test's name, then the file name.
    public var title: String?
    /// The test file, for provenance and a readable session title.
    public var testFile: URL?
    public var video: Bool
    /// Record a reviewable session at all. Off means no video, no evidence and
    /// no timeline — only the verdict.
    public var recordSession: Bool
    public var evidence: TestEvidenceLevel
    /// Launch profiles `launch.profile` may name.
    public var profiles: [LaunchProfile]
    /// Bundle id to launch and scope logs to when the test names none.
    public var defaultApp: String?
    /// Where the app should post logger events. Setting it arms the app-side
    /// network and state loggers for the run, which is what makes mock
    /// verification and network evidence possible at all.
    public var appFacingServerURL: String?
    /// Checkout the run happens in, for the provenance commit.
    public var projectRoot: URL?
    /// Where `${VAR}` values come from when the test does not define them
    /// itself. The test's own `variables:` win over this; see
    /// `TestDefinition.resolvedVariables`.
    public var variables: [String: String]
    /// `--var NAME=value`: wins over both the test file and the environment, so
    /// a received test can be run as a different account without editing it.
    public var variableOverrides: [String: String]
    /// How long to wait for the app to confirm it applied the run's mock rules.
    public var mockAckTimeoutSeconds: Double
    /// Brings the app under test up to date — build if the sources changed,
    /// install if the build did — before the scenario is staged and before the
    /// recorder starts. Injected rather than done here because building is the
    /// CLI's business and the executor must stay driveable from the viewer.
    /// Nil takes whatever is installed on the device as the build to judge.
    public var prepareApp: (@Sendable () async throws -> Void)?

    public init(
        title: String? = nil,
        testFile: URL? = nil,
        video: Bool = true,
        recordSession: Bool = true,
        evidence: TestEvidenceLevel = .failure,
        profiles: [LaunchProfile] = [],
        defaultApp: String? = nil,
        appFacingServerURL: String? = nil,
        projectRoot: URL? = nil,
        variables: [String: String] = ProcessInfo.processInfo.environment,
        variableOverrides: [String: String] = [:],
        mockAckTimeoutSeconds: Double = 20,
        prepareApp: (@Sendable () async throws -> Void)? = nil
    ) {
        self.title = title
        self.testFile = testFile
        self.video = video
        self.recordSession = recordSession
        self.evidence = evidence
        self.profiles = profiles
        self.defaultApp = defaultApp
        self.appFacingServerURL = appFacingServerURL
        self.projectRoot = projectRoot
        self.variables = variables
        self.variableOverrides = variableOverrides
        self.mockAckTimeoutSeconds = mockAckTimeoutSeconds
        self.prepareApp = prepareApp
    }
}

/// What a run concluded, in the shape both the CLI and the web viewer report.
public struct TestRunResult: Sendable {
    public var verdict: TestVerdict
    public var kind: TestKind?
    public var criteria: [TestCriterionResult]
    public var failures: [TestStepFailure]
    public var mocks: [TestMockOutcome]
    public var completedSteps: Int
    public var totalSteps: Int
    public var session: TestSession?
    public var evidence: [String]
    /// Why the run could not be trusted, when the verdict is `infra`.
    public var infraReason: String?
    /// The run was stopped from outside (the viewer's Stop, Ctrl-C).
    public var cancelled: Bool

    public init(
        verdict: TestVerdict,
        kind: TestKind? = nil,
        criteria: [TestCriterionResult] = [],
        failures: [TestStepFailure] = [],
        mocks: [TestMockOutcome] = [],
        completedSteps: Int = 0,
        totalSteps: Int = 0,
        session: TestSession? = nil,
        evidence: [String] = [],
        infraReason: String? = nil,
        cancelled: Bool = false
    ) {
        self.verdict = verdict
        self.kind = kind
        self.criteria = criteria
        self.failures = failures
        self.mocks = mocks
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.session = session
        self.evidence = evidence
        self.infraReason = infraReason
        self.cancelled = cancelled
    }

    /// The single line worth printing first.
    public func headline() -> String { verdict.headline(for: kind) }
}

/// Runs one declarative test end to end: stages the scenario the test asks for,
/// drives its steps, collects the evidence that explains what happened, and
/// turns all of it into a verdict.
///
/// It never throws. Every way a run can go wrong is a verdict — that is the
/// point of the type: a caller should not have to decide whether a thrown error
/// means "the claim does not hold" or "the run was broken", because confusing
/// those two is what sends people to fix the wrong thing.
public final class TestRunExecutor: @unchecked Sendable {
    public var onNarration: (@Sendable (String) -> Void)?
    public var onProgress: (@Sendable (Int, Int) -> Void)?
    public var onSessionStarted: (@Sendable (TestSession) -> Void)?

    private let client: SimToolClient
    private let options: TestRunOptions

    private var sessionId: String?
    private var evidenceDirectory: URL?
    /// The run's own directory. Unlike `evidenceDirectory` this is not gated on
    /// the evidence level: `report.md` is the one artifact written for a person,
    /// and `--evidence none` is a statement about captures, not about that.
    private var sessionDirectory: URL?
    /// `${VAR}` the test refers to without defining, for the report's
    /// "what you have to supply" section.
    private var requiredVariables: [String] = []
    private var evidenceFiles: [String] = []
    private var logCursor: Int?
    private var stateCursor: Int?
    private var collectedLogs: [LogEntry] = []
    private var collectedState: [StateLoggerEvent] = []
    private var runStartedAt = NetworkLoggerTimestamp.now()
    /// When the run launched the app, for the staleness check below.
    private var launchedAt: Date?
    /// How many log lines had been collected when the capture was re-armed
    /// after that launch. Nothing arriving afterwards means the capture is dead
    /// and `logs.jsonl` documents only the pre-launch window.
    private var logsCapturedBeforeLaunch: Int?
    /// Timeline entries from the staging phase, which runs before the session
    /// exists; replayed into it the moment it does.
    private var stagedNotes: [TestSessionEntryRequest] = []

    public init(client: SimToolClient, options: TestRunOptions) {
        self.client = client
        self.options = options
    }

    // MARK: - run

    public func run(_ test: TestDefinition) async -> TestRunResult {
        var criteria = test.criteria.map { TestCriterionResult(label: $0, status: .unchecked) }
        var failures: [TestStepFailure] = []
        var declaredMocks: [(id: String, method: String, strict: Bool)] = []

        // Anything that goes wrong before the first step means the claim was
        // never tested, so it is reported as infra or inconclusive — never as a
        // failing claim.
        let config: ServerConfigPayload
        do {
            config = try await client.config()
        } catch {
            return TestRunResult(
                verdict: .infra,
                kind: test.kind,
                criteria: criteria,
                totalSteps: test.steps.count,
                // No period of our own: URLError's description already ends in one.
                infraReason: "Cannot reach the SimTool server: \(message(of: error)) Start one with `simtool serve`, or pass --server."
            )
        }

        let app = (test.app ?? options.defaultApp).flatMap { $0.isEmpty ? nil : $0 }
        let launch: ResolvedLaunch
        let recordedLaunch: ResolvedLaunch
        do {
            (launch, recordedLaunch) = try resolveLaunch(test)
            requiredVariables = LaunchVariables.names(in: recordedLaunch, setup: test.setup)
                .filter { test.variables[$0] == nil }
        } catch {
            return TestRunResult(
                verdict: .infra,
                kind: test.kind,
                criteria: criteria,
                totalSteps: test.steps.count,
                infraReason: message(of: error)
            )
        }

        // 0 — the build to judge. A verdict is only meaningful next to the code
        // that produced it, so the app is brought up to date first — and before
        // the recorder starts, because a video of an Xcode build is not what
        // anyone opens a test session to watch.
        if let prepareApp = options.prepareApp {
            do {
                try await prepareApp()
            } catch {
                return TestRunResult(
                    verdict: .infra,
                    kind: test.kind,
                    criteria: criteria,
                    totalSteps: test.steps.count,
                    infraReason: "Could not build the app under test: \(message(of: error))"
                )
            }
        }

        // Log capture is armed before the staging and scoped to this run: the
        // capture buffer is reset by arming, so everything it holds afterwards
        // belongs to the run — including what a `setup:` launch logged, which is
        // off camera but still evidence. stdout is deliberately not captured: the
        // server would have to relaunch the app to attach a console, and this run
        // launches the app itself.
        if let app, options.evidence != .none {
            do {
                _ = try await client.startLogCapture(device: config.udid, app: app, captureStdout: false)
            } catch {
                await narrate("Log capture not armed: \(message(of: error))")
            }
        }
        runStartedAt = NetworkLoggerTimestamp.now()

        // 1 — reset simulator state.
        if !test.reset.isEmpty {
            let outcome = await SimulatorStateReset.apply(test.reset, deviceUDID: config.udid, app: app)
            if !outcome.applied.isEmpty { await note(outcome.applied.map { "Reset: \($0)" }) }
            if !outcome.isClean {
                return await finish(
                    verdict: .infra,
                    test: test,
                    criteria: criteria,
                    failures: failures,
                    mocks: [],
                    completedSteps: 0,
                    session: nil,
                    infraReason: "`reset:` could not be applied: " + outcome.failures.joined(separator: "; ")
                )
            }
        }

        // 2 — clear leftover mock rules before anything else runs. A rule left
        // over from a manual session would answer calls this test never
        // accounted for — including calls made by `setup:`, which often warms
        // state up against the real backend precisely so the run can then change
        // one answer. Only tests that declare mocks touch the store, so a manual
        // exploration session running an unrelated test keeps its rules.
        if !test.mocks.isEmpty {
            do {
                _ = try await client.clearMocks()
            } catch {
                return await finish(
                    verdict: .infra,
                    test: test,
                    criteria: criteria,
                    failures: failures,
                    mocks: [],
                    completedSteps: 0,
                    session: nil,
                    infraReason: "Cannot clear existing mock rules: \(message(of: error))"
                )
            }
        }

        // 3 — setup shell. Kept non-fatal on purpose: these commands mostly
        // delete state that may not exist yet.
        for (index, command) in test.setup.enumerated() {
            let status = await runSetupCommand(command, udid: config.udid, app: app, variables: variables(for: test))
            await narrate("Setup \(index + 1)/\(test.setup.count) (\(status)): \(command.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // 4 — start recording. Deliberately after the staging: `setup:` is where
        // a scenario is warmed up — a login, a first launch, a wait — and none of
        // that is what someone opens the video to watch. The staging still shows
        // up in the timeline: the notes above were buffered and are replayed into
        // the session here, so a `Setup n/n (exit 1)` is still there to be read
        // before a verdict is trusted.
        var session: TestSession?
        if options.recordSession {
            do {
                session = try await client.startTestSession(TestSessionStartRequest(
                    title: options.title ?? test.name ?? options.testFile?.deletingPathExtension().lastPathComponent ?? "test",
                    // The viewer keys its list on the file name, so this is what
                    // lets it show the run against the test it belongs to.
                    file: options.testFile?.lastPathComponent,
                    video: options.video,
                    kind: test.kind,
                    reference: test.reference,
                    criteria: test.criteria,
                    provenance: await provenance(test, config: config, app: app, launch: recordedLaunch)
                ))
                sessionId = session?.id
                if let session {
                    onSessionStarted?(session)
                    if let root = config.testSessionsPath {
                        sessionDirectory = URL(fileURLWithPath: root).appendingPathComponent(session.id, isDirectory: true)
                        if options.evidence != .none { evidenceDirectory = sessionDirectory }
                    }
                    await flushStagingNotes()
                }
            } catch {
                // A busy session or a dead recorder must not swallow the run;
                // report it and carry on without a timeline.
                await narrate("Session not recorded: \(message(of: error))")
            }
        }

        // 5 — install the test's mock rules, after setup and before launch, so
        // the app's very first poll already has them.
        var mockGeneration: Int?
        if !test.mocks.isEmpty {
            do {
                for mock in test.mocks {
                    let created = try await client.setMock(mock.draft)
                    declaredMocks.append((id: created.id, method: mock.draft.match.method, strict: mock.strict))
                    mockGeneration = created.generation
                }
                await narrate("Applied \(test.mocks.count) mock rule\(test.mocks.count == 1 ? "" : "s")")
            } catch {
                return await finish(
                    verdict: .infra,
                    test: test,
                    criteria: criteria,
                    failures: failures,
                    mocks: [],
                    completedSteps: 0,
                    session: session,
                    infraReason: "Cannot install the test's mock rules: \(message(of: error))"
                )
            }
        }

        // 6 — launch.
        if let app {
            do {
                try await launchApp(app, launch: launch, udid: config.udid)
                launchedAt = Date()
                await rearmLogCapture(app: app, udid: config.udid)
                // The recorded launch, not the one used: the timeline is part of
                // the artifact, and an artifact that quotes the expanded argv
                // carries the account it logged in with to whoever it is sent to.
                let rendered = recordedLaunch.arguments.isEmpty ? "" : " " + recordedLaunch.arguments.joined(separator: " ")
                await narrate("Launched \(app)\(rendered)")
                if let deeplink = launch.deeplink, !deeplink.isEmpty {
                    try await openDeeplink(deeplink, udid: config.udid)
                    await narrate("Opened \(recordedLaunch.deeplink ?? deeplink)")
                }
            } catch {
                return await finish(
                    verdict: .infra,
                    test: test,
                    criteria: criteria,
                    failures: failures,
                    mocks: [],
                    completedSteps: 0,
                    session: session,
                    infraReason: message(of: error)
                )
            }
        }

        // 6 — wait until the app confirms it holds the rules. Without this the
        // first call of the run can still reach the real backend, and the test
        // would be measuring something nobody declared.
        if let mockGeneration {
            if let reason = await waitForMocks(generation: mockGeneration) {
                return await finish(
                    verdict: .infra,
                    test: test,
                    criteria: criteria,
                    failures: failures,
                    mocks: declaredMocks.map { TestMockOutcome(id: $0.id, method: $0.method, hits: 0, strict: $0.strict) },
                    completedSteps: 0,
                    session: session,
                    infraReason: reason
                )
            }
        }

        // 7 — steps.
        let runner = TestRunner(
            client: client,
            udid: config.udid,
            screenWidth: Double(config.width),
            screenHeight: Double(config.height),
            defaultTimeout: test.stepTimeout
        )
        var completedSteps = 0
        var stagingFailed = false
        var cancelled = false

        for (index, step) in test.steps.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            let cursorFrom = logCursor
            do {
                try await runner.execute(step.action)
                await drainStreams()
                await record(
                    "✓ \(index + 1)/\(test.steps.count) \(step)",
                    criterion: step.criterion,
                    cursorFrom: cursorFrom
                )
                completedSteps = index + 1
                onProgress?(completedSteps, test.steps.count)
                if let criterion = step.criterion {
                    criteria = mark(criteria, label: criterion, status: .met, step: index + 1, detail: nil)
                }
                if options.evidence == .full {
                    await captureScreen(prefix: "step-\(index + 1)")
                }
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                if Task.isCancelled { cancelled = true; break }
                let detail = message(of: error)
                await drainStreams()
                await record(
                    "✗ \(index + 1)/\(test.steps.count) \(step) — \(detail)",
                    criterion: step.criterion,
                    cursorFrom: cursorFrom
                )
                failures.append(TestStepFailure(
                    step: index + 1,
                    description: step.description,
                    message: detail,
                    criterion: step.criterion
                ))
                await attachFailureContext(runner: runner, step: step, index: index)
                if let criterion = step.criterion {
                    criteria = mark(criteria, label: criterion, status: .unmet, step: index + 1, detail: detail)
                    // A bug's reproduction is complete at the first unmet
                    // criterion; a feature's report is not — one run should say
                    // which of its criteria hold.
                    if test.kind != .feature { break }
                } else {
                    // The scenario itself broke, so nothing downstream proves
                    // anything about the claim.
                    stagingFailed = true
                    break
                }
            }
        }

        if cancelled {
            await drainStreams()
            let evidence = await collectEvidence(test: test, app: app, declaredMocks: declaredMocks)
            let stopped = await stopSession(status: .interrupted, verdict: .inconclusive, criteria: criteria, mocks: evidence.mocks, detached: true)
            await writeReport(stopped, test: test)
            return TestRunResult(
                verdict: .inconclusive,
                kind: test.kind,
                criteria: criteria,
                failures: failures,
                mocks: evidence.mocks,
                completedSteps: completedSteps,
                totalSteps: test.steps.count,
                session: session,
                evidence: evidenceFiles,
                infraReason: nil,
                cancelled: true
            )
        }

        // 8 — evidence and mock outcomes decide whether the run can be trusted
        // at all, so they are gathered before the verdict.
        let evidence = await collectEvidence(test: test, app: app, declaredMocks: declaredMocks)
        var infraReason: String?
        if let unfired = evidence.mocks.first(where: { $0.strict && $0.hits == 0 }) {
            infraReason = evidence.sawNetworkEvents
                ? "Strict mock `\(unfired.method)` never intercepted a call. Check the method path against `simtool network events --protocol grpc`, and that a `body:` decodes into the method's response type — a body the app cannot decode is ignored and the real backend answers."
                : "Strict mock `\(unfired.method)` never fired and the app reported no network events at all. Launch with the network logger armed (`SIMTOOL_NETWORK_LOGGER=1`, `SIMTOOL_SERVER_URL=…`) and make sure the build links SimToolNetworkLogger."
        }

        let verdict = decide(
            test: test,
            criteria: criteria,
            failures: failures,
            stagingFailed: stagingFailed,
            infraReason: infraReason
        )
        return await finish(
            verdict: verdict,
            test: test,
            criteria: criteria,
            failures: failures,
            mocks: evidence.mocks,
            completedSteps: completedSteps,
            session: session,
            infraReason: infraReason
        )
    }

    // MARK: - verdict

    private func decide(
        test: TestDefinition,
        criteria: [TestCriterionResult],
        failures: [TestStepFailure],
        stagingFailed: Bool,
        infraReason: String?
    ) -> TestVerdict {
        TestVerdict.decide(
            kind: test.kind,
            criteria: criteria,
            stagingFailed: stagingFailed,
            anyFailure: !failures.isEmpty,
            infra: infraReason != nil
        )
    }

    private func mark(
        _ criteria: [TestCriterionResult],
        label: String,
        status: TestCriterionResult.Status,
        step: Int?,
        detail: String?
    ) -> [TestCriterionResult] {
        criteria.map { criterion in
            guard criterion.label == label else { return criterion }
            // Several assertions may carry the same label; the claim holds only
            // if all of them do, so a recorded failure is never overwritten by a
            // later pass.
            if criterion.status == .unmet { return criterion }
            return TestCriterionResult(label: label, status: status, step: step, detail: detail)
        }
    }

    // MARK: - staging

    private func variables(for test: TestDefinition) -> [String: String] {
        test.resolvedVariables(environment: options.variables, overrides: options.variableOverrides)
    }

    /// Returns the launch to use and the one to record. They differ by
    /// `${VAR}` expansion: the timeline must not repeat a value the test either
    /// deliberately keeps in the shell or already states once in `variables:`.
    private func resolveLaunch(_ test: TestDefinition) throws -> (used: ResolvedLaunch, recorded: ResolvedLaunch) {
        var profile: LaunchProfile?
        if let name = test.launch.profile, !name.isEmpty {
            guard let match = options.profiles.first(where: { $0.name == name }) else {
                let available = options.profiles.map(\.name).joined(separator: ", ")
                let hint = available.isEmpty
                    ? " No `profiles:` are defined in the project config."
                    : " Available: \(available)."
                throw SimToolError("Unknown launch profile '\(name)'.\(hint)")
            }
            profile = match
        }
        var recorded = test.launch.resolved(profile: profile)
        recorded.arguments = test.reset.launchArguments + recorded.arguments
        let used = try recorded.resolvingVariables(using: variables(for: test), context: "launch")
        return (used, recorded)
    }

    private func launchApp(_ app: String, launch: ResolvedLaunch, udid: String) async throws {
        var environment = launch.environment
        // Arming the loggers is what makes mock verification and network
        // evidence possible, so the run does it unless the test set the
        // variables itself.
        if let serverURL = options.appFacingServerURL {
            environment["SIMTOOL_SERVER_URL"] = environment["SIMTOOL_SERVER_URL"] ?? serverURL
            environment["SIMTOOL_NETWORK_LOGGER"] = environment["SIMTOOL_NETWORK_LOGGER"] ?? "1"
            environment["SIMTOOL_STATE_LOGGER"] = environment["SIMTOOL_STATE_LOGGER"] ?? "1"
        }
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: SimulatorAppLifecycleClient.simctlLaunchArguments(
                deviceUDID: udid,
                bundleIdentifier: app,
                launchArguments: launch.arguments
            ),
            environment: SimulatorAppLifecycleClient.simctlChildEnvironment(launchEnvironment: environment),
            timeoutSeconds: 120
        )
        guard output.status == 0 else {
            throw SimToolError("simctl launch \(app) failed: \(output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func openDeeplink(_ url: String, udid: String) async throws {
        let output = try await ProcessRunner.runXcrun(["simctl", "openurl", udid, url])
        guard output.status == 0 else {
            throw SimToolError("simctl openurl \(url) failed: \(output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// `{udid}`, `{app}` and `{server}` filled in. `{server}` is left standing
    /// when there is no address to put there, so a broken flag is visible in the
    /// recorded command instead of silently becoming `--server ` with nothing
    /// after it.
    static func renderSetup(_ command: String, udid: String, app: String?, server: String?) -> String {
        var rendered = command
            .replacingOccurrences(of: "{udid}", with: udid)
            .replacingOccurrences(of: "{app}", with: app ?? "")
        if let server = address(server) {
            rendered = rendered.replacingOccurrences(of: "{server}", with: server)
        }
        return rendered
    }

    /// One spelling for a server address. The client's root URL renders with a
    /// trailing slash, which reads wrong in a command and breaks the moment
    /// somebody appends a path to it.
    private static func address(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var trimmed = raw
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The environment a setup command runs in: the test's own `variables:`, plus
    /// where this run's server is.
    ///
    /// A scenario whose state changes inside one process needs two launches, and
    /// the first one lives in `setup:`. Since a run may start its own server on a
    /// port it picks, no port is knowable when the test is written — so without
    /// these the only way to reach the server from `setup:` is to hardcode one,
    /// which is what stops the file from travelling to another machine.
    ///
    /// `SIMTOOL_SERVER` is the address for `--server`; `SIMTOOL_SERVER_URL` is the
    /// one the app must post to, which differs whenever the server binds a LAN
    /// address. The test's own values win: a file that sets either name means it.
    static func setupEnvironment(
        variables: [String: String],
        server: String?,
        appFacingServer: String?
    ) -> [String: String] {
        var environment = variables
        if let server = address(server), environment["SIMTOOL_SERVER"] == nil {
            environment["SIMTOOL_SERVER"] = server
        }
        if let appFacingServer = address(appFacingServer), environment["SIMTOOL_SERVER_URL"] == nil {
            environment["SIMTOOL_SERVER_URL"] = appFacingServer
        }
        return environment
    }

    /// Setup commands reset persisted state before launch (delete a defaults
    /// key, clear a container), so a non-zero exit — the key not existing on a
    /// first run — is reported but never fails the test.
    private func runSetupCommand(_ command: String, udid: String, app: String?, variables: [String: String]) async -> String {
        let rendered = Self.renderSetup(command, udid: udid, app: app, server: client.rootURL.absoluteString)
        do {
            let output = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", rendered],
                // The test's own `variables:` are exported to the shell too, so
                // `$ACCOUNT` in a setup command means the same thing it means in
                // a launch argument.
                environment: Self.setupEnvironment(
                    variables: variables,
                    server: client.rootURL.absoluteString,
                    appFacingServer: options.appFacingServerURL
                ),
                timeoutSeconds: 60
            )
            return output.status == 0 ? "ok" : "exit \(output.status)"
        } catch {
            return "error: \(message(of: error))"
        }
    }

    /// Polls until an app confirms it applied `generation`. Returns nil on
    /// success, or the reason it never happened.
    private func waitForMocks(generation: Int) async -> String? {
        let deadline = ContinuousClock.now + .milliseconds(Int(options.mockAckTimeoutSeconds * 1000))
        var lastPollSeen = false
        while true {
            if Task.isCancelled { return nil }
            if let ack = try? await client.mockAcknowledgement() {
                if (ack.acknowledged ?? -1) >= generation { return nil }
                if ack.lastPollAt != nil { lastPollSeen = true }
            }
            guard ContinuousClock.now < deadline else {
                return lastPollSeen
                    ? "The app polled for mock rules but never confirmed generation \(generation) within \(Int(options.mockAckTimeoutSeconds))s."
                    : "The app never polled for mock rules within \(Int(options.mockAckTimeoutSeconds))s. Its network logger is not running: launch with `SIMTOOL_NETWORK_LOGGER=1` and `SIMTOOL_SERVER_URL`, and make sure the build links SimToolNetworkLogger."
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    // MARK: - evidence

    private struct EvidenceOutcome {
        var mocks: [TestMockOutcome] = []
        var sawNetworkEvents = false
    }

    /// Re-arms the log capture after the run launched the app, and resets the
    /// cursor because arming starts a fresh buffer.
    ///
    /// Cold-launching the app kills the running capture — measured, not
    /// theorised: a run's `logs.jsonl` otherwise ends one second before the
    /// launch it is supposed to document, and the per-step cursors then never
    /// advance. Whatever was captured before the launch (a `setup:` that warmed
    /// state up, an earlier launch) is drained first, so re-arming adds the
    /// run's own window instead of replacing the story with it.
    private func rearmLogCapture(app: String, udid: String) async {
        guard options.evidence != .none else { return }
        await drainStreams()
        do {
            _ = try await client.startLogCapture(device: udid, app: app, captureStdout: false)
            logCursor = nil
            logsCapturedBeforeLaunch = collectedLogs.count
        } catch {
            await narrate("Log capture not re-armed after launch: \(message(of: error))")
        }
    }

    /// Drains the cursor-based streams into the run's own buffers. Called at
    /// every step boundary rather than once at the end: the capture buffer is
    /// bounded, so a long run would lose its early lines — the ones that
    /// usually explain the failure.
    private func drainStreams() async {
        guard options.evidence != .none else { return }
        if let payload = try? await client.logCaptureEntries(since: logCursor, limit: 1000) {
            collectedLogs.append(contentsOf: payload.entries)
            logCursor = payload.cursor
        }
        if let payload = try? await client.stateLoggerEvents(since: stateCursor, limit: 1000) {
            collectedState.append(contentsOf: payload.events)
            stateCursor = payload.nextCursor
        }
    }

    private func collectEvidence(
        test: TestDefinition,
        app: String?,
        declaredMocks: [(id: String, method: String, strict: Bool)]
    ) async -> EvidenceOutcome {
        var outcome = EvidenceOutcome()
        // Mock outcomes are read from the network events, which is the only
        // place that knows what the app actually answered with.
        var events: [NetworkLoggerEvent] = []
        if !declaredMocks.isEmpty || options.evidence != .none {
            events = (try? await client.networkLoggerEvents(app: app, since: runStartedAt, limit: 2000))?.events ?? []
        }
        outcome.sawNetworkEvents = !events.isEmpty
        outcome.mocks = declaredMocks.map { declared in
            TestMockOutcome(
                id: declared.id,
                method: declared.method,
                hits: events.filter { $0.mocked && $0.mockRuleId == declared.id }.count,
                strict: declared.strict
            )
        }

        guard options.evidence != .none, let directory = evidenceDirectory else { return outcome }
        await drainStreams()
        // Stale evidence is worse than none: it reads like the run's own logs.
        if let before = logsCapturedBeforeLaunch, collectedLogs.count == before, launchedAt != nil {
            await note(["No log lines arrived after the app was launched — the capture died, so logs.jsonl covers only the window before the launch."])
        }
        write(jsonLines: collectedLogs, to: directory, named: "logs.jsonl")
        write(jsonLines: events, to: directory, named: "network.jsonl")
        write(jsonLines: collectedState, to: directory, named: "state.jsonl")
        if !test.mocks.isEmpty {
            write(json: outcome.mocks, to: directory, named: "mocks.json")
        }
        return outcome
    }

    private func attachFailureContext(runner: TestRunner, step: TestStep, index: Int) async {
        var lines: [String] = []
        let screen = await runner.visibleSummary()
        if !screen.isEmpty { lines += ["On screen:"] + screen }
        if case .waitFor(let target, _) = step.action {
            let nearest = await runner.nearestTargets(to: target)
            if !nearest.isEmpty { lines += ["Closest matches: " + nearest.joined(separator: ", ")] }
        }
        if case .tap(let target, _) = step.action {
            let nearest = await runner.nearestTargets(to: target)
            if !nearest.isEmpty { lines += ["Closest matches: " + nearest.joined(separator: ", ")] }
        }
        if options.evidence != .none {
            if let name = await captureScreen(prefix: "failure-step-\(index + 1)") {
                lines.append("Screenshot: \(name)")
            }
            if let directory = evidenceDirectory, !screen.isEmpty {
                let name = "failure-step-\(index + 1)-ax.txt"
                try? screen.joined(separator: "\n").write(
                    to: directory.appendingPathComponent(name),
                    atomically: true,
                    encoding: .utf8
                )
                evidenceFiles.append(name)
            }
        }
        if !lines.isEmpty { await note(lines) }
    }

    @discardableResult
    private func captureScreen(prefix: String) async -> String? {
        guard let directory = evidenceDirectory, let data = try? await client.screenshot() else { return nil }
        let name = "\(prefix).png"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
            evidenceFiles.append(name)
            return name
        } catch {
            return nil
        }
    }

    private func write<T: Encodable>(jsonLines items: [T], to directory: URL, named name: String) {
        guard !items.isEmpty else { return }
        let lines = items.compactMap { item -> String? in
            guard let data = try? JSON.data(item, pretty: false) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard !lines.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(
                to: directory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
            evidenceFiles.append(name)
        } catch {
            // Evidence is worth attempting, never worth failing a run over.
        }
    }

    private func write<T: Encodable>(json value: T, to directory: URL, named name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSON.data(value).write(to: directory.appendingPathComponent(name))
            evidenceFiles.append(name)
        } catch {}
    }

    // MARK: - provenance

    private func provenance(
        _ test: TestDefinition,
        config: ServerConfigPayload,
        app: String?,
        launch: ResolvedLaunch
    ) async -> TestRunProvenance {
        var provenance = TestRunProvenance(
            // Relative to the project, so the report's re-run snippet is one a
            // receiver can paste from the project root.
            testFile: options.testFile.map { TestFilePath.display(file: $0, projectRoot: options.projectRoot) },
            appBundleId: app,
            deviceName: config.device,
            runtime: (try? await client.devices())?.devices.first { $0.udid == config.udid }?.runtime,
            simtoolVersion: SimToolVersion.current,
            launch: launch.isEmpty ? nil : launch
        )
        if let file = options.testFile {
            provenance.testYAML = try? String(contentsOf: file, encoding: .utf8)
        }
        if let app, let bundle = await InstalledAppBundle.read(app: app, udid: config.udid) {
            provenance.appVersion = bundle.version
            provenance.appBuild = bundle.build
        }
        provenance.commit = await gitCommit()
        return provenance
    }

    private func gitCommit() async -> String? {
        guard let root = options.projectRoot else { return nil }
        guard let output = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", root.path, "rev-parse", "HEAD"],
            timeoutSeconds: 15
        ), output.status == 0 else { return nil }
        let commit = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    // MARK: - session plumbing

    private func finish(
        verdict: TestVerdict,
        test: TestDefinition,
        criteria: [TestCriterionResult],
        failures: [TestStepFailure],
        mocks: [TestMockOutcome],
        completedSteps: Int,
        session: TestSession?,
        infraReason: String?
    ) async -> TestRunResult {
        if let infraReason { await note([infraReason]) }
        let stopped = await stopSession(
            status: verdict.sessionStatus,
            verdict: verdict,
            criteria: criteria,
            mocks: mocks,
            detached: false
        )
        await writeReport(stopped, test: test)
        return TestRunResult(
            verdict: verdict,
            kind: test.kind,
            criteria: criteria,
            failures: failures,
            mocks: mocks,
            completedSteps: completedSteps,
            totalSteps: test.steps.count,
            session: stopped ?? session,
            evidence: evidenceFiles,
            infraReason: infraReason
        )
    }

    /// Written after the session is stopped, because that response is where the
    /// finalized video length lives — and the report's timeline is in video time.
    private func writeReport(_ stopped: TestSession?, test: TestDefinition) async {
        guard let stopped, let directory = sessionDirectory else { return }
        do {
            try TestReportWriter.write(
                session: stopped,
                definition: test,
                requiredVariables: requiredVariables,
                into: directory
            )
        } catch {
            await note(["Report not written: \(message(of: error))"])
        }
    }

    @discardableResult
    private func stopSession(
        status: TestSessionStatus,
        verdict: TestVerdict,
        criteria: [TestCriterionResult],
        mocks: [TestMockOutcome],
        detached: Bool
    ) async -> TestSession? {
        guard sessionId != nil else { return nil }
        let request = TestSessionStopRequest(
            status: status,
            verdict: verdict,
            criteria: criteria,
            mocks: mocks,
            evidence: evidenceFiles
        )
        let client = self.client
        guard detached else { return try? await client.stopTestSession(request) }
        // A cancelled task cannot make HTTP calls, so closing the session has to
        // happen somewhere cancellation does not reach.
        return await Task.detached { try? await client.stopTestSession(request) }.value
    }

    private func record(_ text: String, criterion: String?, cursorFrom: Int?) async {
        onNarration?(text)
        guard sessionId != nil else { return }
        _ = try? await client.appendTestSessionEntry(TestSessionEntryRequest(
            kind: .step,
            text: text,
            logCursorFrom: cursorFrom,
            logCursorTo: logCursor,
            criterion: criterion
        ))
    }

    private func narrate(_ text: String) async {
        onNarration?(text)
        guard sessionId != nil else { return stage(TestSessionEntryRequest(kind: .step, text: text)) }
        _ = try? await client.appendTestSessionEntry(TestSessionEntryRequest(kind: .step, text: text))
    }

    private func note(_ logs: [String]) async {
        for line in logs { onNarration?(line) }
        guard !logs.isEmpty else { return }
        guard sessionId != nil else { return stage(TestSessionEntryRequest(kind: .log, logs: logs)) }
        _ = try? await client.appendTestSessionEntry(TestSessionEntryRequest(kind: .log, logs: logs))
    }

    /// Holds a staging note until there is a session to put it in. The staging
    /// happens before the recorder starts — so it is off camera — but `Reset:`
    /// and `Setup n/n (exit 1)` are exactly what has to be read before a verdict
    /// is trusted, so they are not allowed to vanish with it.
    private func stage(_ entry: TestSessionEntryRequest) {
        guard options.recordSession else { return }
        stagedNotes.append(entry)
    }

    private func flushStagingNotes() async {
        let pending = stagedNotes
        stagedNotes = []
        for entry in pending {
            _ = try? await client.appendTestSessionEntry(entry)
        }
    }

    private func message(of error: Error) -> String {
        (error as? SimToolError)?.message ?? error.localizedDescription
    }
}
