import Foundation
import XCTest
@testable import SimToolCore

final class XcodeMCPBuilderTests: XCTestCase {
    func testBuildsForTheSimulatorAndFindsTheAppXcodeBuilt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let device = SimulatorDevice(
            udid: "DEVICE", name: "Sim 1", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4", state: "Booted", isAvailable: true
        )
        let tools = ScriptedTools([
            "XcodeOpenWorkspace": .object([
                "workspaceIdentifier": .string("workspace-1"),
                "activeScheme": .string("Other"),
                "activeRunDestination": .string("iPhone 18 Pro"),
            ]),
            "XcodeSwitchScheme": .object(["activeSchemeName": .string("App"), "message": .string("ok")]),
            "XcodeListRunDestinations": .object([
                "activeDestinationDisplayTitle": .string("iPhone 18 Pro"),
                "truncated": .bool(false),
                "destinations": .array([
                    destination("iPhone 18 Pro", os: "27.0", active: true),
                    destination("Sim 1 (27.0)", os: "27.0"),
                    destination("Sim 1 (26.4.1)", os: "26.4.1"),
                    destination("Any iOS Simulator Device (arm64, x86_64)", generic: true),
                ]),
            ]),
            "XcodeSwitchRunDestination": .object(["activeDestinationDisplayTitle": .string("Sim 1 (26.4.1)")]),
            "BuildProject": .object([
                "buildResult": .string("The project built successfully."),
                "elapsedTime": .number(2.5),
                "errors": .array([]),
                "fullLogPath": .string(fixture.log.path),
            ]),
            "XcodeListTargets": fixture.appTargets,
            "GetTargetBuildSettings": fixture.appSettings,
        ])

        let outcome = try await XcodeMCPBuilder.build(
            selection: fixture.selection.targeting(device), device: device, tools: tools, timeoutSeconds: 60
        )

