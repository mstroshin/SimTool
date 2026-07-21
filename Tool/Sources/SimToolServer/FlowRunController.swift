import Foundation
import SimToolClient
import SimToolCore

/// Lists declarative flows from `<.simtool>/flows` and runs one at a time
/// against the server's own HTTP API, so web-triggered runs share the exact
/// execution path of `simtool test run` — test session recording included.
final class FlowRunController: @unchecked Sendable {
    private struct ActiveRun {
        var file: String
        var name: String?
        var sessionId: String?
        var completedSteps: Int
        var totalSteps: Int
        var status: String
        var error: String?
    }

    private let flowsRoot: URL
    private let lock = NSLock()
    private var run: ActiveRun?

    init(flowsRoot: URL) {
        self.flowsRoot = flowsRoot
    }

    func list() -> FlowListPayload {
        let files = (try? FileManager.default.contentsOfDirectory(at: flowsRoot, includingPropertiesForKeys: nil)) ?? []
        let flows = files
            .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { url -> FlowSummary in
                do {
                    let flow = try TestFlowParser.load(contentsOf: url)
                    return FlowSummary(file: url.lastPathComponent, name: flow.name, description: flow.description, stepCount: flow.steps.count)
                } catch {
                    return FlowSummary(file: url.lastPathComponent, parseError: message(of: error))
                }
            }
        return FlowListPayload(flows: flows)
    }

    func status() -> FlowRunStatusPayload {
        lock.lock()
        defer { lock.unlock() }
        guard let run else { return FlowRunStatusPayload() }
        return FlowRunStatusPayload(
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

    func start(file: String, serverURL: URL) throws -> FlowRunStatusPayload {
        guard !file.contains("/"), !file.contains(".."), !file.isEmpty else {
            throw SimToolError("Invalid flow file name: \(file)")
        }
        let flow = try TestFlowParser.load(contentsOf: flowsRoot.appendingPathComponent(file))

        lock.lock()
        if let current = run, current.status == "running" {
            lock.unlock()
            throw SimToolError("Flow \(current.file) is already running.")
        }
        run = ActiveRun(
            file: file,
            name: flow.name,
            sessionId: nil,
            completedSteps: 0,
            totalSteps: flow.steps.count,
            status: "running",
            error: nil
        )
        lock.unlock()

        Task { await execute(flow, file: file, serverURL: serverURL) }
        return status()
    }

    private func execute(_ flow: TestFlow, file: String, serverURL: URL) async {
        let client = SimToolClient(baseURL: serverURL)
        do {
            let config = try await client.config()
            let session = try await client.startTestSession(title: flow.name ?? file)
            update { $0.sessionId = session.id }

            let runner = FlowRunner(
                client: client,
                udid: config.udid,
                screenWidth: Double(config.width),
                screenHeight: Double(config.height),
                defaultTimeout: flow.stepTimeout,
                record: { text in
                    _ = try? await client.appendTestSessionEntry(TestSessionEntryRequest(kind: .step, text: text))
                },
                onProgress: { completed, _ in
                    self.update { $0.completedSteps = completed }
                }
            )

            do {
                try await runner.run(flow)
                _ = try? await client.stopTestSession(status: .passed)
                update { $0.status = "passed" }
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
        } catch {
            _ = try? await client.stopTestSession(status: .failed)
            update { $0.status = "failed"; $0.error = message(of: error) }
        }
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
