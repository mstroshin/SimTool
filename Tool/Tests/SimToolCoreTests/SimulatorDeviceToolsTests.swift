import Foundation
@testable import SimToolCore
import XCTest

// Accessibility, permissions, the app card, installing a build, and turning
// the device: what is decided before anything reaches the simulator, and how
// what it reports is read back.
final class SimulatorDeviceToolsTests: XCTestCase {
    func testAccessibilitySettingsTakeTheirNamesAndValues() {
        XCTAssertEqual(SimulatorAccessibilitySetting(parsing: "reduce-motion"), .reduceMotion)
        XCTAssertEqual(SimulatorAccessibilitySetting(parsing: "VoiceOver"), .voiceOver)
        XCTAssertEqual(SimulatorAccessibilitySetting(parsing: "glass"), .liquidGlass)
        XCTAssertNil(SimulatorAccessibilitySetting(parsing: "zoom"))
        XCTAssertEqual(SimulatorAccessibilitySetting.colorFilter.value(parsing: "red-green"), "protanopia")
        XCTAssertEqual(SimulatorAccessibilitySetting.colorFilter.value(parsing: "off"), "none")
        XCTAssertNil(SimulatorAccessibilitySetting.colorFilter.value(parsing: "sepia"))
        XCTAssertEqual(SimulatorAccessibilitySetting.buttonShapes.value(parsing: "true"), "on")
        XCTAssertNil(SimulatorAccessibilitySetting.liquidGlass.value(parsing: "on"))
        let settings = SimulatorAccessibilitySettings(reduceMotion: true, colorFilter: "grayscale")
        XCTAssertEqual(settings.value(of: .reduceMotion), "on")
        XCTAssertEqual(settings.value(of: .colorFilter), "grayscale")
        XCTAssertNil(settings.value(of: .liquidGlass))
    }

    // The helper answers JSON; a runtime without Liquid Glass leaves it out.
    func testTheHelpersAnswerDecodesAsTheSettings() throws {
        let answer = #"{"reduceMotion":false,"reduceTransparency":true,"buttonShapes":false,"voiceOver":false,"colorFilter":"none"}"#
        let settings = try JSONDecoder().decode(SimulatorAccessibilitySettings.self, from: Data(answer.utf8))
        XCTAssertEqual(settings.reduceTransparency, true)
        XCTAssertNil(settings.liquidGlass)
        XCTAssertTrue(SimulatorAccessibilityHelperSource.source.contains("_AXSSetReduceMotionEnabled"))
        XCTAssertTrue(SimulatorAccessibilityHelperSource.source.contains("UIViewGlassLegibilityUpdateNotification"))
    }

    func testPermissionsAndDecisionsTakeTheirNamesAndAliases() {
        XCTAssertEqual(SimulatorPermission(parsing: "att"), .userTracking)
        XCTAssertEqual(SimulatorPermission(parsing: "push"), .notifications)
        XCTAssertEqual(SimulatorPermission(parsing: "face-id"), .faceID)
        XCTAssertNil(SimulatorPermission(parsing: "bluetooth"))
        XCTAssertEqual(SimulatorPermissionDecision(parsing: "revoke"), .deny)
        XCTAssertEqual(SimulatorPermissionDecision(parsing: "allow"), .grant)
        XCTAssertNil(SimulatorPermissionDecision(parsing: "maybe"))
        // simctl takes camera and pasteboard although its help leaves them out.
        XCTAssertTrue(SimulatorPermission.camera.simctlTakesIt)
        XCTAssertTrue(SimulatorPermission.pasteboard.simctlTakesIt)
        for permission in [SimulatorPermission.notifications, .speech, .faceID, .userTracking] {
            XCTAssertFalse(permission.simctlTakesIt, permission.rawValue)
        }
        XCTAssertEqual(SimulatorPermission.faceID.tccService, "kTCCServiceFaceID")
        XCTAssertNil(SimulatorPermission.location.tccService)
    }

    func testABundleIDGoesIntoSQLOnlyWhenItIsOne() {
        XCTAssertNoThrow(try SimulatorPermissionClient.check("com.example.app-2"))
        XCTAssertThrowsError(try SimulatorPermissionClient.check("com.example'; DROP TABLE access;--"))
        XCTAssertThrowsError(try SimulatorPermissionClient.check(""))
    }

