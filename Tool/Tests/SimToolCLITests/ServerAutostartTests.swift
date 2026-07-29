import Foundation
import XCTest
@testable import SimToolCLI
@testable import SimToolCore

final class ServerAutostartTests: XCTestCase {
    func testTakesTheConfiguredPortWhenNobodyIsOnIt() async throws {
        let port = try await ServerAutostart.freePort(startingAt: 3200) { _ in [] }

        XCTAssertEqual(port, 3200)
    }

    func testSkipsOccupiedPorts() async throws {
        let occupied: Set<UInt16> = [3200, 3201]

        let port = try await ServerAutostart.freePort(startingAt: 3200) { candidate in
            occupied.contains(candidate) ? [4242] : []
        }

        XCTAssertEqual(port, 3202)
    }

    func testNamesTheRangeItSearchedWhenEverythingIsTaken() async {
        do {
            _ = try await ServerAutostart.freePort(startingAt: 3200, limit: 3) { _ in [4242] }
            XCTFail("expected a thrown error")
        } catch {
            let message = (error as? SimToolError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("3200–3202"), message)
            XCTAssertTrue(message.contains("--server"), message)
        }
    }

    // A probe that cannot answer (no lsof, a timeout) must not make every port
    // look free — but it must not block the run either. Treat it as occupied and
    // move on, so the worst case is a higher port number.
    func testAFailingProbeSkipsThatPort() async throws {
        let port = try await ServerAutostart.freePort(startingAt: 3200) { candidate in
            if candidate == 3200 { throw SimToolError("lsof failed") }
            return []
        }

        XCTAssertEqual(port, 3201)
    }

    func testLostThePortReturnsTrueWhenThePortHasAListener() async {
        let lost = await ServerAutostart.lostThePort(3200) { _ in [4242] }

        XCTAssertTrue(lost)
    }

    func testLostThePortReturnsFalseWhenThePortIsEmpty() async {
        let lost = await ServerAutostart.lostThePort(3200) { _ in [] }

        XCTAssertFalse(lost)
    }

    func testLostThePortReturnsFalseWhenTheProbeCannotAnswer() async {
        let lost = await ServerAutostart.lostThePort(3200) { _ in throw SimToolError("lsof failed") }

        XCTAssertFalse(lost)
    }

    // The autostarted child derives its sessions root from its own working
    // directory unless told otherwise; omitting `--config` here is what let a
    // run's evidence land in the wrong project.
    func testDetachedServerArgumentsForwardConfig() {
        let args = detachedServerArguments(
            parameters: ServeParameters(device: nil, host: "127.0.0.1", port: 3200),
            sessionId: "abc",
            app: nil,
            verbose: false,
            reclaimPort: false,
            config: "/Users/x/Workspace/app/.simtool/config.yml"
        )

        XCTAssertEqual(Array(args.suffix(2)), ["--config", "/Users/x/Workspace/app/.simtool/config.yml"])
    }

    func testDetachedServerArgumentsOmitConfigWhenNoneWasGiven() {
        let args = detachedServerArguments(
            parameters: ServeParameters(device: nil, host: "127.0.0.1", port: 3200),
            sessionId: "abc",
            app: nil,
            verbose: false,
            reclaimPort: false,
            config: nil
        )

        XCTAssertFalse(args.contains("--config"))
    }
}
