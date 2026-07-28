import Foundation

/// Server-side, thread-safe registry of mock rule definitions. Stores only definitions; matching and
/// counting happen app-side in `MockStore`. Every mutation increments `generation` so apps can poll
/// cheaply with `?since=`.
public final class MockRuleRegistry: @unchecked Sendable {
    /// What the registry knows about the app's side of the handshake.
    public struct Acknowledgement: Equatable, Sendable {
        public var generation: Int
        /// Highest generation an app has confirmed holding, or nil if none has.
        public var acknowledged: Int?
        public var lastPollAt: Date?

        public init(generation: Int, acknowledged: Int?, lastPollAt: Date?) {
            self.generation = generation
            self.acknowledged = acknowledged
            self.lastPollAt = lastPollAt
        }

        /// Whether an app is known to hold `generation` or newer. A test that
        /// declares mocks must not start stepping before this is true: the app
        /// polls on an interval, so until it has answered once, calls can still
        /// reach the real backend.
        public func hasApplied(_ target: Int) -> Bool {
            guard let acknowledged else { return false }
            return acknowledged >= target
        }
    }

    private let lock = NSLock()
    private var rules: [MockRule] = []
    private var generation: Int = 0
    private var nextID: Int = 1
    private var acknowledgedGeneration: Int?
    private var lastPollAt: Date?

    public init() {}

    @discardableResult
    public func add(_ draft: MockRuleDraft) -> MockRuleCreateResponse {
        lock.lock(); defer { lock.unlock() }
        let id = "mock-\(nextID)"
        nextID += 1
        rules.append(MockRule(id: id, match: draft.match, response: draft.response, delayMs: draft.delayMs))
        generation += 1
        return MockRuleCreateResponse(id: id, generation: generation)
    }

    /// A poll carrying `since` comes from an app-side poller asking "anything
    /// newer than the generation I already applied?" — so the value itself is
    /// the acknowledgement. Callers that pass nil (the CLI's `mock list`, the
    /// web viewer) say nothing about any app and are not recorded.
    public func list(since: Int?) -> MockRuleListPayload {
        lock.lock(); defer { lock.unlock() }
        if let since {
            lastPollAt = Date()
            acknowledgedGeneration = max(acknowledgedGeneration ?? since, since)
        }
        if let since, since == generation {
            return MockRuleListPayload(generation: generation, rules: [], unchanged: true)
        }
        return MockRuleListPayload(generation: generation, rules: rules, unchanged: false)
    }

    public func acknowledgement() -> Acknowledgement {
        lock.lock(); defer { lock.unlock() }
        return Acknowledgement(
            generation: generation,
            acknowledged: acknowledgedGeneration,
            lastPollAt: lastPollAt
        )
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = rules.count
        rules.removeAll { $0.id == id }
        guard rules.count != before else { return false }
        generation += 1
        return true
    }

    @discardableResult
    public func clear() -> Int {
        lock.lock(); defer { lock.unlock() }
        let removed = rules.count
        rules.removeAll()
        if removed > 0 { generation += 1 }
        return removed
    }
}
