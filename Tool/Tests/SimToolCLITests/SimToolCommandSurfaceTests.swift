import ArgumentParser
import XCTest
@testable import SimToolCLI
import SimToolCore

final class SimToolCommandSurfaceTests: XCTestCase {
    func testLogsTailParsesStdoutCaptureWithApp() throws {
        let command = try Logs.Tail.parse([
            "--device", "iPhone 16",
            "--app", "com.example.MyApp",
            "--stdout",
            "--lines", "50",
            "--json",
        ])
        XCTAssertEqual(command.app, "com.example.MyApp")
        XCTAssertTrue(command.captureStdout)
        XCTAssertEqual(command.lines, 50)
        XCTAssertTrue(command.common.json)
    }

    func testLogsTailRejectsStdoutCaptureWithoutApp() {
        XCTAssertThrowsError(try Logs.Tail.parse(["--stdout"]))
    }

    func testLogsTailDefaultsToOSLogOnlySnapshot() throws {
        let command = try Logs.Tail.parse(["--app", "com.example.MyApp"])
        XCTAssertFalse(command.captureStdout)
    }

    func testLogCaptureJSONPayloadShape() throws {
        let payload = LogCaptureEntriesPayload(
            entries: [LogEntry(sequence: 1, timestamp: "2026-01-01T00:00:00.000Z", source: .stdout, message: "hello")],
            cursor: 1,
            droppedCount: 0
        )
        let json = try JSON.string(payload, pretty: false)
        XCTAssertTrue(json.contains("\"entries\""))
        XCTAssertTrue(json.contains("\"cursor\""))
        XCTAssertTrue(json.contains("\"source\":\"stdout\""))
        XCTAssertTrue(json.contains("\"sequence\":1"))
    }

    func testTopLevelCommandIncludesAppNamespace() {
        let names = SimTool.configuration.subcommands.map { commandName(for: $0) }
        XCTAssertTrue(names.contains("app"))
    }

    func testTopLevelCommandIncludesRunAndOpen() {
        let names = SimTool.configuration.subcommands.map { commandName(for: $0) }
        XCTAssertTrue(names.contains("run"))
        XCTAssertTrue(names.contains("open"))
    }

    func testTopLevelCommandIncludesChecksum() {
        let names = SimTool.configuration.subcommands.map { commandName(for: $0) }
        XCTAssertTrue(names.contains("checksum"))
    }

    func testChecksumParserAcceptsConfigAndAppPath() throws {
        let command = try Checksum.parse(["--config", ".simtool/config.yml", "--app-path", "/tmp/Example.app", "--json"])
        XCTAssertEqual(command.config, ".simtool/config.yml")
        XCTAssertEqual(command.appPath, "/tmp/Example.app")
        XCTAssertTrue(command.common.json)

        let bare = try Checksum.parse([])
        XCTAssertNil(bare.config)
        XCTAssertNil(bare.appPath)
        XCTAssertFalse(bare.common.json)
    }

    func testRunParserAcceptsViewerFlagsAndConfig() throws {
        let command = try Run.parse(["--native", "--no-network", "--no-state", "--config", ".simtool/config.yml", "--json"])
        XCTAssertTrue(command.native)
        XCTAssertFalse(command.web)
        XCTAssertTrue(command.noNetwork)
        XCTAssertTrue(command.noState)
        XCTAssertEqual(command.config, ".simtool/config.yml")
        XCTAssertTrue(command.common.json)
    }

    func testRunDefaultsLoggersOn() throws {
        let command = try Run.parse([])
        XCTAssertFalse(command.noNetwork)
        XCTAssertFalse(command.noState)
    }

    func testRunParserAcceptsForce() throws {
        let command = try Run.parse(["--force"])
        XCTAssertTrue(command.force)
        XCTAssertFalse(try Run.parse([]).force, "force must default to off")
    }

    func testRunRejectsBothViewerFlags() {
        XCTAssertThrowsError(try Run.parse(["--web", "--native"]))
    }

