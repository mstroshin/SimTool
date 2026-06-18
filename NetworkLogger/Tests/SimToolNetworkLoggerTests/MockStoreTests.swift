import XCTest
@testable import SimToolNetworkLogger

final class MockStoreTests: XCTestCase {
    private func rule(_ id: String, method: String, headerMatch: [String: String]? = nil, bodyMatch: NetworkLoggerJSONValue? = nil, skip: Int = 0, times: Int? = nil) -> MockRule {
        MockRule(id: id, match: MockMatch(method: method, headerMatch: headerMatch, bodyMatch: bodyMatch, skip: skip, times: times), response: MockResponse(kind: .success, bodyJSON: "{\"r\":\"\(id)\"}"))
    }

    func testExactMethodMatchReturnsDecision() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/example.v1.FooService/GetBar")], generation: 1)
        let decision = store.decision(fullMethod: "/example.v1.FooService/GetBar", headers: [:], requestJSON: nil)
        XCTAssertEqual(decision?.ruleId, "a")
    }

    func testGlobMethodMatch() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/example.v1.FooService/*")], generation: 1)
        XCTAssertEqual(store.decision(fullMethod: "/example.v1.FooService/GetBar", headers: [:], requestJSON: nil)?.ruleId, "a")
        XCTAssertNil(store.decision(fullMethod: "/example.v1.OtherService/GetBar", headers: [:], requestJSON: nil))
    }

    func testHeaderMatchRequiresAllPairs() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/m", headerMatch: ["x-env": "test"])], generation: 1)
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil))
        XCTAssertEqual(store.decision(fullMethod: "/m", headers: ["x-env": "test", "other": "y"], requestJSON: nil)?.ruleId, "a")
    }

    func testBodySubsetMatch() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/m", bodyMatch: .object(["id": .string("42")]))], generation: 1)
        let matching: NetworkLoggerJSONValue = .object(["id": .string("42"), "extra": .bool(true)])
        let nonMatching: NetworkLoggerJSONValue = .object(["id": .string("99")])
        XCTAssertEqual(store.decision(fullMethod: "/m", headers: [:], requestJSON: matching)?.ruleId, "a")
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nonMatching))
    }

    func testFirstActiveRuleWins() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/m"), rule("b", method: "/m")], generation: 1)
        XCTAssertEqual(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)?.ruleId, "a")
    }

    func testSkipThenTimesGovernsFiring() {
        let store = MockStore()
        // Skip first 2 matches, then fire once.
        store.replace(rules: [rule("a", method: "/m", skip: 2, times: 1)], generation: 1)
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)) // 1st: skipped
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)) // 2nd: skipped
        XCTAssertEqual(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)?.ruleId, "a") // 3rd: fires
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)) // 4th: exhausted
    }

    func testReplaceResetsCounters() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/m", times: 1)], generation: 1)
        XCTAssertNotNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil))
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil))
        store.replace(rules: [rule("a", method: "/m", times: 1)], generation: 2)
        XCTAssertNotNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil))
    }
}
