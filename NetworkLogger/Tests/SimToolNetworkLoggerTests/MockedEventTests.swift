import XCTest
@testable import SimToolNetworkLogger

final class MockedEventTests: XCTestCase {
    func testDefaultsToNotMocked() {
        let event = NetworkLoggerEvent(networkProtocol: .grpc, durationMilliseconds: 1, request: NetworkLoggerRequest())
        XCTAssertFalse(event.mocked)
        XCTAssertNil(event.mockRuleId)
    }

    func testDecodingLegacyJSONWithoutMockedFieldDefaultsFalse() throws {
        let legacy = """
        {"id":"x","timestamp":"t","protocol":"grpc","durationMilliseconds":1,"request":{"headers":{},"metadata":{}},"rawMetadata":{}}
        """
        let event = try NetworkLoggerJSON.decoder.decode(NetworkLoggerEvent.self, from: Data(legacy.utf8))
        XCTAssertFalse(event.mocked)
    }

    func testRecordGRPCStampsMockedFlag() async {
        let logger = SimToolNetworkLogger(configuration: NetworkLoggerConfiguration(fileSinkEnabled: false), sinks: [])
        let event = await logger.recordGRPC(fullMethod: "/m", durationMilliseconds: 1, mocked: true, mockRuleId: "mock-1")
        XCTAssertTrue(event.mocked)
        XCTAssertEqual(event.mockRuleId, "mock-1")
    }
}
