import Foundation
import SimToolClient
import SimToolCore

/// Lists declarative YAML tests from `<.simtool>/tests` and runs one at a time
/// against the server's own HTTP API, so web-triggered runs share the exact
/// execution path of `simtool test run` — staging, evidence, verdict and test
/// session recording included.
final class TestRunController: @unchecked Sendable {
    private struct ActiveRun {
        var file: String
        var name: String?
        var sessionId: String?
        var completedSteps: Int
        var totalSteps: Int
        var status: String
        var verdict: String?
        var error: String?
    }

    private let testsRoot: URL
    private let profiles: [LaunchProfile]
    private let defaultApp: String?
    private let appFacingServerURL: String?
    private let projectRoot: URL?
    private let lock = NSLock()
    private var run: ActiveRun?
    private var task: Task<Void, Never>?

    init(
        testsRoot: URL,
        profiles: [LaunchProfile] = [],
        defaultApp: String? = nil,
        appFacingServerURL: String? = nil,
        projectRoot: URL? = nil
    ) {
        self.testsRoot = testsRoot
        self.profiles = profiles
        self.defaultApp = defaultApp
        self.appFacingServerURL = appFacingServerURL
        self.projectRoot = projectRoot
    }

    func list() -> TestListPayload {
        TestListPayload(tests: TestDefinitionParser.summaries(in: testsRoot))
    }

    /// The run this server is showing. `activeSession` covers what this
    /// controller cannot see: a run started from the CLI records its session
    /// here, so the viewer is watching it happen while this controller holds
    /// nothing — and used to answer "no run in progress", offering to start a
    /// second one onto the same simulator.
    func status(activeSession: TestSession? = nil) -> TestRunStatusPayload {
        lock.lock()
        let run = self.run
        lock.unlock()

        // A run this controller owns wins: it knows the step counts, and Stop can
        // cancel it.
        if let run, run.status == "running" { return Self.payload(run) }
        // Otherwise a session recording here belongs to someone else — a
        // `simtool test run` in a terminal. It is just as much a run in progress.
        if let activeSession, activeSession.status == .running {
            return TestRunStatusPayload(
                active: true,
                file: activeSession.file,
                name: activeSession.title,
                sessionId: activeSession.id,
                status: "running",
                stoppable: false
            )
        }
        return run.map(Self.payload) ?? TestRunStatusPayload()
    }

    private static func payload(_ run: ActiveRun) -> TestRunStatusPayload {
        TestRunStatusPayload(
            active: run.status == "running",
            file: run.file,
            name: run.name,
            sessionId: run.sessionId,
            completedSteps: run.completedSteps,
            totalSteps: run.totalSteps,
            status: run.status,
            verdict: run.verdict,
            error: run.error
        )
    }

    func start(file: String, serverURL: URL, video: Bool = true, activeSession: TestSession? = nil) throws -> TestRunStatusPayload {
        guard !file.contains("/"), !file.contains(".."), !file.isEmpty else {
            throw SimToolError("Invalid test file name: \(file)")
        }
        // A session recording here is a run in progress even when this controller
        // did not start it — one simulator cannot serve two runs.
        if let activeSession, activeSession.status == .running {
            throw SimToolError("\(activeSession.file ?? activeSession.title) is already running on this server.")
        }
        let testURL = testsRoot.appendingPathComponent(file)
        let test = try TestDefinitionParser.load(contentsOf: testURL)

        lock.lock()
        if let current = run, current.status == "running" {
            lock.unlock()
            throw SimToolError("Test \(current.file) is already running.")
        }
        run = ActiveRun(
            file: file,
            name: test.name,
            sessionId: nil,
            completedSteps: 0,
            totalSteps: test.steps.count,
            status: "running",
            verdict: nil,
            error: nil
        )
        task = Task { await execute(test, testURL: testURL, serverURL: serverURL, video: video) }
        lock.unlock()
        return status()
    }

    /// Cancels the in-flight run, if any. The executor notices cancellation at
    /// its next await (step polling sleeps every 500 ms) and finishes the test
    /// session as interrupted; until then the status stays "running".
    func stop() -> TestRunStatusPayload {
        lock.lock()
        let task = run?.status == "running" ? self.task : nil
        lock.unlock()
        task?.cancel()
        return status()
    }

    private func execute(_ test: TestDefinition, testURL: URL, serverURL: URL, video: Bool) async {
        let client = SimToolClient(baseURL: serverURL)
        let executor = TestRunExecutor(
            client: client,
            options: TestRunOptions(
                testFile: testURL,
                video: video,
                profiles: profiles,
                defaultApp: defaultApp,
                appFacingServerURL: appFacingServerURL,
                projectRoot: projectRoot
            )
        )
        executor.onProgress = { [weak self] completed, _ in
            self?.update { $0.completedSteps = completed }
        }
        executor.onSessionStarted = { [weak self] session in
            self?.update { $0.sessionId = session.id }
        }

        let result = await executor.run(test)
        update {
            $0.verdict = result.verdict.rawValue
            $0.completedSteps = result.completedSteps
            if result.cancelled {
                $0.status = "stopped"
                $0.error = nil
            } else {
                $0.status = result.verdict == .satisfied ? "passed" : "failed"
                $0.error = result.verdict == .satisfied
                    ? nil
                    : (result.infraReason ?? result.failures.first?.message ?? result.headline())
            }
        }
    }

    @discardableResult
    private func update<T>(_ mutate: (inout ActiveRun) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        var current = run ?? ActiveRun(
            file: "",
            name: nil,
            sessionId: nil,
            completedSteps: 0,
            totalSteps: 0,
            status: "running",
            verdict: nil,
            error: nil
        )
        let result = mutate(&current)
        run = current
        return result
    }
}
