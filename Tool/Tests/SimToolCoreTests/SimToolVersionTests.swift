import Foundation
import XCTest
@testable import SimToolCore

final class SimToolVersionTests: XCTestCase {
    // A binary built from a working tree is not the release it is based on, and
    // the version it reports lands in every session's provenance. Without a
    // marker, a run recorded against a locally built simtool is indistinguishable
    // from one recorded against the published release of the same number — which
    // is exactly the confusion provenance exists to prevent.
    func testABuildFromSourceMarksItselfAsNotTheRelease() {
        XCTAssertEqual(SimToolVersion.current, SimToolVersion.base + "-dev")
        XCTAssertFalse(SimToolVersion.isRelease)
    }

    // The formula is what users install; the constant is what the binary reports.
    // They drift in whichever commit forgets one of them.
    func testTheBaseVersionMatchesTheHomebrewFormula() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SimToolCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // Tool/
            .deletingLastPathComponent()  // repository root
        let formulaURL = repositoryRoot.appendingPathComponent("Formula/simtool.rb")
        guard let formula = try? String(contentsOf: formulaURL, encoding: .utf8) else {
            throw XCTSkip("no formula at \(formulaURL.path) (building outside a checkout)")
        }
        let versions = formula
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("version \"") else { return nil }
                return trimmed.dropFirst("version \"".count).dropLast().description
            }
        XCTAssertEqual(versions, [SimToolVersion.base], "Formula/simtool.rb and SimToolVersion.base disagree")
    }
}
