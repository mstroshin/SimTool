import Foundation
import XCTest
import Yams
@testable import SimToolCore

final class ProjectConfigLoaderTests: XCTestCase {
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
