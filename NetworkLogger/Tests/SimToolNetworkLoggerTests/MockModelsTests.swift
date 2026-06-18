import XCTest
@testable import SimToolNetworkLogger

final class MockModelsTests: XCTestCase {
    func testMockRuleRoundTripsThroughJSON() throws {
        let rule = MockRule(
            id: "r1",
            match: MockMatch(method: "/example.v1.FooService/GetBar", headerMatch: ["x-env": "test"], bodyMatch: .object(["id": .string("42")]), skip: 1, times: 2),
            response: MockResponse(kind: .success, bodyJSON: "{\"ok\":true}"),
            delayMs: 150
        )
        let data = try NetworkLoggerJSON.data(rule)
        let decoded = try NetworkLoggerJSON.decoder.decode(MockRule.self, from: data)
        XCTAssertEqual(decoded, rule)
    }

    func testErrorResponseRoundTrips() throws {
        let response = MockResponse(kind: .error, grpcStatus: "unavailable", message: "down", trailers: ["retry": "no"])
        let data = try NetworkLoggerJSON.data(response)
        XCTAssertEqual(try NetworkLoggerJSON.decoder.decode(MockResponse.self, from: data), response)
    }

    func testListPayloadCarriesGenerationAndUnchangedFlag() throws {
        let payload = MockRuleListPayload(generation: 7, rules: [], unchanged: true)
        let data = try NetworkLoggerJSON.data(payload)
        XCTAssertEqual(try NetworkLoggerJSON.decoder.decode(MockRuleListPayload.self, from: data), payload)
    }
}
