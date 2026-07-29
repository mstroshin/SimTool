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

    func testInitParsesTheSkillScopeAndAgent() throws {
        XCTAssertEqual(try Init.parse(["--skill", "local"]).skill, .local)
        XCTAssertEqual(try Init.parse(["--skill", "global"]).skill, .global)
        XCTAssertEqual(try Init.parse(["--skill", "none"]).skill, AgentSkillInstaller.Scope.none)
        XCTAssertThrowsError(try Init.parse(["--skill", "everywhere"]))

        XCTAssertEqual(try Init.parse([]).skillAgent, .claude)
        XCTAssertEqual(try Init.parse(["--skill-agent", "codex"]).skillAgent, .codex)
        XCTAssertEqual(try Init.parse(["--skill-agent", "both"]).skillAgent.agents, [.claude, .codex])
        XCTAssertThrowsError(try Init.parse(["--skill-agent", "cursor"]))
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

    // The check the receiver of a test file hits first: the file refers to an
    // account it does not define, and nothing on this machine defines it either.
    func testUnresolvedVariablesNameWhatNothingDefines() {
        let test = TestDefinition(
            name: "Tab order",
            launch: TestLaunch(profile: "staging"),
            setup: ["echo ${SEED}"],
            steps: [TestStep(action: .waitFor(TestTarget(kind: .id, query: "Main"), timeout: nil))]
        )
        let profiles = [LaunchProfile(name: "staging", arguments: ["-FastLoginPhone", "${ACCOUNT}"])]

        let missing = TestCommand.Run.unresolvedVariables(
            test: test,
            profiles: profiles,
            environment: [:],
            overrides: [:]
        )

        XCTAssertEqual(missing, ["ACCOUNT", "SEED"])
    }

    func testTheTestFileTheEnvironmentAndAnOverrideAllSatisfyAReference() {
        var test = TestDefinition(
            launch: TestLaunch(profile: "staging"),
            steps: [TestStep(action: .waitFor(TestTarget(kind: .id, query: "Main"), timeout: nil))]
        )
        test.variables = ["ACCOUNT": "+34600000000"]
        let profiles = [LaunchProfile(name: "staging", arguments: ["-Phone", "${ACCOUNT}", "-Seed", "${SEED}"])]

        XCTAssertEqual(
            TestCommand.Run.unresolvedVariables(test: test, profiles: profiles, environment: ["SEED": "7"], overrides: [:]),
            []
        )
        XCTAssertEqual(
            TestCommand.Run.unresolvedVariables(test: test, profiles: profiles, environment: [:], overrides: ["SEED": "7"]),
            []
        )
    }

    // An exported empty string is not a value: it logs the run in as nobody.
    func testAnEmptyValueCountsAsUnresolved() {
        let test = TestDefinition(
            launch: TestLaunch(arguments: ["-Phone", "${ACCOUNT}"]),
            steps: [TestStep(action: .waitFor(TestTarget(kind: .id, query: "Main"), timeout: nil))]
        )

        XCTAssertEqual(
            TestCommand.Run.unresolvedVariables(test: test, profiles: [], environment: ["ACCOUNT": ""], overrides: [:]),
            ["ACCOUNT"]
        )
    }

    func testServeParsesWithoutBuiltInPortAndHostDefaults() throws {
        let command = try Serve.parse([])
        XCTAssertNil(command.device)
        XCTAssertNil(command.host)
        XCTAssertNil(command.port)
        XCTAssertNil(command.config)
        XCTAssertFalse(command.noReclaim)
    }

    // Hidden, but a started-on-our-own-initiative server depends on it.
    func testServeParsesNoReclaim() throws {
        XCTAssertTrue(try Serve.parse(["--no-reclaim"]).noReclaim)
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

    // A server belonging to another checkout drives another simulator and writes
    // its sessions into another project. Reusing it would report a verdict about
    // the wrong app.
    //
    // `isAlive` is forced to `true` throughout this group: these tests assert
    // the project-matching logic only, and must not depend on what process
    // pid 1 (the fixture's stand-in pid) happens to be on the machine running
    // the suite.
    func testAServerFromAnotherProjectIsNotReused() {
        let sessions = [session(id: "other", project: "/Users/x/Workspace/other", at: 200)]

        XCTAssertNil(TestCommand.ServerOptions.reusableSession(from: sessions, projectRoot: "/Users/x/Workspace/mine", isAlive: { _ in true }))
    }

    func testTheNewestSessionOfThisProjectIsReused() {
        let sessions = [
            session(id: "newest-elsewhere", project: "/Users/x/Workspace/other", at: 300),
            session(id: "mine-new", project: "/Users/x/Workspace/mine", at: 200),
            session(id: "mine-old", project: "/Users/x/Workspace/mine", at: 100),
        ]

        XCTAssertEqual(
            TestCommand.ServerOptions.reusableSession(from: sessions, projectRoot: "/Users/x/Workspace/mine", isAlive: { _ in true })?.sessionId,
            "mine-new"
        )
    }

    // Two runs outside any project share the "no project" context, which is what
    // the behaviour was before sessions recorded a project at all.
    func testOutsideAnyProjectASessionWithoutOneIsReused() {
        let sessions = [session(id: "rootless", project: nil, at: 100)]

        XCTAssertEqual(TestCommand.ServerOptions.reusableSession(from: sessions, projectRoot: nil, isAlive: { _ in true })?.sessionId, "rootless")
        XCTAssertNil(TestCommand.ServerOptions.reusableSession(from: sessions, projectRoot: "/Users/x/Workspace/mine", isAlive: { _ in true }))
    }

    // A session file outlives the process that wrote it — SIGKILL, a crash — and
    // that stale file must not be handed back as if the server were still there.
    func testASessionWhoseProcessIsGoneIsNotReused() {
        let sessions = [session(id: "dead", project: "/Users/x/Workspace/mine", at: 200)]

        XCTAssertNil(TestCommand.ServerOptions.reusableSession(from: sessions, projectRoot: "/Users/x/Workspace/mine", isAlive: { _ in false }))
    }

    private func session(id: String, project: String?, at seconds: TimeInterval) -> SessionInfo {
        SessionInfo(
            sessionId: id,
            pid: 1,
            device: SimulatorDevice(udid: "UDID", name: "iPhone", runtime: "iOS 18.2", state: "Booted", isAvailable: true),
            url: "http://127.0.0.1:3200",
            api: "http://127.0.0.1:3200/api/v1",
            startedAt: Date(timeIntervalSince1970: seconds),
            projectRoot: project
        )
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
