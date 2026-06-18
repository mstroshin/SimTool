import XCTest
@testable import SimToolNetworkLogger

final class MockRuleRegistryTests: XCTestCase {
    private let draft = MockRuleDraft(match: MockMatch(method: "/m"), response: MockResponse(kind: .success, bodyJSON: "{}"))

    func testAddAssignsIdAndBumpsGeneration() {
        let registry = MockRuleRegistry()
        let first = registry.add(draft)
        let second = registry.add(draft)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.generation, first.generation + 1)
        XCTAssertEqual(registry.list(since: nil).rules.count, 2)
    }

    func testListSinceReturnsUnchangedWhenGenerationMatches() {
        let registry = MockRuleRegistry()
        let created = registry.add(draft)
        let payload = registry.list(since: created.generation)
        XCTAssertTrue(payload.unchanged)
        XCTAssertEqual(payload.rules.count, 0)
        XCTAssertEqual(payload.generation, created.generation)
    }

    func testRemoveBumpsGenerationAndDropsRule() {
        let registry = MockRuleRegistry()
        let created = registry.add(draft)
        XCTAssertTrue(registry.remove(id: created.id))
        XCTAssertFalse(registry.remove(id: created.id))
        let payload = registry.list(since: nil)
        XCTAssertEqual(payload.rules.count, 0)
        XCTAssertEqual(payload.generation, created.generation + 1)
    }

    func testClearRemovesAllAndBumpsGeneration() {
        let registry = MockRuleRegistry()
        _ = registry.add(draft)
        _ = registry.add(draft)
        let removed = registry.clear()
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(registry.list(since: nil).rules.count, 0)
    }
}