    func testBrowserOpensOnlyWhenWebRequested() {
        XCTAssertFalse(shouldOpenBrowser(webRequested: false, json: false, nativeWindow: false, detachedChild: false),
                       "the browser must stay closed unless --web is passed")
        XCTAssertTrue(shouldOpenBrowser(webRequested: true, json: false, nativeWindow: false, detachedChild: false))
        XCTAssertFalse(shouldOpenBrowser(webRequested: true, json: true, nativeWindow: false, detachedChild: false),
                       "--json output is for scripts; never open a browser")
        XCTAssertFalse(shouldOpenBrowser(webRequested: true, json: false, nativeWindow: true, detachedChild: false),
                       "the native window replaces the browser viewer")
        XCTAssertFalse(shouldOpenBrowser(webRequested: true, json: false, nativeWindow: false, detachedChild: true),
                       "detached children run headless")
    }

    func testServeParserSupportsOptInWeb() throws {
        XCTAssertFalse(try Serve.parse([]).web, "serve must not open the browser by default")
        XCTAssertTrue(try Serve.parse(["--web"]).web)
        // --no-open is a deprecated no-op kept so existing scripts keep parsing.
        XCTAssertTrue(try Serve.parse(["--no-open"]).noOpen)
        XCTAssertThrowsError(try Serve.parse(["--web", "--window"]))
    }

    func testOpenParserAcceptsOptionalNameAndConfig() throws {
        let withName = try Open.parse(["profile", "--config", "custom.yml"])
        XCTAssertEqual(withName.name, "profile")
        XCTAssertEqual(withName.config, "custom.yml")

        let withoutName = try Open.parse([])
        XCTAssertNil(withoutName.name)
    }

    func testDeeplinkOpenPayloadJSONShape() throws {
        let device = SimulatorDevice(udid: "UDID-1", name: "iPhone 16", runtime: "iOS 18.0", state: "Booted", isAvailable: true)
        let payload = SimulatorDeeplinkOpenPayload(name: "Details", url: "myapp://items/42", device: device)
        let json = try JSON.string(payload, pretty: false)
        XCTAssertTrue(json.contains("\"name\":\"Details\""))
        XCTAssertTrue(json.contains("\"url\":\"myapp://items/42\""))
        XCTAssertTrue(json.contains("\"opened\":true"))
        XCTAssertTrue(json.contains("\"udid\":\"UDID-1\""))
    }

