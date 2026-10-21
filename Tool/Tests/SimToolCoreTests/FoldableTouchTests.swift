@testable import SimToolCore
import XCTest

/// Touches of an iPhone Duo: each panel its own target, points of the picture
/// turned onto the framebuffer, and the touch screen checked per panel.
final class FoldableTouchTests: XCTestCase {
    private let cover = SimulatorDisplay(id: "primary", screenID: 1, role: "cover", width: 1398, height: 2034, scale: 3)
    private let inner = SimulatorDisplay(id: "primary-1", screenID: 3, role: "inner", width: 2007, height: 2853, scale: 3)
    private var duo: SimulatorDisplayLayout { SimulatorDisplayLayout(deviceType: FoldableReadiness.duoDeviceType, displays: [cover, inner]) }

    // MARK: - which way a touch goes

    func testTheInnerPanelTakesIndigoAndTheCoverGoesThroughDtuhidd() {
        XCTAssertTrue(duo.takesIndigoTouches(inner))
        XCTAssertFalse(duo.takesIndigoTouches(cover), "an Indigo event into the cover's stood-down screen aborts backboardd")
        let phone = SimulatorDisplayLayout(displays: [SimulatorDisplay(id: "primary", screenID: 1, width: 1206, height: 2622, scale: 3)])
        XCTAssertTrue(phone.takesIndigoTouches(phone.displays[0]))
    }

    func testARouteAimsTheHelperAtThePanel() {
        let innerRoute = SimulatorTouchRoute(target: 0x4000_0003, display: inner, rotation: 90, uniqueID: "0C89A8AA-FCF7-4C74-9347-CD63A1AC5101")
        XCTAssertEqual(innerRoute.targetLine, "target 1073741827 2007 2853 0")
        XCTAssertEqual(innerRoute.checkedScreen, "0C89A8AA-FCF7-4C74-9347-CD63A1AC5101")
        let coverRoute = SimulatorTouchRoute(target: 0x4000_0001, display: cover, rotation: 0, uniqueID: "C7C9D008-E722-46A3-B076-9764AF9425F8", overDTUHID: true)
        XCTAssertEqual(coverRoute.targetLine, "target 1 1398 2034 1", "through dtuhidd a panel is named by its screen number")
        XCTAssertNil(coverRoute.checkedScreen, "dtuhidd's touch screen is its own: SimulatorHID's verdict does not apply")
    }

    func testARoutedPathAndLiveEventLandOnTheFramebuffer() {
        let route = SimulatorTouchRoute(target: 0x4000_0003, display: inner, rotation: 90)
        let path = TouchPath(samples: [
            .init(phase: .down, time: 0, point: TouchRatio(x: 0.25, y: 0.5)),
            .init(phase: .up, time: 0.06, point: TouchRatio(x: 0.25, y: 0.5)),
        ])
        XCTAssertEqual(route.framebuffer(path).helperLine, "path d,0,0.50000,0.75000 u,60,0.50000,0.75000")
        let pinch = LiveTouchEvent(phase: .move, first: TouchRatio(x: 0.1, y: 0.2), second: TouchRatio(x: 0.9, y: 0.8), display: "primary-1")
        XCTAssertEqual(route.framebuffer(pinch).helperLine, "move2 0.20000 0.90000 0.80000 0.10000")
        XCTAssertEqual(route.framebuffer(pinch).display, "primary-1")
    }

    // MARK: - the helper's protocol

    func testTheHelperNamesTheDeviceTypeAndItsBundle() throws {
        XCTAssertEqual(SimulatorDirectInputCommand.deviceType.line, "type")
        let answer = try XCTUnwrap(SimulatorDirectInputCommand.deviceType(
            fromAnswer: "ok com.apple.CoreSimulator.SimDeviceType.iPhone-Duo /Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype"
        ))
        XCTAssertEqual(answer.identifier, FoldableReadiness.duoDeviceType)
        XCTAssertEqual(answer.bundlePath, "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype")
        XCTAssertNil(SimulatorDirectInputCommand.deviceType(fromAnswer: "err"))
        XCTAssertNil(SimulatorDirectInputCommand.deviceType(fromAnswer: "ok com.apple.CoreSimulator.SimDeviceType.iPhone-17"))
    }

