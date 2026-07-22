import Foundation
import SimToolClient
import SimToolCore

/// Lists declarative YAML tests from `<.simtool>/tests` and runs one at a time
/// against the server's own HTTP API, so web-triggered runs share the exact
/// execution path of `simtool test run` — test session recording included.
final class TestRunController: @unchecked Sendable {
    private struct ActiveRun {
        var file: String
        var name: String?
        var sessionId: String?
        var completedSteps: Int
        var totalSteps: Int
        var status: String
        var error: String?
    }

    private let testsRoot: URL
    private let lock = NSLock()
    private var run: ActiveRun?
    private var task: Task<Void, Never>?

    init(testsRoot: URL) {
        self.testsRoot = testsRoot
    }

    func list() -> TestListPayload {
        TestListPayload(tests: TestDefinitionParser.summaries(in: testsRoot))
    }

    func status() -> TestRunStatusPayload {
        lock.lock()
        defer { lock.unlock() }
        guard let run else { return TestRunStatusPayload() }
        return TestRunStatusPayload(
            active: run.status == "running",
            file: run.file,
            name: run.name,
            sessionId: run.sessionId,
            completedSteps: run.completedSteps,
            totalSteps: run.totalSteps,
            status: run.status,
            error: run.error
        )
    }

    func start(file: String, serverURL: URL, video: Bool = true) throws -> TestRunStatusPayload {
        guard !file.contains("/"), !file.contains(".."), !file.isEmpty else {
            throw SimToolError("Invalid test file name: \(file)")
        }
        let test = try TestDefinitionParser.load(contentsOf: testsRoot.appendingPathComponent(file))

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
            error: nil
        )
        task = Task { await execute(test, file: file, serverURL: serverURL, video: video) }
        lock.unlock()
        return status()
    }

    /// Cancels the in-flight run, if any. The runner notices cancellation at
    /// its next await (step polling sleeps every 500 ms) and finishes the test
    /// session as interrupted; until then the status stays "running".
    func stop() -> TestRunStatusPayload {
        lock.lock()
        let task = run?.status == "running" ? self.task : nil
        lock.unlock()
        task?.cancel()
        return status()
    }

    private func execute(_ test: TestDefinition, file: String, serverURL: URL, video: Bool) async {
        let client = SimToolClient(baseURL: serverURL)
        do {
            let config = try await client.config()
            let session = try await client.startTestSession(title: test.name ?? file, video: video)
            update { $0.sessionId = session.id }

            let runner = TestRunner(
                client: client,
                udid: config.udid,
                screenWidth: Double(config.width),
                screenHeight: Double(config.height),
                defaultTimeout: test.stepTimeout,
                record: { text in
                    _ = try? await client.appendTestSessionEntry(TestSessionEntryRequest(kind: .step, text: text))
                },
                onProgress: { completed, _ in
                    self.update { $0.completedSteps = completed }
                }
            )

            do {
                try await runner.run(test)
                _ = try? await client.stopTestSession(status: .passed)
                update { $0.status = "passed" }
            } catch where error is CancellationError || Task.isCancelled {
                await finishStopped(client: client)
            } catch {
                let failure = message(of: error)
                let screen = await runner.visibleSummary()
                _ = try? await client.appendTestSessionEntry(TestSessionEntryRequest(
                    kind: .log,
                    logs: [failure] + (screen.isEmpty ? [] : ["On screen:"] + screen)
                ))
                _ = try? await client.stopTestSession(status: .failed)
                update { $0.status = "failed"; $0.error = failure }
            }
        } catch where error is CancellationError || Task.isCancelled {
            await finishStopped(client: client)
        } catch {
            _ = try? await client.stopTestSession(status: .failed)
            update { $0.status = "failed"; $0.error = message(of: error) }
        }
    }

    /// A cancelled task cannot make HTTP calls (URLSession throws immediately),
    /// so the session is closed from a detached task that ignores cancellation.
    private func finishStopped(client: SimToolClient) async {
        await Task.detached {
            _ = try? await client.appendTestSessionEntry(TestSessionEntryRequest(kind: .log, logs: ["Stopped from the web viewer."]))
            _ = try? await client.stopTestSession(status: .interrupted)
        }.value
        update { $0.status = "stopped"; $0.error = nil }
    }

    @discardableResult
    private func update<T>(_ mutate: (inout ActiveRun) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        var current = run ?? ActiveRun(file: "", name: nil, sessionId: nil, completedSteps: 0, totalSteps: 0, status: "running", error: nil)
        let result = mutate(&current)
        run = current
        return result
    }

    private func message(of error: Error) -> String {
        (error as? SimToolError)?.message ?? error.localizedDescription
    }
}
