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

    func testInitParserAcceptsSkillScopes() throws {
        XCTAssertEqual(try Init.parse(["--skill", "local"]).skill, .local)
        XCTAssertEqual(try Init.parse(["--skill", "global"]).skill, .global)
        XCTAssertEqual(try Init.parse(["--skill", "none"]).skill, AgentSkill.Scope.none)
        XCTAssertThrowsError(try Init.parse(["--skill", "everywhere"]))
    }

    // Nil, not `.none`: an omitted flag means "ask", which is a different
    // outcome from an explicit `--skill none`.
    func testInitDefaultsToNoSkillChoice() throws {
        let command = try Init.parse([])
        XCTAssertNil(command.skill)
        XCTAssertFalse(command.force)
    }

    func testRunParserAcceptsViewerFlagsAndConfig() throws {
        let command = try Run.parse(["--no-network", "--no-state", "--config", ".simtool/config.yml", "--json"])
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

    func testBrowserOpensOnlyWhenWebRequested() {
        XCTAssertFalse(shouldOpenBrowser(webRequested: false, json: false, detachedChild: false),
                       "the browser must stay closed unless --web is passed")
        XCTAssertTrue(shouldOpenBrowser(webRequested: true, json: false, detachedChild: false))
        XCTAssertFalse(shouldOpenBrowser(webRequested: true, json: true, detachedChild: false),
                       "--json output is for scripts; never open a browser")
        XCTAssertFalse(shouldOpenBrowser(webRequested: true, json: false, detachedChild: true),
                       "detached children run headless")
    }

    func testServeParserSupportsOptInWeb() throws {
        XCTAssertFalse(try Serve.parse([]).web, "serve must not open the browser by default")
        XCTAssertTrue(try Serve.parse(["--web"]).web)
        // --no-open is a deprecated no-op kept so existing scripts keep parsing.
        XCTAssertTrue(try Serve.parse(["--no-open"]).noOpen)
    }

    func testOpenParserAcceptsOptionalNameAndConfig() throws {
        let withName = try Open.parse(["details", "--config", "custom.yml"])
        XCTAssertEqual(withName.name, "details")
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

    func testTestSubcommandsCoverRunningAndListing() {
        let names = TestCommand.configuration.subcommands.map { commandName(for: $0) }
        XCTAssertEqual(names, ["run", "list"])
    }

    func testTestRunParsesTestPathAndOptions() throws {
        let command = try TestCommand.Run.parse(["tests/badges.yml", "--title", "Badges", "--no-session", "--json"])
        XCTAssertEqual(command.test, "tests/badges.yml")
        XCTAssertEqual(command.title, "Badges")
        XCTAssertTrue(command.noSession)
        XCTAssertTrue(command.common.json)
    }

    func testTestRunRequiresTestPath() {
        XCTAssertThrowsError(try TestCommand.Run.parse([]))
    }

    func testServeParsesWithoutBuiltInPortAndHostDefaults() throws {
        let command = try Serve.parse([])
        XCTAssertNil(command.device)
        XCTAssertNil(command.host)
        XCTAssertNil(command.port)
        XCTAssertNil(command.config)
    }

    func testRunParsesDetachFlag() throws {
        XCTAssertFalse(try Run.parse([]).detach)
        XCTAssertTrue(try Run.parse(["--detach"]).detach)
    }

    func testServeParametersPreferExplicitFlagsOverConfig() {
        let params = ServeParameters.resolve(device: "UDID-1", host: "0.0.0.0", port: 3311, config: configFixture)
        XCTAssertEqual(params, ServeParameters(device: "UDID-1", host: "0.0.0.0", port: 3311))
    }

    func testServeParametersFallBackToConfigValues() {
        let params = ServeParameters.resolve(device: nil, host: nil, port: nil, config: configFixture)
        XCTAssertEqual(params, ServeParameters(device: "iPhone 16 Pro", host: "192.168.0.10", port: 4400))
    }

    func testServeParametersFallBackToBuiltInsWithoutConfig() {
        let params = ServeParameters.resolve(device: nil, host: nil, port: nil, config: nil)
        XCTAssertEqual(params, ServeParameters(device: nil, host: "127.0.0.1", port: 3200))
    }

    private var configFixture: ProjectConfig {
        ProjectConfig(
            simulator: "iPhone 16 Pro",
            bundleId: "com.example.MyApp",
            build: ProjectConfig.Build(workspace: "App.xcworkspace", scheme: "App"),
            server: ProjectConfig.Server(host: "192.168.0.10", port: 4400)
        )
    }

    private func commandName(for command: ParsableCommand.Type) -> String {
        command.configuration.commandName ?? String(describing: command).lowercased()
    }
}
