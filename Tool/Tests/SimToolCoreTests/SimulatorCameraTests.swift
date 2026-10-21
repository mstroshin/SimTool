import Darwin
import Foundation
@testable import SimToolCore
import XCTest

// The camera SimTool gives the apps it launches: what a file would show, who
// has the camera, and what a launch carries.
final class SimulatorCameraTests: XCTestCase {
    private var udid = ""

    override func setUp() {
        udid = "TEST-CAMERA-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: SimulatorCamera.directory(deviceUDID: udid))
    }

    func testAFileShowsAnImageOrAVideoByItsExtension() {
        XCTAssertEqual(SimulatorCamera.sourceKind(ofFile: "code.PNG"), .image)
        XCTAssertEqual(SimulatorCamera.sourceKind(ofFile: "fixtures/card.heic"), .image)
        XCTAssertEqual(SimulatorCamera.sourceKind(ofFile: "clip.mov"), .video)
        XCTAssertEqual(SimulatorCamera.sourceKind(ofFile: "clip.mp4"), .video)
        XCTAssertNil(SimulatorCamera.sourceKind(ofFile: "notes.txt"))
        XCTAssertNil(SimulatorCamera.sourceKind(ofFile: "webcam"))
    }

    func testTheSummarySaysWhatTheCameraShows() {
        XCTAssertEqual(SimulatorCameraState(source: .none).summary, "off")
        XCTAssertEqual(SimulatorCameraState(source: .image, name: "code.png").summary, "image code.png")
        XCTAssertEqual(SimulatorCameraState(source: .video, name: "clip.mov").summary, "video clip.mov, in a loop")
        XCTAssertEqual(SimulatorCameraState(source: .video).summary, "video, in a loop")
        XCTAssertEqual(SimulatorCameraState(source: .webcam, name: "MacBook Pro Camera").summary, "the Mac's MacBook Pro Camera")
    }

    // A file the camera cannot show is refused before anything is built or copied.
    func testAFileThatIsNotAnImageOrAVideoIsRefused() async throws {
        do {
            try await SimulatorCamera.setFile(URL(fileURLWithPath: "/tmp/notes.txt"), deviceUDID: udid)
            XCTFail("a text file became the camera")
        } catch {
            XCTAssertTrue("\(error)".contains("The camera takes an image"), "\(error)")
        }
        do {
            try await SimulatorCamera.setFile(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png"), deviceUDID: udid)
            XCTFail("a missing file became the camera")
        } catch {
            XCTAssertTrue("\(error)".contains("does not exist"), "\(error)")
        }
        XCTAssertEqual(SimulatorCamera.state(deviceUDID: udid).source, .none)
    }

    // Nothing reaches an app while the camera is off and nobody asked for it dark.
    func testALaunchCarriesNothingWhileTheCameraIsOff() throws {
        try SimulatorCamera.off(deviceUDID: udid)
        let environment = ["SIMTOOL_SERVER_URL": "http://127.0.0.1:3300"]
        XCTAssertEqual(SimulatorCamera.launchEnvironment(deviceUDID: udid, merging: environment), environment)
        XCTAssertEqual(SimulatorCamera.state(deviceUDID: udid), SimulatorCameraState(source: .none))
    }

    // An app that spoke lately has the camera; one gone quiet has it while its
    // process runs — suspended in the background — and is dropped once it ended.
    // A relaunched app's predecessor, still going away, is not listed beside it.
    func testTheAppsThatHaveTheCameraAreTheLiveOnes() throws {
        let clients = SimulatorCamera.directory(deviceUDID: udid).appendingPathComponent("clients", isDirectory: true)
        try FileManager.default.createDirectory(at: clients, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_000)
        func beat(_ pid: Int, _ bundleId: String, at: Double, running: Bool = true) throws {
            let text = #"{"bundleId": "\#(bundleId)", "pid": \#(pid), "running": \#(running), "at": \#(at)}"#
            try Data(text.utf8).write(to: clients.appendingPathComponent("\(pid).json"))
        }
        try beat(10, "com.example.fresh", at: 999)
        try beat(20, "com.example.suspended", at: 900)
        try beat(30, "com.example.ended", at: 900)
        try beat(40, "com.example.reused", at: 900)
        try beat(50, "com.example.relaunched", at: 990)
        try beat(60, "com.example.relaunched", at: 999.5)
        let starts: [Int: Double] = [20: 800, 40: 950, 50: 700]
        let apps = SimulatorCamera.clients(deviceUDID: udid, now: now, startOfProcess: { starts[$0] })
        XCTAssertEqual(apps, [
            SimulatorCameraClient(bundleId: "com.example.fresh", pid: 10, running: true),
            SimulatorCameraClient(bundleId: "com.example.suspended", pid: 20, running: false),
            SimulatorCameraClient(bundleId: "com.example.relaunched", pid: 60, running: true),
        ])
        let left = try FileManager.default.contentsOfDirectory(atPath: clients.path).sorted()
        XCTAssertEqual(left, ["10.json", "20.json", "50.json", "60.json"], "an ended app's file goes, and so does one whose pid another process took")
    }

    func testAProcessStartIsReadForALiveProcessOnly() {
        let mine = SimulatorCamera.processStart(Int(getpid()))
        XCTAssertNotNil(mine)
        XCTAssertLessThanOrEqual(mine ?? .infinity, Date().timeIntervalSince1970)
        XCTAssertNil(SimulatorCamera.processStart(0))
    }

    // The webcam's frame is swapped in whole.
    func testAFrameIsWrittenWhole() throws {
        try FileManager.default.createDirectory(at: SimulatorCamera.directory(deviceUDID: udid), withIntermediateDirectories: true)
        try SimulatorCamera.writeFrame(Data([0xFF, 0xD8, 0xFF]), deviceUDID: udid)
        try SimulatorCamera.writeFrame(Data([0xFF, 0xD8, 0xFF, 0xD9]), deviceUDID: udid)
        let directory = SimulatorCamera.directory(deviceUDID: udid)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("frame.jpg")), Data([0xFF, 0xD8, 0xFF, 0xD9]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["frame.jpg"], "no temporary file is left")
    }
}
