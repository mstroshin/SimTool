@testable import SimToolCore
import XCTest

final class SimulatorTouchScreenTests: XCTestCase {
    // backboardd's lines from real boots (`log show --style ndjson` with
    // `SimulatorTouchScreen.logPredicate`), each message cut after the part
    // that matters.

    private let touchScreen26 = "<SimHIDVirtualService: 0x10405a2e0: identifier: 0xacefade00000007 com.apple.SimulatorHID.ScreenTouchService.PurpleMain"

    /// The boot MB-42153 was found on (iOS 26.4): the screen came up at boot,
    /// the viewer's keyboard toggle started dtuhidd before any touch, and every
    /// touch after that answered "ok" and went nowhere.
    private var viewerKeyboardIncident: [(Int, String)] {
        [
            (41055, "Connecting service: \(touchScreen26)"),
            (41055, "digitizer attached (sender ACEFADE00000007)"),
            (41055, "SimHIDVirtualServiceManager: dtuhidd state changed to active"),
            (41055, "Disconnecting service: \(touchScreen26)"),
            (41055, "digitizer attached (sender 1042B56000003)"),
            (41055, "SimHIDVirtualServiceManager: Connecting dtuhidd-suppressed service due to IndigoHID event: \(touchScreen26)"),
            (41055, "Connecting service: \(touchScreen26)"),
            (41055, "digitizer attached (sender 1042B5C000007)"),
        ]
    }

    /// iOS 27 has two touch screens; the one Indigo touches is stood down the same way.
    private let deadOnIOS27: [(Int, String)] = [
        (27555, "SimHIDVirtualServiceManager: dtuhidd state changed to active"),
        (27555, "Connecting service: <SimHIDVirtualService: 0x1038664f0: identifier: 0xacefade00000008 com.apple.SimulatorHID.ScreenTouchService.895D008A-12E8-4FC9-AF97-0D6C2DC55142"),
        (27555, "digitizer attached (sender ACEFADE00000008)"),
        (27555, "digitizer attached (sender 10A86D8000003)"),
        (27555, "SimHIDVirtualServiceManager: dtuhidd state changed to inactive"),
        (27555, "digitizer attached (sender ACEFADE00000007)"),
        (27555, "Connecting service: <SimHIDVirtualService: 0x103866520: identifier: 0xacefade00000007 com.apple.SimulatorHID.ScreenTouchService.8B5A5E0E-E971-4E81-9F2B-7337C294AB5A"),
        (27555, "SimHIDVirtualServiceManager: dtuhidd state changed to active"),
        (27555, "Disconnecting service: <SimHIDVirtualService: 0x103866520: identifier: 0xacefade00000007 com.apple.SimulatorHID.ScreenTouchService.8B5A5E0E-E971-4E81-9F2B-7337C294AB5A"),
        (27555, "SimHIDVirtualServiceManager: Connecting dtuhidd-suppressed service due to IndigoHID event: <SimHIDVirtualService: 0x103866520: identifier: 0xacefade00000007 com.apple.SimulatorHID.ScreenTouchService.8B5A5E0E-E971-4E81-9F2B-7337C294AB5A"),
        (27555, "Connecting service: <SimHIDVirtualService: 0x103866520: identifier: 0xacefade00000007 com.apple.SimulatorHID.ScreenTouchService.8B5A5E0E-E971-4E81-9F2B-7337C294AB5A"),
        (27555, "digitizer attached (sender 10B37D0000009)"),
    ]

    /// dtuhidd up from boot: the screen first comes up with the first touch, and stays.
    private var dtuhiddFromBoot: [(Int, String)] {
        [
            (81625, "SimHIDVirtualServiceManager: dtuhidd state changed to active"),
            (81625, "digitizer attached (sender 10C1590000003)"),
            (81625, "SimHIDVirtualServiceManager: Connecting dtuhidd-suppressed service due to IndigoHID event: \(touchScreen26)"),
            (81625, "Connecting service: \(touchScreen26)"),
            (81625, "digitizer attached (sender ACEFADE00000007)"),
        ]
    }

    /// The screen touched before dtuhidd started is not stood down.
    private var touchedBeforeDtuhidd: [(Int, String)] {
        [
            (35073, "SimHIDVirtualServiceManager: dtuhidd state changed to inactive"),
            (35073, "Connecting service: \(touchScreen26)"),
            (35073, "digitizer attached (sender ACEFADE00000007)"),
            (35073, "SimHIDVirtualServiceManager: dtuhidd state changed to active"),
            (35073, "digitizer attached (sender 101EBC2000007)"),
        ]
    }

