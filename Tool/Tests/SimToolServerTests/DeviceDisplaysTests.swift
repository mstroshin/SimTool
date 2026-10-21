import XCTest
import SimToolCore
@testable import SimToolServer

final class DeviceDisplaysTests: XCTestCase {
    let duo = SimulatorDisplayLayout(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", displays: [
        SimulatorDisplay(id: "primary", screenID: 1, role: "cover", width: 1398, height: 2034, scale: 3, cornerRadii: [8, 59, 59, 8]),
        SimulatorDisplay(id: "primary-1", screenID: 3, role: "inner", width: 2007, height: 2853, scale: 3, cornerRadii: [55, 55, 55, 55]),
    ])

    func testAFoldableNamesTheLitScreenForScreenshotsAndRecordings() throws {
        let displays = DeviceDisplays()
        displays.set(layout: duo)
        XCTAssertEqual(displays.activeDisplay?.id, "primary", "before the first reading: the cover, where a foldable rests")
        XCTAssertTrue(displays.set(state: SimulatorDisplayState(active: "primary-1", rotations: ["primary-1": 90])))
        XCTAssertFalse(displays.set(state: SimulatorDisplayState(active: "primary-1", rotations: ["primary-1": 90])), "the same state is no change")
        XCTAssertEqual(displays.activeDisplay?.id, "primary-1")
        XCTAssertEqual(try displays.display(named: nil)?.id, "primary-1")
        XCTAssertEqual(try displays.display(named: "active")?.id, "primary-1")
        XCTAssertEqual(try displays.display(named: "cover")?.id, "primary")
        XCTAssertThrowsError(try displays.display(named: "resizable"))
    }

    func testTheDeviceTopicSaysHowEachPictureReads() throws {
        let displays = DeviceDisplays()
        displays.set(layout: duo)
        displays.set(state: SimulatorDisplayState(active: "primary-1", rotations: ["primary": 0, "primary-1": 90]))
        let topic = displays.topic
        XCTAssertEqual(topic.activeDisplay, "primary-1")
        let inner = try XCTUnwrap(topic.displays.first { $0.id == "primary-1" })
        XCTAssertTrue(inner.active)
        XCTAssertEqual(inner.rotation, 90)
        XCTAssertEqual(inner.points, SimulatorScreenSize(width: 951, height: 669, scale: 3))
        XCTAssertEqual(topic.displays.first { $0.id == "primary" }?.active, false)
    }

    func testAOneScreenDeviceTakesNoDisplayName() throws {
        let displays = DeviceDisplays()
        displays.set(layout: SimulatorDisplayLayout(displays: [SimulatorDisplay(id: "primary", screenID: 1, width: 1206, height: 2622, scale: 3)]))
        XCTAssertNil(displays.activeDisplay)
        XCTAssertNil(try displays.display(named: nil))
        XCTAssertNil(try displays.display(named: "primary"))
        XCTAssertThrowsError(try displays.display(named: "inner"))
        XCTAssertEqual(displays.payloads.map(\.active), [true])
    }

    func testTheMonitorReportsAStateOnlyWhenItChangesAndKeepsItThroughAFailedRead() async {
        let readings = Readings([
            .success(SimulatorDisplayState(active: "primary")),
            .success(SimulatorDisplayState(active: "primary")),
            .failure(SimToolError("devicectl hiccup")),
            .success(SimulatorDisplayState(active: "primary-1", rotations: ["primary-1": 90])),
        ])
        let reported = Reported()
        let monitor = DisplayStateMonitor(deviceUDID: "U", layout: duo, read: { _, _ in try await readings.next() }) { reported.append($0) }
        for _ in 0..<4 { await monitor.refresh() }
        XCTAssertEqual(reported.values.map(\.active), ["primary", "primary-1"])
    }
}

private actor Readings {
    private var results: [Result<SimulatorDisplayState, Error>]
    init(_ results: [Result<SimulatorDisplayState, Error>]) { self.results = results }
    func next() throws -> SimulatorDisplayState { try results.removeFirst().get() }
}

private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [SimulatorDisplayState] = []
    func append(_ state: SimulatorDisplayState) { lock.withLock { states.append(state) } }
    var values: [SimulatorDisplayState] { lock.withLock { states } }
}

final class SimctlVideoRecorderTests: XCTestCase {
    func testAFoldablesRecordingNamesTheScreen() {
        let file = URL(fileURLWithPath: "/tmp/v.mp4")
        XCTAssertEqual(
            SimctlVideoRecorder.arguments(deviceUDID: "U", display: "primary-1", outputFile: file),
            ["simctl", "io", "U", "recordVideo", "--codec", "h264", "--display=primary-1", "--force", "/tmp/v.mp4"]
        )
        XCTAssertEqual(
            SimctlVideoRecorder.arguments(deviceUDID: "U", display: nil, outputFile: file),
            ["simctl", "io", "U", "recordVideo", "--codec", "h264", "--force", "/tmp/v.mp4"]
        )
    }

    // A recording that gets the bezel records the glass too: the corners and the Dynamic Island in black.
    func testARecordingForTheBezelIsMasked() {
        XCTAssertEqual(
            SimctlVideoRecorder.arguments(deviceUDID: "U", display: nil, outputFile: URL(fileURLWithPath: "/tmp/v.mp4"), masked: true),
            ["simctl", "io", "U", "recordVideo", "--codec", "h264", "--mask=black", "--force", "/tmp/v.mp4"]
        )
    }
}
