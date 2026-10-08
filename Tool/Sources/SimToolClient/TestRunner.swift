import Foundation
import SimToolCore

/// Executes the steps of a parsed `TestDefinition` against the served
/// simulator. Every step implicitly waits for its target by polling the
/// accessibility tree, so tests need no explicit sleeps to survive animations
/// and loading.
///
/// Staging the scenario (reset, mocks, launch), collecting evidence and
/// deciding the verdict belong to `TestRunExecutor`; this type only performs
/// actions and reports whether each one did what it said.
public struct TestRunner {
    public let client: SimToolClient
    public let udid: String
    public let defaultTimeout: Double

    private static let pollInterval: Duration = .milliseconds(500)

    public init(
        client: SimToolClient,
        udid: String,
        defaultTimeout: Double
    ) {
        self.client = client
        self.udid = udid
        self.defaultTimeout = defaultTimeout
    }

    /// Flat "type id label" lines of what is currently on screen, for failure
    /// logs.
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

    /// The elements on screen whose text is closest to a missed target — the
    /// fastest way to see that a step names `loginBtn` while the screen has
    /// `loginButton`.
    public func nearestTargets(to target: TestTarget, limit: Int = 3) async -> [String] {
        guard let tree = try? await client.accessibilityTree() else { return [] }
        var candidates: [(score: Int, text: String)] = []
        var queue = tree.roots
        let needle = target.query.lowercased()
        while !queue.isEmpty {
            let node = queue.removeFirst()
            queue.append(contentsOf: node.children)
            for (field, value) in [("id", node.accessibilityIdentifier), ("label", node.label), ("title", node.title)] {
                guard let value, !value.isEmpty, !value.hasPrefix("_") else { continue }
                let score = similarity(value.lowercased(), needle)
                guard score > 0 else { continue }
                candidates.append((score, "\(field)=\(value)"))
            }
        }
        var seen = Set<String>()
        return candidates
            .sorted { $0.score > $1.score }
            .filter { seen.insert($0.text).inserted }
            .prefix(limit)
            .map(\.text)
    }

    /// Length of the longest shared prefix or containment overlap. Deliberately
    /// crude: it only has to rank "nearly the identifier you meant" above
    /// unrelated elements.
    private func similarity(_ candidate: String, _ needle: String) -> Int {
        if candidate == needle { return Int.max }
        if candidate.contains(needle) || needle.contains(candidate) { return min(candidate.count, needle.count) + 100 }
        return zip(candidate, needle).prefix { $0.0 == $0.1 }.count
    }

    public func execute(_ action: TestStepAction) async throws {
        switch action {
        case .tap(let target, let timeout):
            let node = try await waitForMatch(target, timeout: timeout)
            try await tap(node: node, target: target)
        case .longPress(let target, let duration, let timeout):
            let node = try await waitForMatch(target, timeout: timeout)
            try await longPress(node: node, target: target, duration: duration)
        case .type(let text):
            try check(await client.typeText(text), action: "type")
        case .swipe(let direction):
            try check(await client.scroll(direction: direction), action: "swipe")
        case .scroll(let direction, let distance, let from, let timeout):
            let start = try await startPoint(on: from, timeout: timeout)
            try check(await client.scroll(direction: direction, distance: distance, x: start?.x, y: start?.y), action: "scroll")
        case .fling(let direction, let speed, let from, let timeout):
            let start = try await startPoint(on: from, timeout: timeout)
            try check(await client.fling(direction: direction, velocity: speed, x: start?.x, y: start?.y), action: "fling")
        case .drag(let from, let to, let press, let speed, let hold, let timeout):
            let start = try center(of: try await waitForMatch(from, timeout: timeout), target: from)
            let end: TouchPoint = switch to {
            case .target(let target): try center(of: try await waitForMatch(target, timeout: timeout), target: target)
            case .offset(let x, let y): TouchPoint(x: start.x + x, y: start.y + y)
            }
            try check(
                await client.drag(startX: start.x, startY: start.y, endX: end.x, endY: end.y, press: press, velocity: speed, hold: hold),
                action: "drag"
            )
        case .waitFor(let target, let timeout):
            _ = try await waitForMatch(target, timeout: timeout)
        case .assertHidden(let target, let timeout):
            try await waitForAbsence(target, timeout: timeout)
        case .pause(let seconds):
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        }
    }

