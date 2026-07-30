import Foundation
import XCTest
import SimToolCore
@testable import SimToolServer

final class TestRunControllerTests: XCTestCase {
    // A run started from the CLI records its session through this server, so the
    // viewer is looking straight at it — and still offered a Run button, because
    // the controller only knew about runs it started itself. Pressing it would
    // have driven a second test onto the same simulator.
    func testACLIStartedRunShowsAsActive() {
        let controller = TestRunController(testsRoot: temporaryTestsRoot())

        let status = controller.status(activeSession: session(status: .running, file: "tab-order.yml"))

        XCTAssertTrue(status.active)
        XCTAssertEqual(status.file, "tab-order.yml")
        XCTAssertEqual(status.sessionId, "2026-07-30-1115-nu33b9")
        XCTAssertEqual(status.status, "running")
    }

    // The viewer's Stop button cancels the task this controller owns; a CLI run
    // has no such task, so offering Stop would be a button that does nothing.
    func testACLIStartedRunIsNotStoppableFromTheViewer() {
        let controller = TestRunController(testsRoot: temporaryTestsRoot())

        XCTAssertEqual(controller.status(activeSession: session(status: .running, file: "tab-order.yml")).stoppable, false)
    }

    func testAFinishedSessionIsNotAnActiveRun() {
        let controller = TestRunController(testsRoot: temporaryTestsRoot())

        let status = controller.status(activeSession: session(status: .passed, file: "tab-order.yml"))

        XCTAssertFalse(status.active)
        XCTAssertNil(status.sessionId)
    }

    func testNoSessionAtAllIsNotAnActiveRun() {
        let controller = TestRunController(testsRoot: temporaryTestsRoot())

        XCTAssertFalse(controller.status(activeSession: nil).active)
    }

    private func temporaryTestsRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("tests", isDirectory: true)
    }

    private func session(status: TestSessionStatus, file: String?) -> TestSession {
        TestSession(
            id: "2026-07-30-1115-nu33b9",
            title: "Tab order",
            deviceUdid: "UDID",
            deviceName: "iPhone",
            startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            status: status,
            entries: [],
            file: file
        )
    }
}