        XCTAssertEqual(outcome.appBundleURL.path, fixture.app.path)
        XCTAssertEqual(outcome.configuration, "Debug")
        XCTAssertEqual(outcome.destination, "Sim 1 (26.4.1)")
        XCTAssertEqual(tools.names, [
            "XcodeOpenWorkspace", "XcodeSwitchScheme", "XcodeListRunDestinations", "XcodeSwitchRunDestination",
            "BuildProject", "XcodeListTargets", "GetTargetBuildSettings",
        ])
        XCTAssertEqual(tools.arguments("XcodeOpenWorkspace")?["path"], .string(fixture.workspace.path))
        XCTAssertEqual(tools.arguments("XcodeSwitchScheme")?["schemeName"], .string("App"))
        // The simulator's own entry — its iOS version, not a namesake's.
        XCTAssertEqual(tools.arguments("XcodeSwitchRunDestination")?["displayTitle"], .string("Sim 1 (26.4.1)"))
        XCTAssertEqual(tools.arguments("GetTargetBuildSettings")?["targetName"], .string("App"))
        for call in tools.calls.dropFirst() {
            XCTAssertEqual(call.arguments["workspaceIdentifier"], .string("workspace-1"), call.name)
        }
        XCTAssertTrue(outcome.stepSummary.stdout.contains("Destination: Sim 1 (26.4.1)"), outcome.stepSummary.stdout)
    }

    func testAWorkspaceAlreadySetUpIsBuiltAsItIs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let device = SimulatorDevice(udid: "DEVICE", name: "Sim 1", runtime: "iOS-26-4", state: "Booted", isAvailable: true)
        let tools = ScriptedTools([
            "XcodeOpenWorkspace": .object(["workspaceIdentifier": .string("workspace-1"), "activeScheme": .string("App")]),
            "XcodeListRunDestinations": .object([
                "activeDestinationDisplayTitle": .string("Sim 1"),
                "destinations": .array([destination("Sim 1", os: "26.4", active: true)]),
            ]),
            "BuildProject": .object(["buildResult": .string("The project built successfully."), "errors": .array([]), "fullLogPath": .string(fixture.log.path)]),
            "XcodeListTargets": fixture.appTargets,
            "GetTargetBuildSettings": fixture.appSettings,
        ])

        _ = try await XcodeMCPBuilder.build(selection: fixture.selection.targeting(device), device: device, tools: tools, timeoutSeconds: 60)

        XCTAssertEqual(tools.names, ["XcodeOpenWorkspace", "XcodeListRunDestinations", "BuildProject", "XcodeListTargets", "GetTargetBuildSettings"])
    }

    func testReadsTheCompleteDestinationListWhenXcodeCutsItShort() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let device = SimulatorDevice(udid: "DEVICE", name: "Sim 41", runtime: "iOS-26-4", state: "Booted", isAvailable: true)
        let full = fixture.root.appendingPathComponent("destinations.txt")
        try Data("""
        ================================================================================
        RUN DESTINATION LIST
        Active Scheme: App
        ================================================================================

        --------------------------------------------------------------------------------
        DESTINATION_INDEX: 1/42
        DISPLAY_TITLE: iPhone 18 Pro
        GROUP: Simulators
        IS_ACTIVE: true
        IS_ELIGIBLE: true
        INELIGIBILITY_MESSAGE: (none)
        PLATFORM_IDENTIFIER: com.apple.platform.iphonesimulator
        OS_VERSION: 27.0
        IS_SIMULATOR: true
        IS_GENERIC_DEVICE: false
        --------------------------------------------------------------------------------
        DESTINATION_INDEX: 41/42
        DISPLAY_TITLE: Sim 41
        GROUP: Simulators
        IS_ACTIVE: false
        IS_ELIGIBLE: true
        PLATFORM_IDENTIFIER: com.apple.platform.iphonesimulator
        OS_VERSION: 26.4.1
        IS_SIMULATOR: true
        IS_GENERIC_DEVICE: false
        --------------------------------------------------------------------------------
        DESTINATION_INDEX: 42/42
        DISPLAY_TITLE: Any iOS Simulator Device (arm64, x86_64)
        GROUP: Build
        IS_ACTIVE: false
        IS_ELIGIBLE: true
        PLATFORM_IDENTIFIER: com.apple.platform.iphonesimulator
        OS_VERSION: (none)
        IS_SIMULATOR: false
        IS_GENERIC_DEVICE: true
        """.utf8).write(to: full)
        let tools = ScriptedTools([
            "XcodeOpenWorkspace": .object(["workspaceIdentifier": .string("workspace-1"), "activeScheme": .string("App")]),
            "XcodeListRunDestinations": .object([
                "activeDestinationDisplayTitle": .string("iPhone 18 Pro"),
                "destinations": .array([destination("iPhone 18 Pro", os: "27.0", active: true)]),
                "truncated": .bool(true),
                "fullRunDestinationListPath": .string(full.path),
            ]),
            "XcodeSwitchRunDestination": .object(["activeDestinationDisplayTitle": .string("Sim 41")]),
            "BuildProject": .object(["buildResult": .string("The project built successfully."), "errors": .array([]), "fullLogPath": .string(fixture.log.path)]),
            "XcodeListTargets": fixture.appTargets,
            "GetTargetBuildSettings": fixture.appSettings,
        ])

        _ = try await XcodeMCPBuilder.build(selection: fixture.selection.targeting(device), device: device, tools: tools, timeoutSeconds: 60)

        XCTAssertEqual(tools.arguments("XcodeSwitchRunDestination")?["displayTitle"], .string("Sim 41"))
        XCTAssertEqual(XcodeRunDestination.parseList(try String(contentsOf: full, encoding: .utf8)).map(\.displayTitle), [
            "iPhone 18 Pro", "Sim 41", "Any iOS Simulator Device (arm64, x86_64)",
        ])
    }

    func testChoosesTheSimulatorsOwnEntryElseAnotherSimulatorElseAnyIOSSimulator() {
        let destinations = [
            XcodeRunDestination(displayTitle: "My iPhone", isSimulator: false, platformIdentifier: "com.apple.platform.iphoneos"),
            XcodeRunDestination(displayTitle: "iPhone 17 Pro (27.0)", isSimulator: true, osVersion: "27.0"),
            XcodeRunDestination(displayTitle: "iPhone 17 Pro (26.4.1)", isSimulator: true, osVersion: "26.4.1"),
            XcodeRunDestination(displayTitle: "iPhone 16", isEligible: false, isSimulator: true, osVersion: "18.0"),
            XcodeRunDestination(displayTitle: "Any iOS Device (arm64)", isSimulator: false, isGenericDevice: true, platformIdentifier: "com.apple.platform.iphoneos"),
            XcodeRunDestination(displayTitle: "Any iOS Simulator Device (arm64, x86_64)", isSimulator: false, isGenericDevice: true),
        ]
        func device(_ name: String, _ runtime: String) -> SimulatorDevice {
            SimulatorDevice(udid: name, name: name, runtime: runtime, state: "Shutdown", isAvailable: true)
        }

        // simctl names no patch version; Xcode adds the OS to tell namesakes apart.
        XCTAssertEqual(
            XcodeRunDestination.choose(from: destinations, for: device("iPhone 17 Pro", "com.apple.CoreSimulator.SimRuntime.iOS-26-4"))?.displayTitle,
            "iPhone 17 Pro (26.4.1)"
        )
        XCTAssertEqual(
            XcodeRunDestination.choose(from: destinations, for: device("iPhone 17 Pro", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"))?.displayTitle,
            "iPhone 17 Pro (27.0)"
        )
        // An ineligible namesake is skipped; another simulator builds the same
        // architecture on this Mac.
        XCTAssertEqual(
            XcodeRunDestination.choose(from: destinations, for: device("iPhone 16", "com.apple.CoreSimulator.SimRuntime.iOS-18-0"))?.displayTitle,
            "iPhone 17 Pro (27.0)"
        )
        // No device: every simulator architecture, as xcodebuild's generic destination.
        XCTAssertEqual(XcodeRunDestination.choose(from: destinations, for: nil)?.displayTitle, "Any iOS Simulator Device (arm64, x86_64)")
        XCTAssertNil(XcodeRunDestination.choose(from: Array(destinations.prefix(1)), for: nil))
        XCTAssertEqual(device("X", "com.apple.CoreSimulator.SimRuntime.iOS-26-4").osVersion, "26.4")
    }

    func testAFailedBuildReportsXcodesErrors() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tools = ScriptedTools([
            "XcodeOpenWorkspace": .object(["workspaceIdentifier": .string("workspace-1"), "activeScheme": .string("App")]),
            "XcodeListRunDestinations": .object(["destinations": .array([destination("Any iOS Simulator Device", generic: true)])]),
            "XcodeSwitchRunDestination": .object([:]),
            "BuildProject": .object([
                "buildResult": .string("The build failed."),
                "errors": .array([
                    .object([
                        "classification": .string("error"),
                        "message": .string("Cannot convert value of type 'String' to specified type 'Int'"),
                        "filePath": .string("/src/App.swift"),
                        "lineNumber": .number(10),
                    ]),
                    .object(["classification": .string("warning"), "message": .string("Variable was never used")]),
                ]),
                "fullLogPath": .string("/tmp/build.log"),
            ]),
        ])

        do {
            _ = try await XcodeMCPBuilder.build(selection: fixture.selection, device: nil, tools: tools, timeoutSeconds: 60)
            XCTFail("A failed build must throw")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("/src/App.swift:10: Cannot convert value of type"), message)
            XCTAssertTrue(message.contains("Full log: /tmp/build.log"), message)
            XCTAssertFalse(message.contains("never used"), message)
        }
        XCTAssertFalse(tools.names.contains("XcodeListTargets"))

        XCTAssertTrue(XcodeMCPBuilder.buildFailed("The build failed."))
        XCTAssertTrue(XcodeMCPBuilder.buildFailed("Build cancelled"))
        XCTAssertFalse(XcodeMCPBuilder.buildFailed("The project built successfully."))
        XCTAssertFalse(XcodeMCPBuilder.buildFailed("Build succeeded with 0 errors"))
    }

    func testAnUnapprovedSimToolIsToldHowToGetApproved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tools = ScriptedTools([:], errors: [
            "XcodeOpenWorkspace": "This agent isn't approved to use Xcode's tools yet.",
        ])

        do {
            _ = try await XcodeMCPBuilder.build(selection: fixture.selection, device: nil, tools: tools, timeoutSeconds: 60)
            XCTFail("A refused tool call must throw")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("approved to use Xcode"), message)
            XCTAssertTrue(message.contains("xcrun mcp-server status"), message)
        }
    }

    func testTheBuildLogNamesTheTopLevelAppAndItsConfiguration() {
        let products = "/dd/Build/Products"
        let log = """
        Validate /dd/Build/Products/Beta-iphonesimulator/My App.app
            cd /src
            builtin-validationUtility /dd/Build/Products/Beta-iphonesimulator/My\\ App.app -no-validate-extension
        CodeSign /dd/Build/Products/Beta-iphonesimulator/My App.app/PlugIns/Widget.appex
        CodeSign /dd/Build/Products/Beta-iphonesimulator/Kit.framework
        Copy /dd/Build/Products/Beta-iphonesimulator/Package.bundle/x.apple
        Ld /dd/Build/Products/Beta-iphonesimulator/Widget.appex/Widget
        Ld /dd/Build/Products/Beta-iphoneos/My App.app/My App
        """

        let apps = XcodeMCPBuilder.loggedApps(in: log, productsRoot: products)

        XCTAssertEqual(apps.map(\.directory), ["Beta-iphonesimulator"])
        XCTAssertEqual(apps.map(\.name), ["My App.app"])
        XCTAssertEqual(XcodeMCPBuilder.productName(["PRODUCT_NAME": "My App", "WRAPPER_EXTENSION": "app"]), "My App.app")
        XCTAssertNil(XcodeMCPBuilder.productName(["PRODUCT_NAME": "Kit", "WRAPPER_EXTENSION": "framework"]))
    }

    // MARK: - Helpers

    private func destination(_ title: String, os: String? = nil, active: Bool = false, generic: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = [
            "displayTitle": .string(title),
            "isActive": .bool(active),
            "isEligible": .bool(true),
            "isSimulator": .bool(!generic),
            "isGenericDevice": .bool(generic),
            "platformIdentifier": .string(XcodeRunDestination.simulatorPlatform),
        ]
        if let os { object["osVersion"] = .string(os) }
        return .object(object)
    }

    /// A workspace, the app Xcode "built" for it and the log that names it.
    private struct Fixture {
        let root: URL
        let workspace: URL
        let app: URL
        let log: URL
        let selection: SimulatorAppBuildSelection

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            workspace = root.appendingPathComponent("App.xcworkspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            app = root.appendingPathComponent("DerivedData/Build/Products/Debug-iphonesimulator/App.app", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            log = root.appendingPathComponent("build.log")
            try Data("""
            Build App
                Sign App.app
                    CodeSign \(app.path)
                Validate App.app
                    Validate \(app.path)
            ** BUILD SUCCEEDED **
            """.utf8).write(to: log)
            selection = try SimulatorAppBuildSelection.validated(
                workspacePath: workspace.path, projectPath: nil, scheme: "App", builder: .xcodeMCP
            )
        }

        var appTargets: JSONValue {
            .object(["targets": .array([
                .object(["name": .string("App"), "containingProjectPath": .string("App.xcodeproj"), "isTestTarget": .bool(false)]),
                .object(["name": .string("Demo"), "containingProjectPath": .string("Demo.xcodeproj"), "isTestTarget": .bool(false)]),
            ])])
        }

        var appSettings: JSONValue {
            .object(["targetName": .string("App"), "buildSettings": .array([
                .object(["macroName": .string("SYMROOT"), "evaluatedValue": .string(root.appendingPathComponent("DerivedData/Build/Products").path)]),
                .object(["macroName": .string("PRODUCT_NAME"), "value": .string("$(TARGET_NAME)"), "evaluatedValue": .string("App")]),
                .object(["macroName": .string("WRAPPER_EXTENSION"), "value": .string("app"), "evaluatedValue": .string("app")]),
            ])])
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// Answers each tool with a canned structured result, or a tool error, and
/// records the calls.
private final class ScriptedTools: MCPToolCalling, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [String: JSONValue]
    private let errors: [String: String]
    private var recorded: [(name: String, arguments: [String: JSONValue])] = []

    init(_ answers: [String: JSONValue], errors: [String: String] = [:]) {
        self.answers = answers
        self.errors = errors
    }

    func callTool(_ name: String, arguments: [String: JSONValue], timeoutSeconds: TimeInterval?) async throws -> MCPToolResult {
        try answer(name, arguments)
    }

    private func answer(_ name: String, _ arguments: [String: JSONValue]) throws -> MCPToolResult {
        lock.lock()
        defer { lock.unlock() }
        recorded.append((name, arguments))
        if let error = errors[name] {
            return MCPToolResult(isError: true, text: error)
        }
        guard let answer = answers[name] else {
            throw SimToolError("Unexpected tool call: \(name)")
        }
        return MCPToolResult(text: "", structured: answer.objectValue)
    }

    var calls: [(name: String, arguments: [String: JSONValue])] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var names: [String] { calls.map(\.name) }

    func arguments(_ name: String) -> [String: JSONValue]? {
        calls.first { $0.name == name }?.arguments
    }
}
