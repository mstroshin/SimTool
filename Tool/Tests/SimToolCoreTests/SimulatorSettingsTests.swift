import Foundation
import SimToolNetworkLogger
@testable import SimToolCore
import XCTest

// The simulator's settings: how a request is checked before anything runs,
// and how what simctl and notifyutil print is read back.
final class SimulatorSettingsTests: XCTestCase {
    func testDebugOptionsGoByNameOrTheWordsPeopleUse() {
        XCTAssertEqual(SimulatorDebugOption(parsing: "color-blended"), .colorBlended)
        XCTAssertEqual(SimulatorDebugOption(parsing: "Blended"), .colorBlended)
        XCTAssertEqual(SimulatorDebugOption(parsing: "color_off-screen_rendered".replacingOccurrences(of: "_", with: "-")), .colorOffscreen)
        XCTAssertEqual(SimulatorDebugOption(parsing: "slow"), .slowAnimations)
        XCTAssertNil(SimulatorDebugOption(parsing: "flash"))
    }

    // The numbers are QuartzCore's: what the guest's render server takes.
    func testEachColourIsTheRenderServersOptionAndSlowAnimationsAreUIKits() {
        XCTAssertEqual(SimulatorDebugOption.colorCopies.renderServerOption, 1)
        XCTAssertEqual(SimulatorDebugOption.colorBlended.renderServerOption, 2)
        XCTAssertEqual(SimulatorDebugOption.colorMisaligned.renderServerOption, 14)
        XCTAssertEqual(SimulatorDebugOption.colorOffscreen.renderServerOption, 17)
        XCTAssertNil(SimulatorDebugOption.slowAnimations.renderServerOption)
    }

    func testTheHelperReadsAndSetsADebugOption() {
        XCTAssertEqual(SimulatorDirectInputCommand.renderDebugOption(2).line, "cadebug 2")
        XCTAssertEqual(SimulatorDirectInputCommand.renderDebugOption(17, enabled: true).line, "cadebug 17 1")
        XCTAssertEqual(SimulatorDirectInputCommand.renderDebugOption(17, enabled: false).line, "cadebug 17 0")
        XCTAssertEqual(SimulatorDirectInputCommand.flag(fromAnswer: "ok 1"), true)
        XCTAssertEqual(SimulatorDirectInputCommand.flag(fromAnswer: "ok 0"), false)
        XCTAssertNil(SimulatorDirectInputCommand.flag(fromAnswer: "ok"))
        XCTAssertNil(SimulatorDirectInputCommand.flag(fromAnswer: "err this CoreSimulator has no render debug options"))
        XCTAssertEqual(SimulatorDirectInputCommand.memoryWarning.line, "memwarn")
    }

    func testTextSizesTakeSimctlsNamesShortFormsAndSteps() {
        XCTAssertEqual(SimulatorContentSize.parse("accessibility-large"), "accessibility-large")
        XCTAssertEqual(SimulatorContentSize.parse("AX3"), "accessibility-extra-large")
        XCTAssertEqual(SimulatorContentSize.parse("xxxl"), "extra-extra-extra-large")
        XCTAssertEqual(SimulatorContentSize.parse("default"), "large")
        XCTAssertEqual(SimulatorContentSize.parse("bigger"), "increment")
        XCTAssertEqual(SimulatorContentSize.parse("smaller"), "decrement")
        XCTAssertNil(SimulatorContentSize.parse("huge"))
        XCTAssertEqual(SimulatorContentSize.short("accessibility-extra-extra-extra-large"), "AX5")
        XCTAssertEqual(SimulatorContentSize.short("large"), "L")
    }

    func testBiometricActionsTakeTheirNamesAndPlainWords() {
        XCTAssertEqual(SimulatorBiometricAction(parsing: "match"), .match)
        XCTAssertEqual(SimulatorBiometricAction(parsing: "non-matching"), .nomatch)
        XCTAssertEqual(SimulatorBiometricAction(parsing: "enrolled"), .enroll)
        XCTAssertNil(SimulatorBiometricAction(parsing: "maybe"))
        XCTAssertEqual(SimulatorBiometryKind.face.notification(matching: true), "com.apple.BiometricKit_Sim.pearl.match")
        XCTAssertEqual(SimulatorBiometryKind.touch.notification(matching: false), "com.apple.BiometricKit_Sim.fingerTouch.nomatch")
    }