    private func ndjson(_ entries: [(Int, String)]) -> Data {
        let lines = entries.map { process, message in
            String(data: try! JSONSerialization.data(withJSONObject: ["processID": process, "eventMessage": message]), encoding: .utf8)!
        }
        // `log show` closes with a summary object that is not an event.
        return Data((lines + [#"{"count":\#(entries.count),"finished":1}"#]).joined(separator: "\n").utf8)
    }

    // MARK: - reading the log

    func testTheScreenStoodDownBeforeAnyTouchIsCutOff() {
        XCTAssertTrue(SimulatorTouchScreen.isCutOff(log: ndjson(viewerKeyboardIncident)))
        XCTAssertTrue(SimulatorTouchScreen.isCutOff(log: ndjson(deadOnIOS27)))
    }

    func testScreensThatWereNeverStoodDownTakeTouches() {
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: ndjson(dtuhiddFromBoot)))
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: ndjson(touchedBeforeDtuhidd)))
    }

    func testAScreenAttachedAgainTakesTouchesAgain() {
        let reattached = viewerKeyboardIncident + [(41055, "digitizer attached (sender ACEFADE00000007)")]
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: ndjson(reattached)))
    }

    func testOnlyTheLastBackboarddCounts() {
        let restarted = viewerKeyboardIncident + [(52000, "SimHIDVirtualServiceManager: dtuhidd state changed to active")]
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: ndjson(restarted)))
    }

    func testANonTouchServiceStoodDownIsNoReason() {
        let keyboard = [
            (1, "SimHIDVirtualServiceManager: dtuhidd state changed to active"),
            (1, "Disconnecting service: <SimHIDVirtualService: 0x1: identifier: 0xacefade00000003 com.apple.SimulatorHID.ExternalKeyboardService"),
        ]
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: ndjson(keyboard)))
    }

    func testALogWithNothingToSayTakesTouches() {
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: Data()))
        XCTAssertFalse(SimulatorTouchScreen.isCutOff(log: Data("Filtering the log data using \"process == backboardd\"\nnot json\n".utf8)))
    }

    func testTheRefusalSaysHowToGetTouchesBack() {
        let message = SimulatorTouchScreen.cutOffMessage(deviceUDID: "2C2B8676-F0F5-46F1-93DD-89C8A237D0C3")
        XCTAssertTrue(message.contains("not reaching simulator 2C2B8676-F0F5-46F1-93DD-89C8A237D0C3"))
        XCTAssertTrue(message.contains("dtuhidd"))
        XCTAssertTrue(message.contains("xcrun simctl shutdown 2C2B8676-F0F5-46F1-93DD-89C8A237D0C3 && xcrun simctl boot 2C2B8676-F0F5-46F1-93DD-89C8A237D0C3"))
    }

    // MARK: - one check per boot

    private final class LogReads: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [Date] = []
        var count: Int { lock.withLock { reads.count } }
        func note(_ since: Date) { lock.withLock { reads.append(since) } }
    }

    private func check(log: Data?, reads: LogReads, directory: URL) -> TouchScreenCheck {
        TouchScreenCheck(directory: directory, readLog: { _, since in
            reads.note(since)
            return log
        })
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("touch-screens-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testAVerdictIsReadOncePerBootAndRememberedAcrossProcesses() async throws {
        let directory = try temporaryDirectory()
        let reads = LogReads()
        let boot = Date(timeIntervalSince1970: 1_792_532_602)
        let dead = check(log: ndjson(viewerKeyboardIncident), reads: reads, directory: directory)

        let first = await dead.isCutOff(deviceUDID: "UDID", bootedAt: boot)
        XCTAssertTrue(first)
        XCTAssertEqual(reads.count, 1)

        // Another process, same boot: no log read, the same answer.
        let later = check(log: ndjson(dtuhiddFromBoot), reads: reads, directory: directory)
        let again = await later.isCutOff(deviceUDID: "UDID", bootedAt: boot)
        XCTAssertTrue(again)
        XCTAssertEqual(reads.count, 1)

        // A reboot is a new screen.
        let rebooted = await later.isCutOff(deviceUDID: "UDID", bootedAt: boot.addingTimeInterval(600))
        XCTAssertFalse(rebooted)
        XCTAssertEqual(reads.count, 2)
    }

    func testAnUnreadableLogLetsTouchesThroughAndIsAskedAgain() async throws {
        let directory = try temporaryDirectory()
        let reads = LogReads()
        let boot = Date(timeIntervalSince1970: 1_792_532_602)
        let unreadable = check(log: nil, reads: reads, directory: directory)

        let first = await unreadable.isCutOff(deviceUDID: "UDID", bootedAt: boot)
        let second = await unreadable.isCutOff(deviceUDID: "UDID", bootedAt: boot)
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(reads.count, 2)
    }

    func testTheLogIsReadFromTheBootOn() {
        XCTAssertEqual(TouchScreenCheck.logTime(Date(timeIntervalSince1970: 0)).count, "yyyy-MM-dd HH:mm:ss".count)
        XCTAssertTrue(SimulatorTouchScreen.logPredicate.contains("ScreenTouchService"))
        XCTAssertTrue(SimulatorTouchScreen.logPredicate.contains("digitizer attached"))
    }

    // MARK: - helper

    func testTheHelperSaysWhenTheDeviceBooted() {
        XCTAssertEqual(SimulatorDirectInputCommand.boot.line, "boot")
        XCTAssertEqual(SimulatorDirectInputCommand.bootedAt(fromAnswer: "ok 1792532602.000"), Date(timeIntervalSince1970: 1_792_532_602))
        XCTAssertNil(SimulatorDirectInputCommand.bootedAt(fromAnswer: "err"))
        XCTAssertNil(SimulatorDirectInputCommand.bootedAt(fromAnswer: "ok"))
        XCTAssertNil(SimulatorDirectInputCommand.bootedAt(fromAnswer: "ok 0"))
    }

    func testTheHelperClaimsTheTouchScreenAsItStarts() throws {
        let source = SimulatorDirectInputHelperSource.source
        XCTAssertTrue(source.contains("!strcmp(name, \"boot\")"))
        XCTAssertTrue(source.contains("lastBootedAt"))
        // An unassigned Consumer usage to the digitizer: the one claim that
        // reaches the screen on both iOS 26.4 and 27 and does nothing visible.
        XCTAssertTrue(source.contains("buildUsage(0x32, 12, 0, 2)"))
        let opening = try XCTUnwrap(source.range(of: "static BOOL openClient("))
        let claim = try XCTUnwrap(source.range(of: "claimTouchScreen();", range: opening.upperBound..<source.endIndex))
        let opened = try XCTUnwrap(source.range(of: "return YES;", range: opening.upperBound..<source.endIndex))
        XCTAssertLessThan(claim.lowerBound, opened.lowerBound, "the claim goes out before the helper takes its first command")
    }
}
