@testable import SimToolCore
import XCTest

final class SimulatorFoldTests: XCTestCase {
    // MARK: - poses

    func testNamedPosesAndAnglesParse() throws {
        XCTAssertEqual(try SimulatorPose(parsing: "closed"), .closed)
        XCTAssertEqual(try SimulatorPose(parsing: "Cover"), .closed)
        XCTAssertEqual(try SimulatorPose(parsing: "book").hingeDegrees, 130)
        XCTAssertEqual(try SimulatorPose(parsing: "flat"), .open)
        XCTAssertEqual(try SimulatorPose(parsing: "90°"), SimulatorPose(hingeDegrees: 90))
        XCTAssertEqual(try SimulatorPose(parsing: "180"), .open, "an angle that is a pose is that pose")
        XCTAssertEqual(try SimulatorPose(parsing: "130.0").name, "book")
        XCTAssertThrowsError(try SimulatorPose(parsing: "tent"))
        XCTAssertThrowsError(try SimulatorPose(parsing: "190"))
        XCTAssertThrowsError(try SimulatorPose(parsing: "-5"))
        XCTAssertEqual(SimulatorPose(hingeDegrees: 92.5).description, "92.5°")
    }

    func testAPoseCallsForThePanelSpringBoardSettlesOn() {
        XCTAssertEqual(SimulatorPose.closed.expectedPanel, "cover")
        XCTAssertEqual(SimulatorPose.book.expectedPanel, "inner")
        XCTAssertEqual(SimulatorPose.open.expectedPanel, "inner")
        XCTAssertNil(SimulatorPose(hingeDegrees: 90).expectedPanel, "between, the panel that was lit may stay")
    }

    func testTheHelperSweepsTheHinge() {
        XCTAssertEqual(SimulatorFoldCommand.sweep(from: 133.8, to: 180, milliseconds: 800).line, "sweep 133.80 180.00 800")
        XCTAssertEqual(SimulatorFoldCommand.angle(90).line, "angle 90.00")
    }

    // MARK: - reading the fold back

    /// Xcode 27.2, iPhone Duo: a sweep from closed to book, then to open —
    /// which SpringBoard does not mention (book → open is no new posture to
    /// it) while locationd logs every angle.
    private let closedToBookToOpen = """
    2026-10-20 23:08:29.883 Df SpringBoard[20244:31dccdd] [com.apple.SpringBoard:DevicePose] DCMPose: 0.0° (0.00 fold:0.00): fullyClosed [device:Pu]
    2026-10-20 23:08:29.974 Df SpringBoard[20244:31dccdd] [com.apple.SpringBoard:DisplayContentMode] COMPLETED:     .cover:pri .inner:off | 0.0° (0.00 fold:0.00): fullyClosed [device:Pu]
    2026-10-20 23:09:17.801 I  locationd[48765:3212fd6] [com.apple.locationd.Motion:DeviceState] Angle value set to: 8.012345
    2026-10-20 23:09:17.844 Df SpringBoard[20244:31dccdd] [com.apple.SpringBoard:DevicePose] DCMPose: 5.4° (0.03 fold:0.00): closed+toOpen (progress:0.00 toSwap:0.03 fromSwap:0.00) [device:Pu]
    2026-10-20 23:09:18.580 I  locationd[48765:3212fd6] [com.apple.locationd.Motion:DeviceState] Angle value set to: 130.000000
    2026-10-20 23:09:19.831 Df SpringBoard[20244:31dccdd] [com.apple.SpringBoard:DisplayContentMode] COMPLETED:     .cover:aux .inner:pri | 133.8° (0.74 fold:1.00): partiallyOpen+foldAvoidance [device:Pu]
    2026-10-20 23:13:36.400 I  locationd[48765:3212fd6] [com.apple.locationd.Motion:DeviceState] Angle value set to: 151.250000
    2026-10-20 23:13:37.100 I  locationd[48765:3212fd6] [com.apple.locationd.Motion:DeviceState] Angle value set to: 180.000000
    """