    // A device type says which sensor it has in its capabilities.
    func testTheSensorComesFromTheDeviceTypesCapabilities() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Phone-\(UUID().uuidString).simdevicetype")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        for (capabilities, kind) in [(["pearl-id": true, "touch-id": false], SimulatorBiometryKind.face), (["pearl-id": false, "touch-id": true], .touch)] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["capabilities": capabilities], format: .xml, options: 0)
            try data.write(to: resources.appendingPathComponent("capabilities.plist"))
            XCTAssertEqual(SimulatorBiometryKind.of(deviceTypeBundle: bundle.path), kind)
        }
        let none = try PropertyListSerialization.data(fromPropertyList: ["capabilities": ["pearl-id": false]], format: .xml, options: 0)
        try none.write(to: resources.appendingPathComponent("capabilities.plist"))
        XCTAssertNil(SimulatorBiometryKind.of(deviceTypeBundle: bundle.path))
    }

    // What `simctl status_bar list` prints, as Xcode 27.2's simctl prints it.
    func testTheStatusBarListIsReadBackWithItsNumbersNamed() {
        let bar = SimulatorStatusBar.parse(list: """
        Current Status Bar Overrides:
        =============================
        Time: 09:41
        DataNetworkType: 11
        WiFi Mode: 3, WiFi Bars: 3
        Cell Mode: 3, Cell Bars: 4
        Operator Name: Carrier
        Battery State: 0, Battery Level: 20, Not Charging: 0
        """)
        XCTAssertEqual(bar, SimulatorStatusBar(
            time: "09:41", dataNetwork: "5g", wifiMode: "active", wifiBars: 3, cellularMode: "active", cellularBars: 4,
            operatorName: "Carrier", batteryState: "discharging", batteryLevel: 20
        ))
        XCTAssertEqual(bar.summary, "09:41 · 5g · Wi-Fi 3/3 · cell 4/4 · Carrier · 20% discharging")
        XCTAssertEqual(SimulatorStatusBar.parse(list: "DataNetworkType: 1").dataNetwork, "wifi")
        XCTAssertEqual(SimulatorStatusBar.parse(list: "DataNetworkType: 0").dataNetwork, "hide")
        let none = SimulatorStatusBar.parse(list: "Current Status Bar Overrides:\n=============================\n")
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(none.summary, "no overrides")
    }

    func testAStatusBarOverrideNamesAWrongValueBeforeSimctlRuns() throws {
        XCTAssertEqual(
            try SimulatorStatusBar(time: "9:41", dataNetwork: "WIFI", batteryLevel: 100).overrideArguments(),
            ["--time", "9:41", "--dataNetwork", "wifi", "--batteryLevel", "100"]
        )
        XCTAssertThrowsError(try SimulatorStatusBar(batteryLevel: 101).overrideArguments()) { error in
            XCTAssertTrue((error as? SimToolError)?.message.contains("battery level must be 0…100") == true)
        }
        XCTAssertThrowsError(try SimulatorStatusBar(wifiMode: "on").overrideArguments())
        XCTAssertThrowsError(try SimulatorStatusBar().overrideArguments())
        // A cellular field would make simctl turn the data network to 5G.
        XCTAssertNil(SimulatorStatusBar.clean.cellularMode)
        XCTAssertNil(SimulatorStatusBar.clean.cellularBars)
    }

    func testALocationIsAPointOrARouteInSimctlsForm() throws {
        XCTAssertEqual(SimulatorCoordinate(parsing: " 37.3349, -122.0090 "), SimulatorCoordinate(latitude: 37.3349, longitude: -122.009))
        XCTAssertNil(SimulatorCoordinate(parsing: "37.3349"))
        XCTAssertNil(SimulatorCoordinate(parsing: "91,0"))
        XCTAssertEqual(SimulatorCoordinate(latitude: 37.3349, longitude: -122.009).text, "37.3349,-122.009")

        let point = SimulatorLocation(waypoints: [SimulatorCoordinate(latitude: 1.5, longitude: 2)])
        XCTAssertEqual(try point.arguments(deviceUDID: "U"), ["simctl", "location", "U", "set", "1.5,2"])
        let route = SimulatorLocation(waypoints: [SimulatorCoordinate(latitude: 1, longitude: 2), SimulatorCoordinate(latitude: 3, longitude: 4)], speed: 15, interval: 2)
        XCTAssertEqual(try route.arguments(deviceUDID: "U"), ["simctl", "location", "U", "start", "--speed=15.0", "--interval=2.0", "1,2", "3,4"])
        XCTAssertEqual(route.summary, "route of 2 points at 15 m/s")
        XCTAssertThrowsError(try SimulatorLocation(waypoints: route.waypoints, speed: 0).arguments(deviceUDID: "U"))
    }

    func testNotifyutilsStatesAreReadPerKey() {
        XCTAssertEqual(SimulatorNotify.parse("com.apple.BiometricKit.enrollmentChanged 1\ncom.apple.UIKit.SimulatorSlowMotionAnimationState 0\n"), [
            "com.apple.BiometricKit.enrollmentChanged": 1,
            "com.apple.UIKit.SimulatorSlowMotionAnimationState": 0,
        ])
    }

    // A request that cannot be right fails before it reaches the device.
    func testABadRequestFailsBeforeAnythingRuns() async {
        for (control, expected) in [
            (DeviceControlPayload(action: "appearance", value: "blue"), "Appearance takes light or dark"),
            (DeviceControlPayload(action: "content-size", value: "huge"), "Text size takes one of"),
            (DeviceControlPayload(action: "increase-contrast"), "takes enabled"),
            (DeviceControlPayload(action: "debug", option: "flash", enabled: true), "Debug takes an option"),
            (DeviceControlPayload(action: "debug", option: "blended"), "takes enabled"),
            (DeviceControlPayload(action: "biometrics", value: "maybe"), "Biometrics takes enroll"),
            (DeviceControlPayload(action: "push", payload: .object(["aps": .object([:])])), "needs the app's bundle id"),
            (DeviceControlPayload(action: "push", bundleId: "com.example", payload: .object(["alert": .string("hi")])), "`aps` dictionary"),
            (DeviceControlPayload(action: "status-bar"), "needs statusBar fields"),
            (DeviceControlPayload(action: "location"), "needs waypoints"),
            (DeviceControlPayload(action: "teleport"), "Unknown device action teleport"),
        ] {
            do {
                _ = try await SimulatorDeviceControl.perform(control, deviceUDID: "NO-SUCH-DEVICE")
                XCTFail("\(control.action) should fail")
            } catch {
                XCTAssertTrue(((error as? SimToolError)?.message ?? "").contains(expected), "\(control.action): \(error)")
            }
        }
    }
}
