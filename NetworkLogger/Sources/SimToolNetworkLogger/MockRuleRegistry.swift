import Foundation

/// Server-side, thread-safe registry of mock rule definitions. Stores only definitions; matching and
/// counting happen app-side in `MockStore`. Every mutation increments `generation` so apps can poll
/// cheaply with `?since=`.
public final class MockRuleRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [MockRule] = []
    private var generation: Int = 0
    private var nextID: Int = 1

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

    public func list(since: Int?) -> MockRuleListPayload {
        lock.lock(); defer { lock.unlock() }
        if let since, since == generation {
            return MockRuleListPayload(generation: generation, rules: [], unchanged: true)
        }
        return MockRuleListPayload(generation: generation, rules: rules, unchanged: false)
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