    func testTheFoldIsReadFromLocationdsAnglesAndSpringBoardsPanels() throws {
        let lines = closedToBookToOpen.split(separator: "\n").map(String.init)
        let closed = try XCTUnwrap(SimulatorFoldState.latest(inLog: lines.prefix(2).joined(separator: "\n")))
        XCTAssertEqual(closed, SimulatorFoldState(hingeDegrees: 0, posture: "fullyClosed", panel: "cover"))
        XCTAssertEqual(closed.pose, "closed")

        let book = try XCTUnwrap(SimulatorFoldState.latest(inLog: lines.prefix(6).joined(separator: "\n")))
        XCTAssertEqual(book.hingeDegrees, 130, "locationd's hinge wins over SpringBoard's filtered 133.8")
        XCTAssertEqual(book.panel, "inner")
        XCTAssertEqual(book.posture, "partiallyOpen+foldAvoidance")
        XCTAssertEqual(book.pose, "book")
        XCTAssertEqual(book.summary, "book · 130°, inner panel lit")

        let open = try XCTUnwrap(SimulatorFoldState.latest(inLog: closedToBookToOpen))
        XCTAssertEqual(open.hingeDegrees, 180)
        XCTAssertEqual(open.pose, "open")
        XCTAssertNil(open.posture, "SpringBoard's book posture is stale once the hinge moved on")
        XCTAssertEqual(open.panel, "inner")
    }

    func testOtherLinesSayNothingAboutTheFold() {
        XCTAssertNil(SimulatorFoldState().reading("2026-10-20 23:13:36.328 Df SpringBoard[1:2] [com.apple.SpringBoard:IdleTimer] updateIdleTimerForReason:\"Hinge Motion\""))
        XCTAssertNil(SimulatorFoldState().reading("Angle value set to: 400"))
        XCTAssertNil(SimulatorFoldState.latest(inLog: ""))
        // `log stream`'s first line quotes the predicate, markers and all.
        XCTAssertNil(SimulatorFoldState().reading(#"Filtering the log data using "(process == "SpringBoard" AND ((category == "DevicePose" AND composedMessage CONTAINS "DCMPose:") OR (category == "DisplayContentMode" AND composedMessage CONTAINS "COMPLETED:")))""#))
    }

    func testAFoldEncodesItsPoseForTheViewer() throws {
        let json = String(decoding: try JSONEncoder().encode(SimulatorFoldState(hingeDegrees: 180, panel: "inner")), as: UTF8.self)
        XCTAssertTrue(json.contains("\"pose\":\"open\""), json)
        XCTAssertFalse(json.contains("postureDegrees"))
        let decoded = try JSONDecoder().decode(SimulatorFoldState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.hingeDegrees, 180)
        XCTAssertEqual(SimulatorFoldState(hingeDegrees: 92.6, panel: "inner").summary, "92.6°, inner panel lit")
    }

    // MARK: - waiting for the device

    private let duo = SimulatorDisplayLayout(displays: [
        SimulatorDisplay(id: "primary", screenID: 1, role: "cover", width: 1398, height: 2034, scale: 3),
        SimulatorDisplay(id: "primary-1", screenID: 3, role: "inner", width: 2007, height: 2853, scale: 3),
    ])

    func testAFoldSettlesOnceThePanelAndTheHingeAgree() async throws {
        let readings = FoldReadings([
            ("primary", SimulatorFoldState(hingeDegrees: 40)),
            ("primary-1", SimulatorFoldState(hingeDegrees: 130, panel: "inner")),
        ])
        let state = try await SimulatorFoldClient.settle(at: .book, layout: duo, readback: { await readings.next() })
        XCTAssertEqual(state.pose, "book")
        XCTAssertEqual(state.panel, "inner")
    }

    func testAFoldTheDeviceNeverTakesIsAnError() async {
        let readings = FoldReadings([("primary", SimulatorFoldState(hingeDegrees: 130, posture: "closed"))])
        do {
            _ = try await SimulatorFoldClient.settle(at: .book, layout: duo, timeout: 0.6, readback: { await readings.next() })
            XCTFail("the cover still lit is not book")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not fold to book"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("the cover panel lit"), error.localizedDescription)
        }
    }

    func testOnlyAFoldableTakesAPose() async {
        let phone = SimulatorDisplayLayout(displays: [SimulatorDisplay(id: "primary", screenID: 1, width: 1206, height: 2622, scale: 3)])
        do {
            _ = try await SimulatorFoldClient().fold(to: .open, from: 0, layout: phone, deviceUDID: "U", readback: { (nil, nil) })
            XCTFail("a phone does not fold")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not fold"))
        }
    }

    /// Built on the user's machine for the simulator; a mistake would surface only there.
    func testTheFoldHelperSourceCompilesForTheSimulator() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fold.m")
        try SimulatorFoldHelperSource.source.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "iphonesimulator", "clang", "-fsyntax-only", "-mios-simulator-version-min=15.0", "-fobjc-arc", file.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, said)
    }
}

private actor FoldReadings {
    private var readings: [(String?, SimulatorFoldState?)]
    init(_ readings: [(String?, SimulatorFoldState?)]) { self.readings = readings }
    func next() -> (active: String?, fold: SimulatorFoldState?) {
        let reading = readings.count > 1 ? readings.removeFirst() : readings[0]
        return (reading.0, reading.1)
    }
}
