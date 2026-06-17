import XCTest
@testable import SimToolCore
import SimToolNetworkLogger

final class SimulatorDeviceTests: XCTestCase {
    func testParseDevicesFiltersUnavailable() throws {
        let json = #"""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
              { "name": "iPhone 16", "udid": "A", "state": "Booted", "isAvailable": true },
              { "name": "iPhone 15", "udid": "B", "state": "Shutdown", "isAvailable": false }
            ]
          }
        }
        """#.data(using: .utf8)!

        let devices = try SimulatorDeviceClient.parseDevices(json)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].udid, "A")
        XCTAssertEqual(devices[0].state, "Booted")
    }

    func testSelectDeviceBootedKeywordPicksFirstBootedAvailable() throws {
        let devices = [
            SimulatorDevice(udid: "A", name: "iPhone 15", runtime: "iOS-18-0", state: "Shutdown", isAvailable: true),
            SimulatorDevice(udid: "B", name: "iPhone 16", runtime: "iOS-18-0", state: "Booted", isAvailable: true),
            SimulatorDevice(udid: "C", name: "iPhone 17", runtime: "iOS-18-0", state: "Booted", isAvailable: true),
        ]
        // The literal "booted" (any case) selects the first booted+available device.
        XCTAssertEqual(try SimulatorDeviceClient.selectDevice("booted", from: devices).udid, "B")
        XCTAssertEqual(try SimulatorDeviceClient.selectDevice("Booted", from: devices).udid, "B")
        // nil and empty keep selecting the first booted (existing behavior).
        XCTAssertEqual(try SimulatorDeviceClient.selectDevice(nil, from: devices).udid, "B")
        XCTAssertEqual(try SimulatorDeviceClient.selectDevice("", from: devices).udid, "B")
    }

    func testSelectDeviceBootedKeywordThrowsWhenNoneBooted() {
        let devices = [
            SimulatorDevice(udid: "A", name: "iPhone 15", runtime: "iOS-18-0", state: "Shutdown", isAvailable: true),
        ]
        XCTAssertThrowsError(try SimulatorDeviceClient.selectDevice("booted", from: devices))
    }

    func testSelectDeviceMatchesByUDIDAndName() throws {
        let devices = [
            SimulatorDevice(udid: "AAA-111", name: "iPhone 15", runtime: "iOS-18-0", state: "Shutdown", isAvailable: true),
            SimulatorDevice(udid: "BBB-222", name: "iPhone 16 Pro", runtime: "iOS-18-0", state: "Booted", isAvailable: true),
        ]
        XCTAssertEqual(try SimulatorDeviceClient.selectDevice("aaa-111", from: devices).udid, "AAA-111")
        XCTAssertEqual(try SimulatorDeviceClient.selectDevice("16 Pro", from: devices).udid, "BBB-222")
        XCTAssertThrowsError(try SimulatorDeviceClient.selectDevice("Pixel", from: devices))
    }

    func testParseAccessibilityTreeNormalizesNodes() throws {
        let json = #"""
        [
          {
            "AXUniqueId": "root",
            "AXLabel": "App",
            "AXValue": null,
            "role": "AXApplication",
            "role_description": "application",
            "type": "Application",
            "enabled": true,
            "frame": { "x": 0, "y": 0, "width": 390, "height": 844 },
            "children": [
              {
                "AXUniqueId": "continueButton",
                "AXLabel": "Continue",
                "role": "AXButton",
                "type": "Button",
                "enabled": true,
                "pid": 123,
                "children": []
              }
            ]
          }
        ]
        """#.data(using: .utf8)!

        let tree = try SimulatorAccessibilityClient.parseTree(json)
        XCTAssertEqual(tree.nodeCount, 2)
        XCTAssertEqual(tree.roots[0].label, "App")
        XCTAssertEqual(tree.roots[0].frame?.width, 390)
        XCTAssertEqual(tree.roots[0].children[0].accessibilityIdentifier, "continueButton")
        XCTAssertEqual(tree.roots[0].children[0].pid, 123)

        let matches = try SimulatorAccessibilityClient.findNodes(needle: "continue", in: tree)
        XCTAssertEqual(matches.matches.count, 1)
        XCTAssertEqual(matches.matches[0].path, [0, 0])
        XCTAssertEqual(matches.matches[0].node.role, "AXButton")
    }

    func testParseNetworkEvents() {
        let line = #"{"timestamp":"2026-06-06 20:00:00.000+0300","processImagePath":"\/usr\/libexec\/networkd","processID":42,"subsystem":"com.apple.network","category":"connection","messageType":"Info","eventMessage":"connected","traceID":123}"#

        let events = SimulatorNetworkClient.parseNetworkEvents(line)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].process, "networkd")
        XCTAssertEqual(events[0].processID, 42)
        XCTAssertEqual(events[0].subsystem, "com.apple.network")
        XCTAssertEqual(events[0].eventMessage, "connected")
    }

    func testAppLogPredicateMatchesSubsystemAndProcessCandidates() throws {
        let predicate = try XCTUnwrap(SimulatorLogsClient.appLogPredicate(app: "com.example.MyApp'; DROP"))

        // The embedded single quote is escaped (\'), so it cannot terminate the literal; the
        // rest of the value (`; DROP`, spaces) survives harmlessly inside the quoted string.
        XCTAssertTrue(predicate.contains("subsystem BEGINSWITH 'com.example.MyApp\\'; DROP'"))
        XCTAssertTrue(predicate.contains("process == 'com.example.MyApp\\'; DROP'"))
        XCTAssertTrue(predicate.contains("processImagePath ENDSWITH '/com.example.MyApp\\'; DROP'"))
        XCTAssertTrue(predicate.contains("process == 'MyApp\\'; DROP'"))
        XCTAssertTrue(predicate.contains("processImagePath ENDSWITH '/MyApp\\'; DROP'"))
        // No unescaped quote from the input survives to open a new clause.
        XCTAssertFalse(predicate.contains("Client'; DROP"))

        XCTAssertEqual(SimulatorLogsClient.appProcessCandidates(app: "MyApp"), ["MyApp"])
        XCTAssertEqual(SimulatorLogsClient.appProcessCandidates(app: "com.example.MyApp"), ["com.example.MyApp", "MyApp"])

        // A value made entirely of predicate metacharacters is escaped, not dropped to nil.
        let escapedInjection = try XCTUnwrap(SimulatorLogsClient.appLogPredicate(app: "';"))
        XCTAssertTrue(escapedInjection.contains("subsystem BEGINSWITH '\\';'"))
        XCTAssertFalse(escapedInjection.contains("BEGINSWITH '';"))
    }

    func testAppLogPredicatePreservesSpacesInProcessName() throws {
        XCTAssertEqual(SimulatorLogsClient.appProcessCandidates(app: "My App"), ["My App"])

        let predicate = try XCTUnwrap(SimulatorLogsClient.appLogPredicate(app: "My App"))
        XCTAssertTrue(predicate.contains("subsystem BEGINSWITH 'My App'"))
        XCTAssertTrue(predicate.contains("process == 'My App'"))
        XCTAssertTrue(predicate.contains("processImagePath ENDSWITH '/My App'"))
    }

    func testAppLogPredicateMatchesBaseSubsystemForBuildVariantBundleID() throws {
        // A Debug build ships under `com.example.MyApp.debug` but logs under base subsystem `com.example.MyApp`.
        XCTAssertEqual(
            SimulatorLogsClient.appSubsystemCandidates(app: "com.example.MyApp.debug"),
            ["com.example.MyApp.debug", "com.example.MyApp"]
        )
        let predicate = try XCTUnwrap(SimulatorLogsClient.appLogPredicate(app: "com.example.MyApp.debug"))
        XCTAssertTrue(predicate.contains("subsystem BEGINSWITH 'com.example.MyApp.debug'"))
        XCTAssertTrue(predicate.contains("subsystem BEGINSWITH 'com.example.MyApp'"))

        // Non-variant final components are not stripped.
        XCTAssertEqual(
            SimulatorLogsClient.appSubsystemCandidates(app: "com.example.MyApp"),
            ["com.example.MyApp"]
        )
        // A two-component id is not reduced to a single-component (over-broad) base.
        XCTAssertEqual(SimulatorLogsClient.appSubsystemCandidates(app: "foo.debug"), ["foo.debug"])
    }

    func testAppLogPredicateIsNilForEmptyOrWhitespaceFilter() {
        XCTAssertNil(SimulatorLogsClient.appLogPredicate(app: nil))
        XCTAssertNil(SimulatorLogsClient.appLogPredicate(app: ""))
        XCTAssertNil(SimulatorLogsClient.appLogPredicate(app: "   "))
        XCTAssertNil(SimulatorLogsClient.appLogPredicate(app: "\n\t"))
        XCTAssertEqual(SimulatorLogsClient.appProcessCandidates(app: "   "), [])
    }

    func testParseNetworkLoggerEventsSkipsInvalidLinesAndFilters() throws {
        let http = makeNetworkLoggerEvent(id: "http", timestamp: "2026-01-01T00:00:00.000Z", networkProtocol: .http)
        let grpc = makeNetworkLoggerEvent(id: "grpc", timestamp: "2026-01-01T00:00:01.000Z", networkProtocol: .grpc)
        let text = try [
            NetworkLoggerJSON.string(http),
            "not json",
            NetworkLoggerJSON.string(grpc),
        ].joined(separator: "\n")

        let payload = SimulatorNetworkLoggerClient.parseEvents(
            text,
            filter: NetworkLoggerEventFilter(networkProtocol: .grpc, limit: 1)
        )

        XCTAssertEqual(payload.eventCount, 1)
        XCTAssertEqual(payload.events[0].id, "grpc")
    }

    func testReadNetworkLoggerEventsFromFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let event = makeNetworkLoggerEvent(id: "event-1", networkProtocol: .http)
        try Data((NetworkLoggerJSON.string(event) + "\n").utf8).write(to: fileURL)

        let payload = try SimulatorNetworkLoggerClient.readEvents(fileURL: fileURL)

        XCTAssertEqual(payload.eventCount, 1)
        XCTAssertEqual(payload.events[0].id, "event-1")
    }

    func testAddressInUseDetection() {
        XCTAssertTrue(PortReclaimer.isAddressInUse(SimToolError("bindFailed(\"Address already in use\")")))
        XCTAssertTrue(PortReclaimer.isAddressInUse(SimToolError("EADDRINUSE")))
        XCTAssertFalse(PortReclaimer.isAddressInUse(SimToolError("No booted simulator found")))
    }

    func testParsePIDsDeduplicatesAndExcludesCurrentProcess() {
        let current = Int32(42)
        let pids = PortReclaimer.parsePIDs("42\n100\n100\nabc\n200\n", excluding: current)
        XCTAssertEqual(pids, [100, 200])
    }

    private func makeNetworkLoggerEvent(
        id: String,
        timestamp: String = "2026-01-01T00:00:00.000Z",
        networkProtocol: NetworkLoggerProtocol
    ) -> NetworkLoggerEvent {
        NetworkLoggerEvent(
            id: id,
            timestamp: timestamp,
            appBundleID: "com.example.app",
            networkProtocol: networkProtocol,
            durationMilliseconds: 1,
            request: NetworkLoggerRequest(method: networkProtocol == .http ? "GET" : nil, url: "https://example.test")
        )
    }

}
