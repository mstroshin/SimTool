import XCTest
@testable import SimToolCore

final class SimulatorDisplaysTests: XCTestCase {
    /// The `displays` of the iPhone Duo device type (Xcode 27.2): the cover,
    /// TV-out, the inner panel, CarPlay and Device Hub's resizable scene.
    static let duoCapabilities = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>capabilities</key><dict><key>displays</key><array>
      <dict><key>deviceName</key><string>primary</string><key>displayType</key><string>integrated</string>
        <key>hasDigitizer</key><true/><key>chromeIdentifier</key><string>com.apple.dt.devicekit.chrome.phone15</string>
        <key>screenID</key><integer>1</integer><key>width</key><integer>1398</integer><key>height</key><integer>2034</integer>
        <key>scale</key><integer>3</integer><key>nativeRotation</key><integer>0</integer>
        <key>cornerRadiusUL</key><integer>8</integer><key>cornerRadiusUR</key><integer>59</integer>
        <key>cornerRadiusLR</key><integer>59</integer><key>cornerRadiusLL</key><integer>8</integer></dict>
      <dict><key>deviceName</key><string>external-0</string><key>displayType</key><string>tvOut</string>
        <key>hasDigitizer</key><false/><key>screenID</key><integer>2</integer><key>width</key><integer>720</integer><key>height</key><integer>480</integer></dict>
      <dict><key>deviceName</key><string>primary-1</string><key>displayType</key><string>integrated</string>
        <key>hasDigitizer</key><true/><key>chromeIdentifier</key><string>com.apple.dt.devicekit.chrome.phone14</string>
        <key>screenID</key><integer>3</integer><key>width</key><integer>2007</integer><key>height</key><integer>2853</integer>
        <key>scale</key><integer>3</integer><key>nativeRotation</key><integer>270</integer>
        <key>cornerRadiusUL</key><integer>55</integer><key>cornerRadiusUR</key><integer>55</integer>
        <key>cornerRadiusLR</key><integer>55</integer><key>cornerRadiusLL</key><integer>55</integer></dict>
      <dict><key>deviceName</key><string>wireless0</string><key>displayType</key><string>carPlay</string>
        <key>hasDigitizer</key><false/><key>screenID</key><integer>4</integer><key>width</key><integer>720</integer><key>height</key><integer>480</integer></dict>
      <dict><key>deviceName</key><string>resizable</string><key>displayType</key><string>scene</string>
        <key>hasDigitizer</key><true/><key>screenID</key><integer>5</integer><key>width</key><integer>7680</integer><key>height</key><integer>4320</integer>
        <key>scale</key><integer>3</integer></dict>
    </array></dict></dict></plist>
    """.utf8)

    static let phoneCapabilities = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict><key>capabilities</key><dict><key>displays</key><array>
      <dict><key>deviceName</key><string>primary</string><key>displayType</key><string>integrated</string>
        <key>hasDigitizer</key><true/><key>chromeIdentifier</key><string>com.apple.dt.devicekit.chrome.phone12</string>
        <key>screenID</key><integer>1</integer><key>width</key><integer>1206</integer><key>height</key><integer>2622</integer>
        <key>scale</key><integer>3</integer></dict>
    </array></dict></dict></plist>
    """.utf8)

    /// `devicectl device info displays --json-output -` on an open Duo, trimmed.
    static let devicectlOpen = Data("""
    {"info":{"outcome":"success"},"result":{"displays":[
      {"active":false,"currentOrientation":"rot0","displayId":1,"primary":true,"uniqueId":"C7C9D008-E722-46A3-B076-9764AF9425F8","type":{"integrated":{}}},
      {"active":true,"currentOrientation":"rot90","displayId":3,"primary":false,"uniqueId":"0C89A8AA-FCF7-4C74-9347-CD63A1AC5101","type":{"integrated":{}}}
    ],"orientation":{"currentDeviceOrientation":"portrait"}}}
    """.utf8)

    var duo: SimulatorDisplayLayout { SimulatorDisplayLayout.parse(capabilities: Self.duoCapabilities, deviceType: FoldableReadiness.duoDeviceType) }

    func testTheDuoHasTwoScreensAndTheSmallerIsTheCover() {
        let layout = duo
        XCTAssertTrue(layout.isFoldable)
        XCTAssertEqual(layout.displays.map(\.id), ["primary", "primary-1"], "TV-out, CarPlay and the resizable scene are not screens of the device")
        XCTAssertEqual(layout.displays.map(\.role), ["cover", "inner"])
        XCTAssertEqual(layout.displays.map(\.screenID), [1, 3])
        XCTAssertEqual(layout.displays[0].cornerRadii, [8, 59, 59, 8])
        XCTAssertEqual(layout.displays[1].scale, 3)
    }

    func testEachDuoPanelHasItsOwnTouchTargetAndAPhoneKeepsTheSharedOne() throws {
        let layout = duo
        XCTAssertEqual(layout.touchTarget(of: layout.displays[0]), 0x4000_0001)
        XCTAssertEqual(layout.touchTarget(of: layout.displays[1]), 0x4000_0003)
        let phone = SimulatorDisplayLayout.parse(capabilities: Self.phoneCapabilities)
        XCTAssertFalse(phone.isFoldable)
        XCTAssertEqual(phone.touchTarget(of: try XCTUnwrap(phone.displays.first)), 0x32)
        XCTAssertNil(phone.displays.first?.role)
    }

    func testAScreenIsFoundBySimctlNameRoleOrNumber() {
        let layout = duo
        XCTAssertEqual(layout.display(named: "primary-1")?.id, "primary-1")
        XCTAssertEqual(layout.display(named: "Inner")?.id, "primary-1")
        XCTAssertEqual(layout.display(named: "cover")?.id, "primary")
        XCTAssertEqual(layout.display(named: "3")?.id, "primary-1")
        XCTAssertNil(layout.display(named: "resizable"))
        XCTAssertNil(layout.display(named: ""))
    }

    func testTheInnerPanelReadsLandscapeWhenItsPictureIsTurned() {
        let inner = duo.displays[1]
        XCTAssertEqual(inner.points(rotation: 0), SimulatorScreenSize(width: 669, height: 951, scale: 3))
        XCTAssertEqual(inner.points(rotation: 90), SimulatorScreenSize(width: 951, height: 669, scale: 3))
        let cover = duo.displays[0]
        XCTAssertEqual(cover.points(rotation: 0), SimulatorScreenSize(width: 466, height: 678, scale: 3))
        // The cover's tight hinge-side corners follow the picture round.
        XCTAssertEqual(cover.cornerRadii(rotation: 90), [8, 8, 59, 59])
        XCTAssertEqual(cover.cornerRadii(rotation: 180), [59, 8, 8, 59])
    }

    func testAPointOfATurnedPictureLandsWhereTheFramebufferHasIt() {
        // Measured on Xcode 27.2: Settings → Accessibility on the open inner
        // panel sits at 17 % across and 50 % down of the landscape picture,
        // and Indigo touches it at (0.496, 0.832) of the portrait framebuffer.
        let raw = SimulatorDisplayRotation.framebufferRatio(TouchRatio(x: 0.168, y: 0.496), rotation: 90)
        XCTAssertEqual(raw.x, 0.496, accuracy: 0.0001)
        XCTAssertEqual(raw.y, 0.832, accuracy: 0.0001)
        let point = TouchRatio(x: 0.25, y: 0.1)
        XCTAssertEqual(SimulatorDisplayRotation.framebufferRatio(point, rotation: 0), point)
        XCTAssertEqual(SimulatorDisplayRotation.framebufferRatio(point, rotation: 180), TouchRatio(x: 0.75, y: 0.9))
        XCTAssertEqual(SimulatorDisplayRotation.framebufferRatio(point, rotation: 270), TouchRatio(x: 0.9, y: 0.25))
        XCTAssertEqual(SimulatorDisplayRotation.framebufferRatio(point, rotation: -90), TouchRatio(x: 0.9, y: 0.25))
    }

    func testDevicectlNamesTheLitScreenAndEachPicturesTurn() throws {
        let state = try XCTUnwrap(SimulatorDisplayState.parse(devicectl: Self.devicectlOpen, layout: duo))
        XCTAssertEqual(state.active, "primary-1")
        XCTAssertEqual(state.rotations, ["primary": 0, "primary-1": 90])
        XCTAssertEqual(state.uniqueIDs["primary-1"], "0C89A8AA-FCF7-4C74-9347-CD63A1AC5101")
        XCTAssertEqual(state.rotation(of: "primary-1"), 90)
    }

    func testDevicectlWithNoLitScreenOrAnErrorIsNoState() {
        let dark = Data(#"{"result":{"displays":[{"active":false,"displayId":1},{"active":false,"displayId":3}]}}"#.utf8)
        XCTAssertNil(SimulatorDisplayState.parse(devicectl: dark, layout: duo))
        let failed = Data(#"{"error":{"code":1000,"domain":"com.apple.dt.CoreDeviceError"}}"#.utf8)
        XCTAssertNil(SimulatorDisplayState.parse(devicectl: failed, layout: duo))
    }

    func testTheDeviceTypeBundleIsFoundInSimctlsList() {
        let list = Data("""
        {"devicetypes":[
          {"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","bundlePath":"/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17 Pro.simdevicetype"},
          {"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo","bundlePath":"/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype"}
        ]}
        """.utf8)
        XCTAssertEqual(
            SimulatorDisplayLayout.bundlePath(of: FoldableReadiness.duoDeviceType, inDeviceTypes: list),
            "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype"
        )
        XCTAssertNil(SimulatorDisplayLayout.bundlePath(of: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro", inDeviceTypes: list))
    }

    func testSimctlsDeviceListCarriesTheDeviceType() throws {
        let json = Data("""
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4":[
          {"name":"SimTool-Duo","udid":"0E81E54F","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}
        ]}}
        """.utf8)
        let device = try XCTUnwrap(try SimulatorDeviceClient.parseDevices(json).first)
        XCTAssertEqual(device.deviceTypeIdentifier, FoldableReadiness.duoDeviceType)
        XCTAssertEqual(device.runtime, "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4")
    }

    func testAScreenshotOfOneScreenNamesIt() {
        XCTAssertEqual(
            SimulatorScreenshotClient.arguments(deviceUDID: "U", display: "primary-1", file: "/tmp/s.png"),
            ["simctl", "io", "U", "screenshot", "--type=png", "--display=primary-1", "/tmp/s.png"]
        )
        XCTAssertEqual(
            SimulatorScreenshotClient.arguments(deviceUDID: "U", display: nil, file: "/tmp/s.png"),
            ["simctl", "io", "U", "screenshot", "--type=png", "/tmp/s.png"]
        )
    }
}

final class FoldableReadinessTests: XCTestCase {
    func testOnlyTheDeviceSpecificRuntimeRunsADuo() {
        let runtimes = Data("""
        {"runtimes":[
          {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2","name":"iOS 27.2","isAvailable":true,
           "supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"}]},
          {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4","name":"iOS 27.2","isAvailable":true,
           "supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}]},
          {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-3-iPhone19-4","isAvailable":false,
           "supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}]}
        ]}
        """.utf8)
        XCTAssertEqual(
            FoldableReadiness.runtimes(supporting: FoldableReadiness.duoDeviceType, inRuntimes: runtimes),
            ["iOS 27.2 (com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4)"]
        )
        XCTAssertEqual(FoldableReadiness.runtimes(supporting: FoldableReadiness.duoDeviceType, inRuntimes: Data("{}".utf8)), [])
    }

    func testDeviceHubsHoldOnInputReadsFromTheGuestFlag() {
        XCTAssertEqual(FoldableReadiness.isInputShadowed(notifyutil: "com.apple.coredevice.dtuhidd.active 1\n"), true)
        XCTAssertEqual(FoldableReadiness.isInputShadowed(notifyutil: "com.apple.coredevice.dtuhidd.active 0"), false)
        XCTAssertNil(FoldableReadiness.isInputShadowed(notifyutil: ""))
    }
}

final class Duo3DModelTests: XCTestCase {
    private let duo = SimulatorDisplayLayout(displays: [
        SimulatorDisplay(id: "primary", screenID: 1, role: "cover", width: 1398, height: 2034, scale: 3),
        SimulatorDisplay(id: "primary-1", screenID: 3, role: "inner", width: 2007, height: 2853, scale: 3),
    ], productClass: "V68")

    /// A stand-in for an Xcode: `Contents/Developer` beside `Contents/SharedFrameworks`.
    private func xcode(withModel model: String?) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Xcode-\(UUID().uuidString).app/Contents")
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let developer = root.appendingPathComponent("Developer")
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        let resources = root.appendingPathComponent("SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if let model { try Data("usdz".utf8).write(to: resources.appendingPathComponent(model)) }
        return developer.path
    }

    func testTheModelIsFoundInTheSelectedXcodeByProductClass() throws {
        let developer = try xcode(withModel: "V68.usdz")
        let located = Duo3DModel.locate(layout: duo, developerDir: developer)
        XCTAssertEqual(located.url?.lastPathComponent, "V68.usdz")
        XCTAssertNil(located.reason)
    }

    func testWithoutAModelThePreviewSaysWhy() throws {
        let developer = try xcode(withModel: nil)
        let missing = Duo3DModel.locate(layout: duo, developerDir: developer)
        XCTAssertNil(missing.url)
        XCTAssertTrue(missing.reason?.contains("has no V68.usdz device model") == true, missing.reason ?? "")
        let phone = SimulatorDisplayLayout(displays: [SimulatorDisplay(id: "primary", screenID: 1, width: 1206, height: 2622, scale: 3)])
        XCTAssertEqual(Duo3DModel.locate(layout: phone, developerDir: developer).reason, "only a foldable device has a 3D preview")
        var unnamed = duo
        unnamed.productClass = nil
        XCTAssertTrue(Duo3DModel.locate(layout: unnamed, developerDir: developer).reason?.contains("no product class") == true)
    }

    func testTheDeviceTypeBundleNamesItsProductClass() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("Duo-\(UUID().uuidString).simdevicetype")
        addTeardownBlock { try? FileManager.default.removeItem(at: bundle) }
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try SimulatorDisplaysTests.duoCapabilities.write(to: resources.appendingPathComponent("capabilities.plist"))
        let profile = try PropertyListSerialization.data(fromPropertyList: ["productClass": "V68", "modelIdentifier": "iPhone19,4"], format: .xml, options: 0)
        try profile.write(to: resources.appendingPathComponent("profile.plist"))
        let layout = try XCTUnwrap(SimulatorDisplayLayout.load(bundlePath: bundle.path, deviceType: FoldableReadiness.duoDeviceType))
        XCTAssertEqual(layout.productClass, "V68")
        XCTAssertEqual(layout.bundlePath, bundle.path)
        XCTAssertTrue(layout.isFoldable)
    }
}
