import Foundation
import XCTest
import Yams
@testable import SimToolCore

final class ProjectConfigLoaderTests: XCTestCase {
    // How long a simulator SimTool holds may sit unused: unset is the
    // default, `off` never, anything else is a duration.
    func testIdleTimeoutReadsAsADuration() throws {
        for (value, expected) in [("15m", 900.0), ("90", 90), ("off", 0), ("\"off\"", 0)] as [(String, TimeInterval)] {
            let root = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeConfig(minimalYAML + "\nidleTimeout: \(value)\n", in: root)
            XCTAssertEqual(try ProjectConfigLoader.load(startDirectory: root).idleTimeout, expected, value)
        }
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig(minimalYAML, in: root)
        XCTAssertNil(try ProjectConfigLoader.load(startDirectory: root).idleTimeout)
        try assertLoadThrows(minimalYAML + "\nidleTimeout: soon\n", contains: "Invalid `idleTimeout`")
    }

    func testLoadsConfigFromWorkingDirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig(minimalYAML, in: root)

        let config = try ProjectConfigLoader.load(startDirectory: root)
        XCTAssertEqual(config.simulator, "iPhone 16 Pro")
        XCTAssertEqual(config.bundleId, "com.example.MyApp")
        XCTAssertEqual(config.build.scheme, "App")
        // Relative workspace resolves against the project root (parent of .simtool).
        XCTAssertEqual(config.build.workspace, root.appendingPathComponent("App.xcworkspace").standardizedFileURL.path)
        // Build configuration defaults to Debug through the shared selection.
        XCTAssertEqual(try config.buildSelection().identity.configuration, "Debug")
        // Server defaults.
        XCTAssertEqual(config.server.host, "127.0.0.1")
        XCTAssertEqual(config.server.port, 3200)
        XCTAssertTrue(config.deeplinks.isEmpty)
        // Network and state loggers default on; app-facing URL points at the default server.
        XCTAssertTrue(config.networkLogger)
        XCTAssertTrue(config.stateLogger)
        XCTAssertEqual(config.appFacingServerURL, "http://127.0.0.1:3200")
        XCTAssertEqual(
            config.sourcePath,
            root.appendingPathComponent(".simtool/config.yml").standardizedFileURL.path
        )
        XCTAssertEqual(config.simtoolDirectory.path, root.appendingPathComponent(".simtool").standardizedFileURL.path)
    }

    // `projectRoot` resolves symlinks, not merely `standardizedFileURL`: on
    // macOS `/tmp` is itself a symlink to `/private/tmp`, so the same project
    // reached through either spelling must compare equal — otherwise it looks
    // foreign depending on which one happened to be current.
    func testProjectRootResolvesSymlinksSoTmpAndPrivateTmpAgree() throws {
        let name = "ProjectConfigLoaderTests-\(UUID().uuidString)"
        let viaTmp = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: viaTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: viaTmp) }
        try writeConfig(minimalYAML, in: viaTmp)
        // Same directory, reached the way it would be if `/tmp` were not
        // resolved — the two must still name one project, not two.
        let viaPrivateTmp = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)

        let reachedThroughTmp = try ProjectConfigLoader.load(startDirectory: viaTmp)
        let reachedThroughPrivateTmp = try ProjectConfigLoader.load(startDirectory: viaPrivateTmp)

        XCTAssertEqual(reachedThroughTmp.projectRoot, reachedThroughPrivateTmp.projectRoot)
    }

    func testDiscoversConfigInAncestorDirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig(minimalYAML, in: root)
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let config = try ProjectConfigLoader.load(startDirectory: nested)
        XCTAssertEqual(config.bundleId, "com.example.MyApp")
    }

    func testExplicitPathOverridesDiscovery() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent("cfg", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let custom = configDir.appendingPathComponent("custom.yml")
        try Data(minimalYAML.utf8).write(to: custom)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcworkspace", isDirectory: true),
            withIntermediateDirectories: true
        )
        let elsewhere = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let config = try ProjectConfigLoader.load(explicitPath: custom.path, startDirectory: elsewhere)
        XCTAssertEqual(config.simulator, "iPhone 16 Pro")
    }

    func testExplicitPathAnchorsSimtoolDirectoryAtItsParent() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent("cfg", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(minimalYAML.utf8).write(to: configDir.appendingPathComponent("custom.yml"))
        // Relative paths resolve against the parent of the config's directory.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcworkspace", isDirectory: true),
            withIntermediateDirectories: true
        )

        let config = try ProjectConfigLoader.load(
            explicitPath: configDir.appendingPathComponent("custom.yml").path,
            startDirectory: root
        )
        XCTAssertEqual(config.simtoolDirectory.path, configDir.standardizedFileURL.path)
        XCTAssertEqual(
            config.build.workspace,
            root.appendingPathComponent("App.xcworkspace").standardizedFileURL.path
        )
    }

    func testExplicitPathMissingThrows() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ProjectConfigLoader.load(explicitPath: root.appendingPathComponent("nope.yml").path, startDirectory: root))
    }

    func testNoConfigFoundThrows() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ProjectConfigLoader.load(startDirectory: root)) { error in
            XCTAssertTrue("\(error)".contains(".simtool/config.yml"))
        }
    }

    func testFullConfigParses() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let yaml = """
        simulator: 11111111-2222-3333-4444-555555555555
        bundleId: com.example.full
        build:
          project: App.xcodeproj
          scheme: Release
          configuration: Release
          derivedDataPath: /tmp/DerivedData
        server:
          host: 0.0.0.0
          port: 4500
        networkLogger: false
        stateLogger: false
        deeplinks:
          - name: Details
            url: myapp://items/42
          - name: Settings
            url: myapp://settings?section=general
        """
        try writeConfig(yaml, in: root)

        let config = try ProjectConfigLoader.load(startDirectory: root)
        XCTAssertEqual(config.build.project, root.appendingPathComponent("App.xcodeproj").standardizedFileURL.path)
        XCTAssertNil(config.build.workspace)
        XCTAssertEqual(try config.buildSelection().identity.configuration, "Release")
        XCTAssertEqual(config.build.derivedDataPath, "/tmp/DerivedData")
        XCTAssertEqual(config.server.host, "0.0.0.0")
        XCTAssertEqual(config.server.port, 4500)
        XCTAssertEqual(config.deeplinks.map(\.name), ["Details", "Settings"])
        XCTAssertEqual(config.deeplinks.first?.url, "myapp://items/42")
        XCTAssertFalse(config.networkLogger)
        XCTAssertFalse(config.stateLogger)
        // host 0.0.0.0 is rewritten to loopback for the app-facing URL.
        XCTAssertEqual(config.appFacingServerURL, "http://127.0.0.1:4500")
    }

    func testBuildSettingsStayTextAndApplyOnlyToTheConfiguredSource() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let yaml = """
        simulator: iPhone 16 Pro
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
          settings:
            MACOSX_DEPLOYMENT_TARGET: 15.0
            ENABLE_PREVIEWS: NO
        """
        try writeConfig(yaml, in: root)

        let config = try ProjectConfigLoader.load(startDirectory: root)
        // YAML would read 15.0 as a number and NO as a Bool; xcodebuild needs the text.
        XCTAssertEqual(config.build.settings, ["MACOSX_DEPLOYMENT_TARGET": "15.0", "ENABLE_PREVIEWS": "NO"])
        XCTAssertEqual(
            try config.buildSelection().identity.buildSettings,
            ["ENABLE_PREVIEWS=NO", "MACOSX_DEPLOYMENT_TARGET=15.0"]
        )

        let sameWorkspace = try SimulatorAppBuildSelection.validated(
            workspacePath: root.appendingPathComponent("App.xcworkspace").path, projectPath: nil, scheme: "OtherScheme"
        )
        let otherProject = try SimulatorAppBuildSelection.validated(
            workspacePath: nil, projectPath: root.appendingPathComponent("App.xcodeproj").path, scheme: "App"
        )
        XCTAssertEqual(config.build.settings(for: sameWorkspace), config.build.settings)
        XCTAssertEqual(config.build.settings(for: otherProject), [:])
    }

    func testRunBuildsForTheConfiguredSimulatorOnly() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("""
        simulator: 5A1C0DE0-0000-4000-8000-00000000BEEF
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
          configuration: Debug
          derivedDataPath: DerivedData
          settings:
            MACOSX_DEPLOYMENT_TARGET: 15.0
        """, in: root)
        let config = try ProjectConfigLoader.load(startDirectory: root)
        let devices = [
            SimulatorDevice(udid: "0THER-B00TED", name: "iPhone 16", runtime: "iOS-18", state: "Booted", isAvailable: true),
            SimulatorDevice(udid: "5A1C0DE0-0000-4000-8000-00000000BEEF", name: "iPhone 17 Pro", runtime: "iOS-26", state: "Shutdown", isAvailable: true),
        ]
        // What `run` does: resolve the simulator first, then build for it.
        let device = try SimulatorDeviceClient.selectDevice(nil, configured: config.simulator, from: devices)
        let selection = try config.buildSelection(for: device)
        let derivedData = root.appendingPathComponent("DerivedData").path

        // One architecture, not every simulator's: the build is for this device.
        XCTAssertEqual(SimulatorAppLifecycleClient.xcodebuildArguments(selection: selection, derivedDataPath: derivedData), [
            "xcodebuild",
            "-workspace", root.appendingPathComponent("App.xcworkspace").path,
            "-scheme", "App",
            "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=5A1C0DE0-0000-4000-8000-00000000BEEF",
            "-derivedDataPath", derivedData,
            "-hideShellScriptEnvironment",
            "MACOSX_DEPLOYMENT_TARGET=15.0",
            "build",
        ])
        // Locating the built product asks about the same destination.
        let settingsArguments = SimulatorAppLifecycleClient.xcodebuildArguments(
            selection: selection, derivedDataPath: derivedData, showBuildSettings: true
        )
        XCTAssertTrue(settingsArguments.contains("platform=iOS Simulator,id=5A1C0DE0-0000-4000-8000-00000000BEEF"), "\(settingsArguments)")
        // The cache entry is the one a build without a device uses.
        XCTAssertEqual(selection.identity, try config.buildSelection().identity)
    }

    func testRunOnTheBootedSimulatorBuildsForThatSimulator() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("""
        simulator: booted
        bundleId: com.example.MyApp
        build:
          project: App.xcodeproj
          scheme: App
        """, in: root)
        let config = try ProjectConfigLoader.load(startDirectory: root)
        let devices = [
            SimulatorDevice(udid: "SHUT-DOWN", name: "iPhone 16", runtime: "iOS-18", state: "Shutdown", isAvailable: true),
            SimulatorDevice(udid: "B00TED-UDID", name: "iPhone 17 Pro", runtime: "iOS-26", state: "Booted", isAvailable: true),
        ]
        // `booted` is a selector, not a destination: it resolves to a UDID first.
        let device = try SimulatorDeviceClient.selectDevice(nil, configured: config.simulator, from: devices)
        let arguments = SimulatorAppLifecycleClient.xcodebuildArguments(selection: try config.buildSelection(for: device), derivedDataPath: nil)

        let destination = try XCTUnwrap(arguments.firstIndex(of: "-destination"))
        XCTAssertEqual(arguments[destination + 1], "platform=iOS Simulator,id=B00TED-UDID")
    }

    func testXcodeBuilderLeavesTheXcodebuildOnlyKeysOut() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("""
        simulator: booted
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
          derivedDataPath: DerivedData
          settings:
            MACOSX_DEPLOYMENT_TARGET: 15.0
          builder: xcode-mcp
        """, in: root)
        let config = try ProjectConfigLoader.load(startDirectory: root)
        XCTAssertEqual(config.build.builder, .xcodeMCP)

        // Xcode builds where its own settings say, with the project's own
        // settings, so neither reaches its build nor its cache entry.
        let xcode = try config.buildSelection()
        XCTAssertEqual(xcode.builder, .xcodeMCP)
        XCTAssertEqual(xcode.identity.builder, .xcodeMCP)
        XCTAssertNil(xcode.identity.derivedDataPath)
        XCTAssertNil(xcode.identity.buildSettings)

        // `--builder xcodebuild` builds the same config the way it always did.
        let xcodebuild = try config.buildSelection(builder: .xcodebuild)
        XCTAssertNil(xcodebuild.identity.builder)
        XCTAssertEqual(xcodebuild.identity.derivedDataPath.map { URL(fileURLWithPath: $0).lastPathComponent }, "DerivedData")
        XCTAssertEqual(xcodebuild.identity.buildSettings, ["MACOSX_DEPLOYMENT_TARGET=15.0"])

        // Like `settings`, the builder applies to builds of the configured source only.
        let sameWorkspace = try SimulatorAppBuildSelection.validated(
            workspacePath: root.appendingPathComponent("App.xcworkspace").path, projectPath: nil, scheme: "OtherScheme"
        )
        let otherProject = try SimulatorAppBuildSelection.validated(
            workspacePath: nil, projectPath: root.appendingPathComponent("App.xcodeproj").path, scheme: "App"
        )
        XCTAssertEqual(config.build.builder(for: sameWorkspace), .xcodeMCP)
        XCTAssertNil(config.build.builder(for: otherProject))
    }

    // `app build --workspace <the configured one>` must build what `run`
    // builds, where `run` builds it: a DerivedData of its own is a second cold
    // build, and with Xcode's custom build locations a fight over module caches.
    func testAnExplicitWorkspaceOfTheConfiguredAppInheritsItsDerivedData() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("""
        simulator: booted
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
          derivedDataPath: DerivedData
          settings:
            MACOSX_DEPLOYMENT_TARGET: 15.0
        """, in: root)
        let build = try ProjectConfigLoader.load(startDirectory: root).build
        let workspace = root.appendingPathComponent("App.xcworkspace").path
        func explicit(
            workspace: String? = workspace,
            project: String? = nil,
            derivedDataPath: String? = nil,
            builder: SimulatorAppBuilder? = nil
        ) throws -> SimulatorAppBuildSelection {
            try ProjectConfig.Build.explicitSelection(
                configured: build, workspace: workspace, project: project, scheme: "App", configuration: nil,
                derivedDataPath: derivedDataPath, settings: [:], builder: builder
            )
        }

        // The same workspace by its path is the configured build: one cache entry.
        XCTAssertEqual(try explicit().identity, try build.selection().identity)
        XCTAssertEqual(try explicit().identity.derivedDataPath, root.appendingPathComponent("DerivedData").path)
        // A flag still wins over the key.
        XCTAssertEqual(try explicit(derivedDataPath: "/tmp/Elsewhere").identity.derivedDataPath, "/tmp/Elsewhere")
        // Another project takes nothing from the block.
        let other = try explicit(workspace: nil, project: root.appendingPathComponent("App.xcodeproj").path)
        XCTAssertNil(other.identity.derivedDataPath)
        XCTAssertNil(other.identity.buildSettings)
        // Without a config, the flags alone.
        XCTAssertNil(try ProjectConfig.Build.explicitSelection(
            configured: nil, workspace: workspace, project: nil, scheme: "App", configuration: nil,
            derivedDataPath: nil, settings: [:], builder: nil
        ).identity.derivedDataPath)
        // Xcode picks its DerivedData itself: the configured one stays out,
        // and asking for one is an error.
        let xcode = try explicit(builder: .xcodeMCP)
        XCTAssertNil(xcode.identity.derivedDataPath)
        XCTAssertNil(xcode.identity.buildSettings)
        XCTAssertThrowsError(try explicit(derivedDataPath: "/tmp/Elsewhere", builder: .xcodeMCP))
    }

    func testABuildRunsUnderTheConfiguredTimeoutOrNone() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("""
        simulator: booted
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
          timeout: 90m
        """, in: root)
        let config = try ProjectConfigLoader.load(startDirectory: root)
        XCTAssertEqual(config.build.timeout, 5_400)
        XCTAssertEqual(try config.buildSelection().buildTimeLimit, 5_400)
        let device = SimulatorDevice(udid: "DEVICE", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        XCTAssertEqual(try config.buildSelection(for: device).buildTimeLimit, 5_400, "run and test run build under it too")
        // A flag wins; 0 lifts the limit.
        XCTAssertEqual(try config.buildSelection(timeout: 60).buildTimeLimit, 60)
        XCTAssertNil(try config.buildSelection(timeout: 0).buildTimeLimit)
        // The configured workspace by its path takes it; another project does not.
        func explicit(workspace: String?, project: String?, timeout: TimeInterval? = nil) throws -> SimulatorAppBuildSelection {
            try ProjectConfig.Build.explicitSelection(
                configured: config.build, workspace: workspace, project: project, scheme: "App", configuration: nil,
                derivedDataPath: nil, settings: [:], builder: nil, timeout: timeout
            )
        }
        XCTAssertEqual(try explicit(workspace: root.appendingPathComponent("App.xcworkspace").path, project: nil).buildTimeLimit, 5_400)
        XCTAssertNil(try explicit(workspace: nil, project: root.appendingPathComponent("App.xcodeproj").path).buildTimeLimit)
        XCTAssertEqual(try explicit(workspace: nil, project: root.appendingPathComponent("App.xcodeproj").path, timeout: 30).buildTimeLimit, 30)
        // The time limit is no part of what was built: one cache entry.
        XCTAssertEqual(try config.buildSelection(timeout: 60).identity, try config.buildSelection().identity)

        try writeConfig("""
        simulator: booted
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
        """, in: root)
        XCTAssertNil(try ProjectConfigLoader.load(startDirectory: root).buildSelection().buildTimeLimit, "no limit unless one is set")

        try assertLoadThrows("""
        simulator: booted
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
          timeout: soon
        """, contains: "Invalid `build.timeout`")
    }

    func testBuildTimeoutsReadAsSecondsOrWithAUnit() throws {
        XCTAssertEqual(try SimulatorAppBuildSelection.parseTimeout("2700"), 2_700)
        XCTAssertEqual(try SimulatorAppBuildSelection.parseTimeout("30s"), 30)
        XCTAssertEqual(try SimulatorAppBuildSelection.parseTimeout("45m"), 2_700)
        XCTAssertEqual(try SimulatorAppBuildSelection.parseTimeout("1.5h"), 5_400)
        XCTAssertEqual(try SimulatorAppBuildSelection.parseTimeout(" 2H "), 7_200)
        XCTAssertEqual(try SimulatorAppBuildSelection.parseTimeout("0"), 0)
        XCTAssertEqual(try SimulatorAppBuildSelection.parseTimeout("168h"), 604_800)
        for invalid in ["", "m", "soon", "-5", "10x", "nan", "inf", "169h", "1e16"] {
            XCTAssertThrowsError(try SimulatorAppBuildSelection.parseTimeout(invalid), invalid)
        }
    }

    func testFlagsOverrideTheConfiguredBuildKeyByKey() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("""
        simulator: booted
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
          configuration: Beta
          derivedDataPath: DerivedData
          settings:
            MACOSX_DEPLOYMENT_TARGET: 15.0
            SWIFT_VERSION: 6
        """, in: root)
        let build = try ProjectConfigLoader.load(startDirectory: root).build

        // No flags: the configured build as it stands, the one `run` makes.
        let configured = try build.selection()
        XCTAssertEqual(configured.identity.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent }, "App.xcworkspace")
        XCTAssertEqual(configured.identity.scheme, "App")
        XCTAssertEqual(configured.identity.configuration, "Beta")
        XCTAssertEqual(configured.identity.derivedDataPath.map { URL(fileURLWithPath: $0).lastPathComponent }, "DerivedData")
        XCTAssertEqual(configured.identity.buildSettings, ["MACOSX_DEPLOYMENT_TARGET=15.0", "SWIFT_VERSION=6"])

        // Each flag wins over its key; the workspace stays the configured one.
        let flagged = try build.selection(
            scheme: "AppDev",
            configuration: "Debug",
            derivedDataPath: "/tmp/OtherDerivedData",
            settings: ["SWIFT_VERSION": "5", "OTHER_SWIFT_FLAGS": "-DPROBE"]
        )
        XCTAssertEqual(flagged.identity.workspacePath, configured.identity.workspacePath)
        XCTAssertEqual(flagged.identity.scheme, "AppDev")
        XCTAssertEqual(flagged.identity.configuration, "Debug")
        XCTAssertEqual(flagged.identity.derivedDataPath, "/tmp/OtherDerivedData")
        XCTAssertEqual(flagged.identity.buildSettings, ["MACOSX_DEPLOYMENT_TARGET=15.0", "OTHER_SWIFT_FLAGS=-DPROBE", "SWIFT_VERSION=5"])

        // Xcode leaves the configured DerivedData and settings out, but an
        // explicit one is still a mistake to report.
        let xcode = try build.selection(builder: .xcodeMCP, scheme: "AppDev")
        XCTAssertEqual(xcode.identity.scheme, "AppDev")
        XCTAssertNil(xcode.identity.derivedDataPath)
        XCTAssertNil(xcode.identity.buildSettings)
        XCTAssertThrowsError(try build.selection(builder: .xcodeMCP, derivedDataPath: "/tmp/OtherDerivedData"))
        XCTAssertThrowsError(try build.selection(builder: .xcodeMCP, settings: ["SWIFT_VERSION": "5"]))
    }

    func testUnknownBuilderThrows() throws {
        try assertLoadThrows("""
        simulator: booted
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
          builder: xcode
        """, contains: "Unknown `build.builder`")
    }

    func testInvalidBuildSettingNameThrows() throws {
        try assertLoadThrows("""
        simulator: iPhone 16 Pro
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
          settings:
            "MACOSX DEPLOYMENT": 15.0
        """, contains: "Invalid build setting name")
    }

    func testLaunchProfilesParse() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let yaml = """
        simulator: iPhone 16 Pro
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
        profiles:
          staging-account1:
            arguments: [-UITesting, -Environment, staging, -AutoLogin, "${ACCOUNT1}", -Code, 1234]
            env: { SOME_FLAG: 1, OTHER: "yes" }
            deeplink: myapp://home
          empty-profile: {}
        """
        try writeConfig(yaml, in: root)

        let config = try ProjectConfigLoader.load(startDirectory: root)
        // Sorted by name so listings and error hints are stable.
        XCTAssertEqual(config.profiles.map(\.name), ["empty-profile", "staging-account1"])

        let profile = try config.profile(named: "staging-account1")
        // Numbers and booleans keep their literal text: argv is text.
        XCTAssertEqual(
            profile.arguments,
            ["-UITesting", "-Environment", "staging", "-AutoLogin", "${ACCOUNT1}", "-Code", "1234"]
        )
        XCTAssertEqual(profile.environment, ["SOME_FLAG": "1", "OTHER": "yes"])
        XCTAssertEqual(profile.deeplink, "myapp://home")
        XCTAssertTrue(config.profiles.first { $0.name == "empty-profile" }?.arguments.isEmpty == true)
    }

    /// A test naming a profile that does not exist must say so — launching with
    /// no arguments at all would silently test the wrong thing.
    func testUnknownProfileListsAvailableOnes() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("""
        simulator: iPhone 16 Pro
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
        profiles:
          staging:
            arguments: [-UITesting]
        """, in: root)

        let config = try ProjectConfigLoader.load(startDirectory: root)
        XCTAssertThrowsError(try config.profile(named: "production")) { error in
            // Read `message` rather than interpolating: reflecting a struct
            // escapes the quotes around the profile name.
            let message = (error as? SimToolError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("Unknown launch profile 'production'"), message)
            XCTAssertTrue(message.contains("Available: staging"), message)
        }
    }

    func testInvalidProfileEnvironmentKeyThrows() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("""
        simulator: iPhone 16 Pro
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
        profiles:
          staging:
            env: { "BAD-KEY": 1 }
        """, in: root)

        XCTAssertThrowsError(try ProjectConfigLoader.load(startDirectory: root)) { error in
            XCTAssertTrue("\(error)".contains("invalid `env` key"))
        }
    }

    func testMissingRequiredFieldThrows() throws {
        try assertLoadThrows("""
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
        """, contains: "simulator")

        try assertLoadThrows("""
        simulator: iPhone 16
        build:
          workspace: App.xcworkspace
          scheme: App
        """, contains: "bundleId")

        try assertLoadThrows("""
        simulator: iPhone 16
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
        """, contains: "build.scheme")
    }

    func testAmbiguousOrEmptyBuildSelectionThrows() throws {
        try assertLoadThrows("""
        simulator: iPhone 16
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          project: App.xcodeproj
          scheme: App
        """, contains: "exactly one")

        try assertLoadThrows("""
        simulator: iPhone 16
        bundleId: com.example.MyApp
        build:
          scheme: App
        """, contains: "exactly one")
    }

    func testIncompleteDeeplinkThrows() throws {
        try assertLoadThrows("""
        simulator: iPhone 16
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
        deeplinks:
          - url: myapp://no-name
        """, contains: "missing `name`")

        try assertLoadThrows("""
        simulator: iPhone 16
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
        deeplinks:
          - name: NoURL
        """, contains: "missing `url`")
    }

    func testDuplicateDeeplinkNamesThrows() throws {
        try assertLoadThrows("""
        simulator: iPhone 16
        bundleId: com.example.MyApp
        build:
          workspace: App.xcworkspace
          scheme: App
        deeplinks:
          - name: Dup
            url: myapp://one
          - name: Dup
            url: myapp://two
        """, contains: "Duplicate deeplink name")
    }

    func testMissingBuildSourceThrows() throws {
        try assertLoadThrows("""
        simulator: iPhone 16
        bundleId: com.example.MyApp
        build:
          workspace: Missing.xcworkspace
          scheme: App
        """, contains: "Workspace not found")
    }

    func testInvalidYAMLThrows() throws {
        try assertLoadThrows("""
        simulator: [unterminated
        bundleId: com.example.MyApp
        """, contains: "YAML")
    }

    // MARK: - Helpers

    func testLoadIfPresentReturnsNilWhenNoConfigExists() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try ProjectConfigLoader.loadIfPresent(startDirectory: root))
    }

    func testLoadIfPresentLoadsDiscoveredConfig() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig(minimalYAML, in: root)

        let config = try ProjectConfigLoader.loadIfPresent(startDirectory: root)
        XCTAssertEqual(config?.simulator, "iPhone 16 Pro")
        XCTAssertEqual(config?.bundleId, "com.example.MyApp")
    }

    func testLoadIfPresentStillThrowsOnInvalidDiscoveredConfig() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig("bundleId: com.example.MyApp", in: root)

        XCTAssertThrowsError(try ProjectConfigLoader.loadIfPresent(startDirectory: root)) { error in
            XCTAssertTrue("\(error)".contains("simulator"), "\(error)")
        }
    }

    func testLoadIfPresentRequiresExplicitPathToExist() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("custom.yml").path

        XCTAssertThrowsError(try ProjectConfigLoader.loadIfPresent(explicitPath: missing, startDirectory: root))
    }

    private let minimalYAML = """
    simulator: iPhone 16 Pro
    bundleId: com.example.MyApp
    build:
      workspace: App.xcworkspace
      scheme: App
    """

    private func assertLoadThrows(_ yaml: String, contains needle: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfig(yaml, in: root)
        XCTAssertThrowsError(try ProjectConfigLoader.load(startDirectory: root), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(needle), "Expected error to contain '\(needle)', got: \(error)", file: file, line: line)
        }
    }

    private func writeConfig(_ yaml: String, in directory: URL) throws {
        let simtoolDir = directory.appendingPathComponent(SimToolDirectory.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: simtoolDir, withIntermediateDirectories: true)
        try Data(yaml.utf8).write(to: simtoolDir.appendingPathComponent(SimToolDirectory.configFileName))
        // Selection validation requires the referenced source to exist; the
        // fixtures all use these two names.
        for fixture in ["App.xcworkspace", "App.xcodeproj"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(fixture, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    func testTemplateRenderFillsDetectedFieldsAndParsesBack() throws {
        let detected = ProjectConfigTemplate.Detected(workspace: "MyApp.xcworkspace", project: nil, scheme: "MyApp")
        let yaml = ProjectConfigTemplate.render(detected)

        XCTAssertTrue(yaml.contains("simulator: booted"), yaml)
        XCTAssertTrue(yaml.contains("workspace: MyApp.xcworkspace"), yaml)
        XCTAssertTrue(yaml.contains("scheme: MyApp"), yaml)

        // The rendered starter config is structurally valid: it decodes and
        // passes loader validation (placeholders are non-empty).
        let raw = try YAMLDecoder().decode(RawProjectConfig.self, from: yaml)
        XCTAssertEqual(raw.simulator?.trimmingCharacters(in: .whitespaces), "booted")
        XCTAssertEqual(raw.build?.scheme, "MyApp")
        XCTAssertEqual(raw.build?.workspace, "MyApp.xcworkspace")
        XCTAssertNil(raw.build?.project)
    }

    func testTemplateRenderUsesPlaceholdersWhenNothingDetected() throws {
        let yaml = ProjectConfigTemplate.render(ProjectConfigTemplate.Detected())
        // Still valid YAML that decodes with a scheme placeholder present.
        let raw = try YAMLDecoder().decode(RawProjectConfig.self, from: yaml)
        XCTAssertEqual(raw.simulator?.trimmingCharacters(in: .whitespaces), "booted")
        XCTAssertNotNil(raw.build?.scheme)
        XCTAssertFalse((raw.build?.scheme ?? "").isEmpty)
    }

    func testTemplateDetectPrefersWorkspaceOverProjectAndFindsSingleScheme() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for fixture in ["MyApp.xcworkspace", "MyApp.xcodeproj"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(fixture, isDirectory: true), withIntermediateDirectories: true)
        }
        let schemes = root.appendingPathComponent("MyApp.xcworkspace/xcshareddata/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try Data("<Scheme/>".utf8).write(to: schemes.appendingPathComponent("MyApp.xcscheme"))

        let detected = ProjectConfigTemplate.detect(in: root)
        XCTAssertEqual(detected.workspace, "MyApp.xcworkspace")
        XCTAssertNil(detected.project)
        XCTAssertEqual(detected.scheme, "MyApp")
    }

    func testTemplateDetectFallsBackToProjectWhenNoWorkspace() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true), withIntermediateDirectories: true)

        let detected = ProjectConfigTemplate.detect(in: root)
        XCTAssertNil(detected.workspace)
        XCTAssertEqual(detected.project, "MyApp.xcodeproj")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
