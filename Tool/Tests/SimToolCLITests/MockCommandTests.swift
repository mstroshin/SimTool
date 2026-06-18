import Foundation
import XCTest
@testable import SimToolCLI
import SimToolNetworkLogger

final class MockCommandTests: XCTestCase {
    func testSetBuildsSuccessDraft() throws {
        let set = try Mock.Set.parse(["--method", "/example.v1.FooService/GetBar", "--body", "{\"ok\":true}", "--delay", "100", "--match-header", "x-env=test"])
        let draft = try set.makeDraft()
        XCTAssertEqual(draft.match.method, "/example.v1.FooService/GetBar")
        XCTAssertEqual(draft.match.headerMatch, ["x-env": "test"])
        XCTAssertEqual(draft.delayMs, 100)
        XCTAssertEqual(draft.response.kind, .success)
        XCTAssertEqual(draft.response.bodyJSON, "{\"ok\":true}")
    }

    func testSetBuildsErrorDraft() throws {
        let set = try Mock.Set.parse(["--method", "/m", "--error", "unavailable", "--message", "down"])
        let draft = try set.makeDraft()
        XCTAssertEqual(draft.response.kind, .error)
        XCTAssertEqual(draft.response.grpcStatus, "unavailable")
        XCTAssertEqual(draft.response.message, "down")
    }

    func testSetRejectsMissingBodyAndError() {
        let set = try? Mock.Set.parse(["--method", "/m"])
        XCTAssertThrowsError(try set?.makeDraft())
    }
}
