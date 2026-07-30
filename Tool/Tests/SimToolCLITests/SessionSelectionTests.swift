import ArgumentParser
import Foundation
import XCTest
@testable import SimToolCLI
import SimToolCore

final class SessionSelectionTests: XCTestCase {
    // `simtool sessions` prints ids truncated to the table's width, so the id a
    // user can see is not one they can paste. Accepting the prefix they *can*
    // copy is the difference between `kill` working and "No matching session
    // found" on a session plainly listed a line above.
    func testAUniquePrefixIdentifiesASession() throws {
        let sessions = [session(id: "E0D12083-7907-400B-84FF-F9C8A5E658B2"), session(id: "39C77E79-DFC0-416F-AEB3-3970630B8599")]

        let picked = try Kill.select(id: "E0D12083-7907", among: sessions)

        XCTAssertEqual(picked.sessionId, "E0D12083-7907-400B-84FF-F9C8A5E658B2")
    }

    func testAnExactIdStillWins() throws {
        let sessions = [session(id: "abc"), session(id: "abcdef")]

        XCTAssertEqual(try Kill.select(id: "abc", among: sessions).sessionId, "abc")
    }

    // Killing the wrong server is worse than not killing one, so an ambiguous
    // prefix has to name the candidates rather than pick.
    func testAnAmbiguousPrefixRefusesAndNamesTheCandidates() {
        let sessions = [session(id: "abc-1"), session(id: "abc-2")]

        XCTAssertThrowsError(try Kill.select(id: "abc", among: sessions)) { error in
            let message = (error as? SimToolError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("abc-1"), message)
            XCTAssertTrue(message.contains("abc-2"), message)
        }
    }

    func testAPrefixMatchingNothingSaysSo() {
        XCTAssertThrowsError(try Kill.select(id: "nope", among: [session(id: "abc")])) { error in
            let message = (error as? SimToolError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("nope"), message)
        }
    }

    private func session(id: String) -> SessionInfo {
        SessionInfo(
            sessionId: id,
            pid: 1,
            device: SimulatorDevice(udid: "UDID", name: "iPhone", runtime: "iOS 18.2", state: "Booted", isAvailable: true),
            url: "http://127.0.0.1:3200",
            api: "http://127.0.0.1:3200/api/v1",
            startedAt: Date(timeIntervalSince1970: 100),
            projectRoot: "/Users/x/Workspace/mine"
        )
    }
}