    func testUnknownDeeplinkNameListsAvailable() throws {
        let config = ProjectConfig(
            simulator: "iPhone 16",
            bundleId: "com.example.MyApp",
            build: ProjectConfig.Build(workspace: "App.xcworkspace", scheme: "App"),
            deeplinks: [
                ProjectConfig.Deeplink(name: "Details", url: "myapp://items"),
                ProjectConfig.Deeplink(name: "Settings", url: "myapp://settings"),
            ]
        )
        XCTAssertEqual(try config.deeplink(named: "Details").url, "myapp://items")
        XCTAssertThrowsError(try config.deeplink(named: "Nope")) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("Details"))
            XCTAssertTrue(message.contains("Settings"))
        }
    }

    func testAppNamespaceIncludesBuildLaunchAndTest() {
        let names = AppCommand.configuration.subcommands.map { commandName(for: $0) }
        XCTAssertTrue(names.contains("build"))
        XCTAssertTrue(names.contains("launch"))
        XCTAssertTrue(names.contains("test"))
    }

    func testAppBuildParserAcceptsBuildOptions() throws {
        let command = try AppCommand.Build.parse([
            "--workspace", "Example.xcworkspace",
            "--scheme", "Example",
            "--configuration", "Debug",
            "--derived-data-path", "/tmp/DerivedData",
            "--force",
            "--json",
        ])

        XCTAssertEqual(command.buildOptions.workspace, "Example.xcworkspace")
        XCTAssertEqual(command.buildOptions.scheme, "Example")
        XCTAssertEqual(command.buildOptions.configuration, "Debug")
        XCTAssertEqual(command.buildOptions.derivedDataPath, "/tmp/DerivedData")
        XCTAssertTrue(command.buildOptions.force)
        XCTAssertTrue(command.common.json)
    }

    func testAppLaunchParserAcceptsDeviceAndBuildOptions() throws {
        let command = try AppCommand.Launch.parse([
            "--device", "iPhone 16",
            "--project", "Example.xcodeproj",
            "--scheme", "Example",
            "--env", "SIMTOOL_NETWORK_LOGGER=1",
            "--env", "SIMTOOL_SERVER_URL=http://127.0.0.1:3311",
            "--json",
        ])

        XCTAssertEqual(command.device, "iPhone 16")
        XCTAssertEqual(command.buildOptions.project, "Example.xcodeproj")
        XCTAssertEqual(command.buildOptions.scheme, "Example")
        XCTAssertEqual(command.environment, ["SIMTOOL_NETWORK_LOGGER=1", "SIMTOOL_SERVER_URL=http://127.0.0.1:3311"])
        XCTAssertTrue(command.common.json)
    }

    func testAppLaunchParserForwardsArgumentsAfterTerminator() throws {
        let command = try AppCommand.Launch.parse([
            "--device", "iPhone 16",
            "--project", "Example.xcodeproj",
            "--scheme", "Example",
            "--",
            "-DebugFlag", "1234",
            "-AnotherFlag", "value",
        ])

        XCTAssertEqual(command.device, "iPhone 16")
        XCTAssertEqual(command.launchArguments, ["-DebugFlag", "1234", "-AnotherFlag", "value"])
    }

    func testAppTestParserAcceptsDeviceAndXcodeOptions() throws {
        let command = try AppCommand.Test.parse([
            "--device", "iPhone 16",
            "--workspace", "Example.xcworkspace",
            "--scheme", "ExampleUITests",
            "--configuration", "Debug",
            "--derived-data-path", "/tmp/DerivedData",
            "--json",
        ])

        XCTAssertEqual(command.device, "iPhone 16")
        XCTAssertEqual(command.testOptions.workspace, "Example.xcworkspace")
        XCTAssertEqual(command.testOptions.scheme, "ExampleUITests")
        XCTAssertEqual(command.testOptions.configuration, "Debug")
        XCTAssertEqual(command.testOptions.derivedDataPath, "/tmp/DerivedData")
        XCTAssertTrue(command.common.json)
    }

    func testTopLevelCommandIncludesTest() {
        let names = SimTool.configuration.subcommands.map { commandName(for: $0) }
        XCTAssertTrue(names.contains("test"))
    }

    func testTestStartParsesTitle() throws {
        let command = try TestCommand.Start.parse(["Verify preference editing", "--json"])
        XCTAssertEqual(command.title, "Verify preference editing")
        XCTAssertTrue(command.common.json)
    }

    func testTestStepParsesRepeatedLogOptions() throws {
        let command = try TestCommand.Step.parse(["Tapped Save", "--log", "[Settings] save OK", "--log", "[Sync] pushed"])
        XCTAssertEqual(command.text, "Tapped Save")
        XCTAssertEqual(command.logs, ["[Settings] save OK", "[Sync] pushed"])
    }

    func testTestLogRequiresAtLeastOneLine() {
        XCTAssertThrowsError(try TestCommand.LogLines.parse([]))
    }

    func testTestStopRequiresTerminalStatus() throws {
        XCTAssertThrowsError(try TestCommand.Stop.parse([]))
        XCTAssertThrowsError(try TestCommand.Stop.parse(["--status", "maybe"]))
        XCTAssertThrowsError(try TestCommand.Stop.parse(["--status", "running"]))
        let command = try TestCommand.Stop.parse(["--status", "passed"])
        XCTAssertEqual(command.status, "passed")
    }

    private func commandName(for command: ParsableCommand.Type) -> String {
        command.configuration.commandName ?? String(describing: command).lowercased()
    }
}