    func testAlwaysIsLocationsAlone() async {
        do {
            _ = try await SimulatorPermissionClient.set(.camera, to: .always, bundleId: "com.example.app", deviceUDID: "NO-SUCH-DEVICE")
            XCTFail("camera takes no always")
        } catch {
            XCTAssertTrue("\(error)".contains("Only location takes always"))
        }
    }

    // A section SpringBoard never wrote is archived under its class names, and
    // reads back with the status it was given; one it wrote keeps everything
    // but the status.
    func testANotificationSectionIsWrittenAndChangedAsSpringBoardKeepsIt() throws {
        let created = try SimulatorNotificationPermission.newSection(bundleId: "com.example.app", name: "Example", authorizationStatus: 2)
        XCTAssertEqual(SimulatorNotificationPermission.authorizationStatus(inSection: created), 2)
        let archive = try XCTUnwrap(PropertyListSerialization.propertyList(from: created, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(archive["$objects"] as? [Any])
        let classNames = objects.compactMap { ($0 as? [String: Any])?["$classname"] as? String }
        XCTAssertEqual(Set(classNames), ["BBSectionInfo", "BBSectionInfoSettings"])
        XCTAssertTrue(objects.contains { $0 as? String == "com.example.app" })

        let denied = try SimulatorNotificationPermission.updated(created, authorizationStatus: 1)
        XCTAssertEqual(SimulatorNotificationPermission.authorizationStatus(inSection: denied), 1)
        let after = try XCTUnwrap((PropertyListSerialization.propertyList(from: denied, format: nil) as? [String: Any])?["$objects"] as? [Any])
        XCTAssertEqual(after.count, objects.count, "only the status changes")
        XCTAssertThrowsError(try SimulatorNotificationPermission.updated(Data("not a plist".utf8), authorizationStatus: 1))
    }

    func testTheAppCardReadsSimctlsOldStylePlist() {
        let appinfo = """
        {
            ApplicationType = User;
            Bundle = "file:///Users/me/Library/Developer/CoreSimulator/Devices/U/data/Containers/Bundle/Application/B/Probe.app/";
            CFBundleDisplayName = Probe;
            CFBundleIdentifier = "com.example.probe";
            CFBundleName = Probe;
            CFBundleShortVersionString = "1.2.3";
            CFBundleVersion = 45;
            DataContainer = "file:///Users/me/Library/Developer/CoreSimulator/Devices/U/data/Containers/Data/Application/D/";
            Path = "/Users/me/Library/Developer/CoreSimulator/Devices/U/data/Containers/Bundle/Application/B/Probe.app";
        }
        """
        let info = SimulatorAppInfoClient.parse(appinfo: Data(appinfo.utf8), bundleId: "com.example.probe")
        XCTAssertEqual(info.name, "Probe")
        XCTAssertEqual(info.version, "1.2.3")
        XCTAssertEqual(info.build, "45")
        XCTAssertEqual(info.bundlePath, "/Users/me/Library/Developer/CoreSimulator/Devices/U/data/Containers/Bundle/Application/B/Probe.app")
        XCTAssertEqual(info.dataContainer, "/Users/me/Library/Developer/CoreSimulator/Devices/U/data/Containers/Data/Application/D")
        XCTAssertEqual(SimulatorAppInfoClient.pid(inLaunchctlList: "PID\tStatus\tLabel\n15817\t0\tUIKitApplication:com.example.probe[0223][rb-legacy]\n-\t0\tcom.apple.x\n", bundleId: "com.example.probe"), 15817)
        XCTAssertNil(SimulatorAppInfoClient.pid(inLaunchctlList: "15817\t0\tUIKitApplication:com.example.probe2[0223]\n", bundleId: "com.example.probe"))
    }

    // An .ipa is a zip, a dropped .app arrives as a tar; anything else is refused.
    func testABuildIsKnownByItsFirstBytesAndItsAppFound() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Payload/Probe.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("a.ipa")
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0]).write(to: zip)
        XCTAssertEqual(try SimulatorAppInstaller.kind(of: zip), "zip")
        var tar = Data(count: 512)
        tar.replaceSubrange(257..<262, with: Data("ustar".utf8))
        let tarFile = directory.appendingPathComponent("a.tar")
        try tar.write(to: tarFile)
        XCTAssertEqual(try SimulatorAppInstaller.kind(of: tarFile), "tar")
        let text = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        XCTAssertThrowsError(try SimulatorAppInstaller.kind(of: text))
        XCTAssertEqual(SimulatorAppInstaller.findApp(in: directory)?.lastPathComponent, "Probe.app")
    }

    func testOrientationsTurnAQuarterAtATime() {
        XCTAssertEqual(SimulatorOrientation.portrait.turned(clockwise: false), .landscapeLeft)
        XCTAssertEqual(SimulatorOrientation.portrait.turned(clockwise: true), .landscapeRight)
        XCTAssertEqual(SimulatorOrientation.landscapeRight.turned(clockwise: true), .portraitUpsideDown)
        XCTAssertEqual(SimulatorOrientation(parsing: "landscape"), .landscapeLeft)
        XCTAssertEqual(SimulatorOrientation(parsing: "portrait upside down"), .portraitUpsideDown)
        XCTAssertNil(SimulatorOrientation(parsing: "sideways"))
        XCTAssertEqual(SimulatorOrientation.landscapeRight.deviceOrientation, 4)
        XCTAssertEqual(SimulatorDirectInputCommand.orientation(3).line, "orient 3")
    }

    // A device nothing turned since it booted reads `unknown`: the last upright one counts.
    func testCoreDevicesOrientationIsRead() {
        let turned = #"{"result":{"orientation":{"currentDeviceOrientation":"landscapeRight","currentDeviceNonFlatOrientation":"landscapeRight"}}}"#
        XCTAssertEqual(SimulatorOrientation.parse(devicectl: Data(turned.utf8)), .landscapeRight)
        let fresh = #"{"result":{"orientation":{"currentDeviceOrientation":"unknown","currentDeviceNonFlatOrientation":"portrait"}}}"#
        XCTAssertEqual(SimulatorOrientation.parse(devicectl: Data(fresh.utf8)), .portrait)
        XCTAssertNil(SimulatorOrientation.parse(devicectl: Data("{}".utf8)))
    }

    // CoreDevice says a phone's screen is primary, not active; it is lit all the same.
    func testAPhonesOneScreenIsLitAndTurned() throws {
        let layout = SimulatorDisplayLayout(displays: [SimulatorDisplay(id: "primary", screenID: 1, width: 1206, height: 2622, scale: 3)])
        let output = #"{"result":{"displays":[{"displayId":1,"currentOrientation":"rot90","primary":true}]}}"#
        let state = try XCTUnwrap(SimulatorDisplayState.parse(devicectl: Data(output.utf8), layout: layout))
        XCTAssertEqual(state.active, "primary")
        XCTAssertEqual(state.rotation(of: "primary"), 90)
        XCTAssertEqual(layout.displays[0].points(rotation: 90), SimulatorScreenSize(width: 874, height: 402, scale: 3))
    }

    func testTheNewActionsFailBeforeTheyReachTheDevice() async {
        for (control, expected) in [
            (DeviceControlPayload(action: "accessibility", option: "zoom", value: "on"), "Accessibility takes an option"),
            (DeviceControlPayload(action: "accessibility", option: "voiceover"), "takes enabled"),
            (DeviceControlPayload(action: "permission", option: "bluetooth", value: "grant"), "A permission takes an option"),
            (DeviceControlPayload(action: "permission", option: "camera", value: "maybe"), "takes value: grant, deny or reset"),
            (DeviceControlPayload(action: "permission", option: "camera", value: "grant"), "needs the app's bundle id"),
            (DeviceControlPayload(action: "keychain", value: "wipe"), "Keychain takes value"),
            (DeviceControlPayload(action: "keychain", value: "add-root-cert"), "needs certificate"),
        ] {
            do {
                _ = try await SimulatorDeviceControl.perform(control, deviceUDID: "NO-SUCH-DEVICE")
                XCTFail("\(control.action) should fail")
            } catch {
                XCTAssertTrue(((error as? SimToolError)?.message ?? "").contains(expected), "\(control): \(error)")
            }
        }
    }
}
