import Foundation
import XCTest
@testable import SimToolCore

final class LaunchVariablesTests: XCTestCase {
    func testCollectsNamesFromArgumentsEnvironmentDeeplinkAndSetup() {
        let launch = ResolvedLaunch(
            profile: "staging",
            arguments: ["-Environment", "stable", "-FastLoginPhone", "${ACCOUNT}"],
            environment: ["TOKEN": "${SESSION_TOKEN}"],
            deeplink: "myapp://invite/${INVITE_CODE}"
        )

        let names = LaunchVariables.names(in: launch, setup: ["simtool app launch -- -Phone \"${ACCOUNT}\" -Seed ${SEED}"])

        XCTAssertEqual(names, ["ACCOUNT", "SESSION_TOKEN", "INVITE_CODE", "SEED"])
    }

    func testIgnoresAnUnterminatedReferenceAndDeduplicates() {
        let launch = ResolvedLaunch(arguments: ["${ACCOUNT}", "${ACCOUNT}", "${OPEN"])

        XCTAssertEqual(LaunchVariables.names(in: launch), ["ACCOUNT"])
    }

    func testALaunchWithNoReferencesNeedsNothing() {
        XCTAssertEqual(LaunchVariables.names(in: ResolvedLaunch(arguments: ["-UITesting"])), [])
    }
}
