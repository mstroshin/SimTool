import Foundation
import SimToolCore
import SimToolServer
import XCTest

// POST /api/v1/device: a change the device cannot take is refused with the
// reason, and the activity feed says it failed.
final class DeviceRouteTests: XCTestCase {
    func testABadDeviceRequestIsRefusedWithTheReasonAndShowsAsFailed() async throws {
        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        for (body, expected) in [
            (#"{"action": "appearance", "value": "blue"}"#, "Appearance takes light or dark"),
            (#"{"action": "push", "payload": {"aps": {}}}"#, "needs the app's bundle id"),
            (#"{"action": "teleport"}"#, "Unknown device action teleport"),
        ] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/device")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400, body)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(expected), "\(body) → \(String(decoding: data, as: UTF8.self))")
        }

        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/v1/activity")!)
        let feed = try JSON.decoder.decode(DeviceActivityPayload.self, from: data)
        XCTAssertEqual(feed.entries.map(\.title), ["Change appearance", "Push to the app", "Teleport"])
        XCTAssertEqual(Set(feed.entries.map(\.status)), [.failed])
        XCTAssertEqual(feed.entries.first?.kind, "appearance")
    }

    // A server without an app asks for one; an install needs the build in its body.
    func testTheAppRoutesSayWhatTheyLack() async throws {
        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        let (card, cardResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/v1/app")!)
        XCTAssertEqual((cardResponse as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(String(decoding: card, as: UTF8.self).contains("Name the app"))

        var install = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/app/install")!)
        install.httpMethod = "POST"
        let (body, installResponse) = try await URLSession.shared.data(for: install)
        XCTAssertEqual((installResponse as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("must be the .ipa"))

        let (odd, oddResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/v1/app?bundleId=com.example%27x")!)
        XCTAssertEqual((oddResponse as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(String(decoding: odd, as: UTF8.self).contains("is not a bundle identifier"))
    }
}
