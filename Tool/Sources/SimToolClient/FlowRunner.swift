import Foundation
import SimToolCore

/// Executes a parsed `TestFlow` against the served simulator. Every step
/// implicitly waits for its target by polling the accessibility tree, so flows
/// need no explicit sleeps to survive animations and loading.
public struct FlowRunner {
    public let client: SimToolClient
    public let udid: String
    public let screenWidth: Double
    public let screenHeight: Double
    public let defaultTimeout: Double
    public let record: (String) async -> Void
    /// Called after each completed step with (completedSteps, totalSteps).
    public var onProgress: ((Int, Int) async -> Void)?

    private static let pollInterval: Duration = .milliseconds(500)

    public init(
        client: SimToolClient,
        udid: String,
        screenWidth: Double,
        screenHeight: Double,
        defaultTimeout: Double,
        record: @escaping (String) async -> Void,
        onProgress: ((Int, Int) async -> Void)? = nil
    ) {
        self.client = client
        self.udid = udid
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.defaultTimeout = defaultTimeout
        self.record = record
        self.onProgress = onProgress
    }

    public func run(_ flow: TestFlow) async throws {
        for (index, command) in flow.setup.enumerated() {
            let status = await runSetupCommand(command, app: flow.app)
            await record("Setup \(index + 1)/\(flow.setup.count) (\(status)): \(command.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let app = flow.app {
            let arguments = flow.effectiveLaunchArguments
            try await launch(app: app, arguments: arguments)
            let rendered = arguments.isEmpty ? "" : " " + arguments.joined(separator: " ")
            await record("Launched \(app)\(rendered)")
        }
        for (index, step) in flow.steps.enumerated() {
            do {
                try await execute(step)
            } catch let error as SimToolError {
                throw SimToolError("Step \(index + 1) of \(flow.steps.count) — \(step): \(error.message)")
            }
            await record("✓ \(index + 1)/\(flow.steps.count) \(step)")
            await onProgress?(index + 1, flow.steps.count)
        }
    }

    /// Flat "type id label" lines of what is currently on screen, for failure logs.
    public func visibleSummary(limit: Int = 40) async -> [String] {
        guard let tree = try? await client.accessibilityTree() else { return [] }
        var lines: [String] = []
        var queue = tree.roots
        while !queue.isEmpty, lines.count < limit {
            let node = queue.removeFirst()
            queue.append(contentsOf: node.children)
            var parts: [String] = []
            if let type = node.type ?? node.role { parts.append(type) }
            // Underscore-prefixed identifiers are private SwiftUI/UIKit hosting
            // wrappers — noise that buries the meaningful elements.
            if let id = node.accessibilityIdentifier, !id.isEmpty, !id.hasPrefix("_") { parts.append("id=\(id)") }
            if let label = node.label, !label.isEmpty { parts.append("label=\(label)") }
            if let value = node.value, !value.isEmpty { parts.append("value=\(value)") }
            if parts.count > 1 { lines.append(parts.joined(separator: " ")) }
        }
        return lines
    }

    private func execute(_ step: TestFlowStep) async throws {
        switch step {
        case .tap(let target, let timeout):
            let node = try await waitForMatch(target, timeout: timeout)
            try await tap(node: node, target: target)
        case .type(let text):
            try check(await client.typeText(text), action: "type")
        case .swipe(let direction):
            try await swipe(direction)
        case .waitFor(let target, let timeout):
            _ = try await waitForMatch(target, timeout: timeout)
        case .assertHidden(let target, let timeout):
            try await waitForAbsence(target, timeout: timeout)
        case .pause(let seconds):
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        }
    }

    private func waitForMatch(_ target: TestFlowTarget, timeout: Double?) async throws -> AccessibilityNode {
        let deadline = ContinuousClock.now + .milliseconds(Int((timeout ?? defaultTimeout) * 1000))
        while true {
            if let node = await firstMatch(target) { return node }
            guard ContinuousClock.now < deadline else {
                throw SimToolError("no element matching \(target) appeared within \(timeout ?? defaultTimeout)s")
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    private func waitForAbsence(_ target: TestFlowTarget, timeout: Double?) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int((timeout ?? defaultTimeout) * 1000))
        while true {
            if await firstMatch(target) == nil { return }
            guard ContinuousClock.now < deadline else {
                throw SimToolError("element matching \(target) is still visible after \(timeout ?? defaultTimeout)s")
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    private func firstMatch(_ target: TestFlowTarget) async -> AccessibilityNode? {
        guard let tree = try? await client.accessibilityTree() else { return nil }
        var queue = tree.roots
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if target.matches(node) { return node }
            queue.append(contentsOf: node.children)
        }
        return nil
    }

    private func tap(node: AccessibilityNode, target: TestFlowTarget) async throws {
        if let id = node.accessibilityIdentifier, !id.isEmpty {
            try check(await client.tap(id: id), action: "tap")
        } else if let label = node.label, !label.isEmpty {
            try check(await client.tap(label: label), action: "tap")
        } else if let frame = node.frame,
                  let x = frame.x, let y = frame.y, let width = frame.width, let height = frame.height {
            try check(await client.tap(x: x + width / 2, y: y + height / 2), action: "tap")
        } else {
            throw SimToolError("matched \(target) but the node has no id, label or frame to tap")
        }
    }

    private func swipe(_ direction: TestFlowSwipeDirection) async throws {
        let (start, end): ((Double, Double), (Double, Double)) = switch direction {
        case .up: ((0.5, 0.7), (0.5, 0.3))
        case .down: ((0.5, 0.3), (0.5, 0.7))
        case .left: ((0.7, 0.5), (0.3, 0.5))
        case .right: ((0.3, 0.5), (0.7, 0.5))
        }
        try check(
            await client.swipe(
                startX: start.0 * screenWidth,
                startY: start.1 * screenHeight,
                endX: end.0 * screenWidth,
                endY: end.1 * screenHeight
            ),
            action: "swipe"
        )
    }

    /// Setup commands reset persisted state before launch (delete a defaults
    /// key, clear a container), so a non-zero exit — the key not existing on a
    /// first run — is reported but never fails the flow.
    private func runSetupCommand(_ command: String, app: String?) async -> String {
        let rendered = command
            .replacingOccurrences(of: "{udid}", with: udid)
            .replacingOccurrences(of: "{app}", with: app ?? "")
        do {
            let output = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", rendered],
                timeoutSeconds: 60
            )
            return output.status == 0 ? "ok" : "exit \(output.status)"
        } catch {
            return "error: \((error as? SimToolError)?.message ?? error.localizedDescription)"
        }
    }

    private func launch(app: String, arguments: [String]) async throws {
        _ = try? await ProcessRunner.runXcrun(["simctl", "terminate", udid, app])
        let output = try await ProcessRunner.runXcrun(["simctl", "launch", udid, app] + arguments)
        guard output.status == 0 else {
            throw SimToolError("simctl launch \(app) failed: \(output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func check(_ result: CommandResultPayload, action: String) throws {
        guard result.ok else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw SimToolError("\(action) failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