    func testTheHelperNeverClaimsAPanelsOwnTarget() throws {
        let source = SimulatorDirectInputHelperSource.source
        // The claim stays on the shared slot; HIDArbitrary to 0x4000000N aborts backboardd.
        XCTAssertEqual(source.components(separatedBy: "buildUsage(").count - 1, 2, "the claim and the old toolchains' button, nothing else")
        XCTAssertTrue(source.contains("buildUsage(0x32, 12, 0, 2)"))
        XCTAssertTrue(source.contains("buildUsage(0x32, page, usage"))
        // Touches use the selected target, and the cover's go to dtuhidd by screen number.
        XCTAssertTrue(source.contains("buildMouse(&p, count == 2 ? &q : NULL, touchTarget"))
        XCTAssertTrue(source.contains("\"IndigoDigitizerEvent\""))
        XCTAssertTrue(source.contains("xpc_dictionary_set_uint64(payload, \"target\", dtuhidScreen)"))
        XCTAssertTrue(source.contains("!strcmp(name, \"target\")"))
        XCTAssertTrue(source.contains("!strcmp(name, \"type\")"))
    }

    /// The helper is compiled on the user's machine the first time it is
    /// needed; a mistake in it would surface only there.
    func testTheHelperSourceCompiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("helper.m")
        try SimulatorDirectInputHelperSource.source.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang", "-fsyntax-only", "-fobjc-arc", file.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, said)
    }

    // MARK: - the touch screen of each panel

    private func ndjson(_ entries: [(Int, String)]) -> Data {
        Data(entries.map { process, message in
            String(data: try! JSONSerialization.data(withJSONObject: ["processID": process, "eventMessage": message]), encoding: .utf8)!
        }.joined(separator: "\n").utf8)
    }

    private let innerService = "<SimHIDVirtualService: 0x103c6bb70: identifier: 0xacefade00000008 com.apple.SimulatorHID.ScreenTouchService.0C89A8AA-FCF7-4C74-9347-CD63A1AC5101, state: disconnected"
    private let resizableService = "<SimHIDVirtualService: 0x105c6a430: identifier: 0xacefade00000009 com.apple.SimulatorHID.ScreenTouchService.D3DB736B-A687-4306-AC34-B886E59F956D, state: connected"

    /// A Duo boot on Xcode 27.2: dtuhidd up from the start, the inner panel's
    /// screen revived by its first Indigo touch.
    private var duoBoot: [(Int, String)] {
        [
            (48762, "SimHIDVirtualServiceManager: dtuhidd state changed to active"),
            (48762, "Connecting service: \(resizableService)"),
            (48762, "digitizer attached (sender ACEFADE00000009) service:<BKIOHIDService: 0x105cffb60; senderID: 0xACEFADE00000009>"),
            (48762, "SimHIDVirtualServiceManager: Connecting dtuhidd-suppressed service due to IndigoHID event: \(innerService)"),
            (48762, "digitizer attached (sender ACEFADE00000008) service:<BKIOHIDService: 0x110977de0; senderID: 0xACEFADE00000008>"),
            (48762, "Connecting service: \(innerService)"),
        ]
    }

    func testADuoWhoseInnerPanelCameBackTakesTouches() {
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: ndjson(duoBoot), screen: "0C89A8AA-FCF7-4C74-9347-CD63A1AC5101"))
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: ndjson(duoBoot)))
    }

    func testAPanelStoodDownSaysNothingAboutTheOther() {
        let resizableDown = duoBoot + [(48762, "Disconnecting service: \(resizableService)")]
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: ndjson(resizableDown), screen: "0C89A8AA-FCF7-4C74-9347-CD63A1AC5101"))
        XCTAssertTrue(SimulatorTouchScreen.isCutOff(log: ndjson(resizableDown), screen: "d3db736b-a687-4306-ac34-b886e59f956d"))
        XCTAssertTrue(SimulatorTouchScreen.isCutOff(log: ndjson(resizableDown)), "without a screen any stood-down one counts, as on a phone")
        let innerDown = duoBoot + [(48762, "Disconnecting service: \(innerService)")]
        XCTAssertTrue(SimulatorTouchScreen.isCutOff(log: ndjson(innerDown), screen: "0C89A8AA-FCF7-4C74-9347-CD63A1AC5101"))
    }

    func testEachPanelsVerdictIsRememberedOnItsOwn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("touch-screens-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ndjson(duoBoot + [(48762, "Disconnecting service: \(resizableService)")])
        let check = TouchScreenCheck(directory: directory, readLog: { _, _ in log })
        let boot = Date(timeIntervalSince1970: 1_792_532_602)
        let innerCut = await check.isCutOff(deviceUDID: "UDID", bootedAt: boot, screen: "0C89A8AA-FCF7-4C74-9347-CD63A1AC5101")
        let resizableCut = await check.isCutOff(deviceUDID: "UDID", bootedAt: boot, screen: "D3DB736B-A687-4306-AC34-B886E59F956D")
        XCTAssertFalse(innerCut)
        XCTAssertTrue(resizableCut)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["UDID-0C89A8AA-FCF7-4C74-9347-CD63A1AC5101.json", "UDID-D3DB736B-A687-4306-AC34-B886E59F956D.json"])
    }
}