    private func waitForMatch(_ target: TestTarget, timeout: Double?) async throws -> AccessibilityNode {
        let deadline = ContinuousClock.now + .milliseconds(Int((timeout ?? defaultTimeout) * 1000))
        while true {
            if let node = await firstMatch(target) { return node }
            guard ContinuousClock.now < deadline else {
                throw SimToolError("no element matching \(target) appeared within \(timeout ?? defaultTimeout)s")
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    private func waitForAbsence(_ target: TestTarget, timeout: Double?) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int((timeout ?? defaultTimeout) * 1000))
        while true {
            if await firstMatch(target) == nil { return }
            guard ContinuousClock.now < deadline else {
                throw SimToolError("element matching \(target) is still visible after \(timeout ?? defaultTimeout)s")
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    private func firstMatch(_ target: TestTarget) async -> AccessibilityNode? {
        guard let tree = try? await client.accessibilityTree() else { return nil }
        var queue = tree.roots
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if target.matches(node) { return node }
            queue.append(contentsOf: node.children)
        }
        return nil
    }

    /// The runner has already picked the exact node, so its frame center is the
    /// only tap target guaranteed to hit that node — resolving by id/label again
    /// fails when several elements share the same identifier (e.g. list cells).
    private func tap(node: AccessibilityNode, target: TestTarget) async throws {
        if let frame = node.frame,
           let x = frame.x, let y = frame.y, let width = frame.width, let height = frame.height {
            try check(await client.tap(x: x + width / 2, y: y + height / 2), action: "tap")
        } else if let id = node.accessibilityIdentifier, !id.isEmpty {
            try check(await client.tap(id: id), action: "tap")
        } else if let label = node.label, !label.isEmpty {
            try check(await client.tap(label: label), action: "tap")
        } else {
            throw SimToolError("matched \(target) but the node has no frame, id or label to tap")
        }
    }

    private func longPress(node: AccessibilityNode, target: TestTarget, duration: Double?) async throws {
        if let frame = node.frame,
           let x = frame.x, let y = frame.y, let width = frame.width, let height = frame.height {
            try check(await client.longPress(x: x + width / 2, y: y + height / 2, duration: duration), action: "long press")
        } else if let id = node.accessibilityIdentifier, !id.isEmpty {
            try check(await client.longPress(id: id, duration: duration), action: "long press")
        } else if let label = node.label, !label.isEmpty {
            try check(await client.longPress(label: label, duration: duration), action: "long press")
        } else {
            throw SimToolError("matched \(target) but the node has no frame, id or label to long-press")
        }
    }

    /// The center of the element a gesture starts on, once it is on screen;
    /// nil lets the server pick its default start.
    private func startPoint(on target: TestTarget?, timeout: Double?) async throws -> TouchPoint? {
        guard let target else { return nil }
        return try center(of: try await waitForMatch(target, timeout: timeout), target: target)
    }

    /// Where a gesture on this node lands: its frame center, like a tap.
    private func center(of node: AccessibilityNode, target: TestTarget) throws -> TouchPoint {
        guard let frame = node.frame,
              let x = frame.x, let y = frame.y, let width = frame.width, let height = frame.height else {
            throw SimToolError("matched \(target) but the node has no frame to touch")
        }
        return TouchPoint(x: x + width / 2, y: y + height / 2)
    }

    private func check(_ result: CommandResultPayload, action: String) throws {
        guard result.ok else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw SimToolError("\(action) failed: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
