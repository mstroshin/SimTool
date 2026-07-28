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
        let before = registry.list(since: nil).generation
        let removed = registry.clear()
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(registry.list(since: nil).rules.count, 0)
        XCTAssertEqual(registry.list(since: nil).generation, before + 1)
    }

    // MARK: - acknowledgement

    /// A poll carrying `since` is the app saying "I already applied that
    /// generation" — the only signal that the rules are actually in force, which
    /// a run must wait for before its first step.
    func testPollWithSinceAcknowledgesThatGeneration() {
        let registry = MockRuleRegistry()
        let created = registry.add(draft)
        XCTAssertFalse(registry.acknowledgement().hasApplied(created.generation))

        // The app is still on the previous generation: not an acknowledgement.
        _ = registry.list(since: created.generation - 1)
        XCTAssertFalse(registry.acknowledgement().hasApplied(created.generation))

        _ = registry.list(since: created.generation)
        let ack = registry.acknowledgement()
        XCTAssertTrue(ack.hasApplied(created.generation))
        XCTAssertEqual(ack.acknowledged, created.generation)
        XCTAssertNotNil(ack.lastPollAt)
    }

    /// The CLI's `mock list` and the web viewer poll without `since`; they say
    /// nothing about any app and must not fake an acknowledgement.
    func testPollWithoutSinceIsNotAnAcknowledgement() {
        let registry = MockRuleRegistry()
        let created = registry.add(draft)
        _ = registry.list(since: nil)
        let ack = registry.acknowledgement()
        XCTAssertNil(ack.acknowledged)
        XCTAssertNil(ack.lastPollAt)
        XCTAssertFalse(ack.hasApplied(created.generation))
    }

    func testAcknowledgementKeepsTheHighestGenerationSeen() {
        let registry = MockRuleRegistry()
        _ = registry.add(draft)
        _ = registry.list(since: 5)
        _ = registry.list(since: 2)
        XCTAssertEqual(registry.acknowledgement().acknowledged, 5)
    }

    /// Adding rules mid-session leaves the older acknowledgement in place, so a
    /// run waiting on the new generation keeps waiting.
    func testNewRulesAreNotCoveredByAnEarlierAcknowledgement() {
        let registry = MockRuleRegistry()
        let first = registry.add(draft)
        _ = registry.list(since: first.generation)
        let second = registry.add(draft)
        XCTAssertTrue(registry.acknowledgement().hasApplied(first.generation))
        XCTAssertFalse(registry.acknowledgement().hasApplied(second.generation))
    }

    func testClearOnEmptyRegistryDoesNotBumpGeneration() {
        let registry = MockRuleRegistry()
        let g0 = registry.list(since: nil).generation
        let removed = registry.clear()
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(registry.list(since: nil).generation, g0)
    }
}
