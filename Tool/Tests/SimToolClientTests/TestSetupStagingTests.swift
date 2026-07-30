import Foundation
import XCTest
@testable import SimToolClient
import SimToolCore

final class TestSetupStagingTests: XCTestCase {
    // A scenario whose state changes inside one process needs two launches, and
    // the first one lives in `setup:`. Without the run's own server address there,
    // that launch can only reach a server whose port the test hardcodes — which is
    // exactly what stops the file from travelling to another machine.
    func testSetupCommandsCanNameTheRunsServer() {
        let rendered = TestRunExecutor.renderSetup(
            "simtool mock clear --server {server}",
            udid: "UDID",
            app: "com.example.app",
            server: "http://127.0.0.1:3203"
        )

        XCTAssertEqual(rendered, "simtool mock clear --server http://127.0.0.1:3203")
    }

    func testSetupSubstitutionsStillCoverTheDeviceAndTheApp() {
        let rendered = TestRunExecutor.renderSetup(
            "xcrun simctl spawn {udid} defaults delete {app}",
            udid: "UDID",
            app: "com.example.app",
            server: nil
        )

        XCTAssertEqual(rendered, "xcrun simctl spawn UDID defaults delete com.example.app")
    }

    // With no server to name, the placeholder must not silently become the empty
    // string and turn `--server {server}` into a broken flag.
    func testWithoutAServerThePlaceholderIsLeftAlone() {
        let rendered = TestRunExecutor.renderSetup("echo {server}", udid: "UDID", app: nil, server: nil)

        XCTAssertEqual(rendered, "echo {server}")
    }

    // The client's root URL renders with a trailing slash, which then lands in a
    // command as `--server http://127.0.0.1:3203/` and in a variable someone will
    // concatenate a path onto. One spelling, and it matches the address printed
    // everywhere else.
    func testTheServerAddressCarriesNoTrailingSlash() {
        XCTAssertEqual(
            TestRunExecutor.renderSetup("simtool mock clear --server {server}", udid: "U", app: nil, server: "http://127.0.0.1:3203/"),
            "simtool mock clear --server http://127.0.0.1:3203"
        )
        XCTAssertEqual(
            TestRunExecutor.setupEnvironment(variables: [:], server: "http://127.0.0.1:3203/", appFacingServer: "http://127.0.0.1:3203/")["SIMTOOL_SERVER"],
            "http://127.0.0.1:3203"
        )
        XCTAssertEqual(
            TestRunExecutor.setupEnvironment(variables: [:], server: nil, appFacingServer: "http://192.168.0.10:3203/")["SIMTOOL_SERVER_URL"],
            "http://192.168.0.10:3203"
        )
    }

    func testSetupEnvironmentCarriesBothServerAddresses() {
        let environment = TestRunExecutor.setupEnvironment(
            variables: ["ACCOUNT": "+34600000000"],
            server: "http://127.0.0.1:3203",
            appFacingServer: "http://192.168.0.10:3203"
        )

        XCTAssertEqual(environment["SIMTOOL_SERVER"], "http://127.0.0.1:3203")
        XCTAssertEqual(environment["SIMTOOL_SERVER_URL"], "http://192.168.0.10:3203")
        XCTAssertEqual(environment["ACCOUNT"], "+34600000000")
    }

    // A test that sets one of these names itself means it; the run must not
    // overwrite what the file says.
    func testTheTestsOwnValuesWinOverTheRunsAddresses() {
        let environment = TestRunExecutor.setupEnvironment(
            variables: ["SIMTOOL_SERVER": "http://127.0.0.1:9999"],
            server: "http://127.0.0.1:3203",
            appFacingServer: nil
        )

        XCTAssertEqual(environment["SIMTOOL_SERVER"], "http://127.0.0.1:9999")
    }
}
