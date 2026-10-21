import Foundation
import XCTest
import SimToolCore
import SimToolServer

// The viewer's recording routes, without a simulator: nothing records, so
// stopping is refused and there is nothing to download.
final class RecordingRouteTests: XCTestCase {
    func testWithNothingRecordingStopIsRefusedAndThereIsNoVideo() async throws {
        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!

        let (state, stateResponse) = try await URLSession.shared.data(from: base.appendingPathComponent("api/v1/recording"))
        XCTAssertEqual((stateResponse as? HTTPURLResponse)?.statusCode, 200)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: state) as? [String: Any])
        XCTAssertNil(payload["current"], "nothing is recording")

        var stop = URLRequest(url: base.appendingPathComponent("api/v1/recording/stop"))
        stop.httpMethod = "POST"
        let (body, stopResponse) = try await URLSession.shared.data(for: stop)
        XCTAssertEqual((stopResponse as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("No recording is running"))

        let (_, video) = try await URLSession.shared.data(from: base.appendingPathComponent("api/v1/recording/rec-x/video"))
        XCTAssertEqual((video as? HTTPURLResponse)?.statusCode, 404)
    }
}
