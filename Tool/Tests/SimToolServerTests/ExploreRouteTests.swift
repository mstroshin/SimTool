import Darwin
import Foundation
import XCTest
import SimToolCore
import SimToolServer

final class ExploreRouteTests: XCTestCase {
    // The canvas saves a drag and reads the arrangement back from `status` on
    // the next open — the round trip the Картограф tab depends on.
    func testLayoutRoundTripsThroughStatus() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("explore-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, baseURL) = try startServer(sessionsRoot: root.appendingPathComponent("test-sessions"))
        defer { server.stop() }

        let saved = try await postJSON(
            ExploreLayout.self,
            url: baseURL.appendingPathComponent("api/v1/explore/layout"),
            body: try JSON.encoder.encode(ExploreLayoutRequest(positions: ["s-a": ExploreNodePosition(x: 64, y: 128)]))
        )
        XCTAssertEqual(saved.positions["s-a"], ExploreNodePosition(x: 64, y: 128))

        let status = try await getJSON(ExploreStatusPayload.self, url: baseURL.appendingPathComponent("api/v1/explore/status"))
        XCTAssertEqual(status.layout?.positions["s-a"], ExploreNodePosition(x: 64, y: 128))
    }

    // A budget nobody means used to take the process with it: the multiplication
    // into seconds trapped, and the stream, the mocks and every test watching
    // them died with the crawl. The answer is a refusal — and a server that is
    // still answering afterwards.
    func testStartRefusesAnAbsurdBudgetAndSurvivesIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, baseURL) = try startServer(sessionsRoot: root.appendingPathComponent("test-sessions"))
        defer { server.stop() }

        for body in [
            #"{"budgetMinutes": 1000000000000000000}"#,
            #"{"budgetMinutes": 0}"#,
            #"{"maxScreens": -1}"#,
            #"{"maxSteps": 9223372036854775807}"#,
        ] {
            let refusal = try await post(baseURL.appendingPathComponent("api/v1/explore/start"), body: body)
            XCTAssertEqual(refusal.status, 400, "\(body) is the caller's to fix: \(refusal.body)")
        }

        let health = try await get(baseURL.appendingPathComponent("health"))
        XCTAssertEqual(health.status, 200, "the server is still there")
    }

    // A body that would not decode was replaced by the defaults, so a typo in
    // `maxSteps` quietly started a 200-step crawl of the wrong shape.
    func testStartRefusesABodyThatIsNotJSON() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, baseURL) = try startServer(sessionsRoot: root.appendingPathComponent("test-sessions"))
        defer { server.stop() }

        let refusal = try await post(baseURL.appendingPathComponent("api/v1/explore/start"), body: "{maxSteps: 60,,}")
        XCTAssertEqual(refusal.status, 400)
    }

    // And the typo the refusal above was written for, which walked straight
    // past it: JSON that parses perfectly and names a field this build has
    // never heard of. `Codable` skips what it does not recognise, so every one
    // of these decoded as an empty request — a 200-step crawl with none of the
    // limits the caller wrote down, and not a word about it.
    func testStartRefusesAFieldItDoesNotKnow() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, baseURL) = try startServer(sessionsRoot: root.appendingPathComponent("test-sessions"))
        defer { server.stop() }

        for body in [#"{"maxStep": 60}"#, #"{"max_steps": 60}"#, #"{"maxSteps": 60, "budget": 3}"#] {
            let refusal = try await post(baseURL.appendingPathComponent("api/v1/explore/start"), body: body)
            XCTAssertEqual(refusal.status, 400, "\(body) names a field nothing reads: \(refusal.body)")
            XCTAssertTrue(refusal.body.contains("maxSteps"), "the answer lists what this build does read")
        }

        // The fields it does know still mean what they say, and an empty body
        // still means "crawl with the defaults" — the refusal is about spelling,
        // not about being asked for less.
        let misconfigured = try await post(baseURL.appendingPathComponent("api/v1/explore/start"), body: #"{"maxSteps": 60}"#)
        XCTAssertEqual(misconfigured.status, 500, "no app to explore, which is a different complaint")
    }

    // Three different answers used to arrive as 409: an unknown profile name is
    // a request to fix, a server with no app to explore is ours to answer for,
    // and only a run already in flight is a conflict.
    func testStartTellsABadRequestFromAConflictAndFromAMisconfiguredServer() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (noApp, noAppURL) = try startServer(sessionsRoot: root.appendingPathComponent("test-sessions"))
        defer { noApp.stop() }

        let misconfigured = try await post(noAppURL.appendingPathComponent("api/v1/explore/start"), body: "{}")
        XCTAssertEqual(misconfigured.status, 500, misconfigured.body)

        let (server, baseURL) = try startServer(
            sessionsRoot: root.appendingPathComponent("with-app"),
            app: "com.example.app"
        )
        defer { server.stop() }
        let unknownProfile = try await post(
            baseURL.appendingPathComponent("api/v1/explore/start"),
            body: #"{"profile": "nope"}"#
        )
        XCTAssertEqual(unknownProfile.status, 400, unknownProfile.body)
        XCTAssertTrue(unknownProfile.body.contains("nope"))

        // And the conflict proper: one run at a time.
        let started = try await post(baseURL.appendingPathComponent("api/v1/explore/start"), body: #"{"maxSteps": 1}"#)
        XCTAssertEqual(started.status, 200, started.body)
        let second = try await post(baseURL.appendingPathComponent("api/v1/explore/start"), body: "{}")
        XCTAssertEqual(second.status, 409, second.body)
        _ = try await post(baseURL.appendingPathComponent("api/v1/explore/stop"), body: "")
        // `stop` only asks: the crawl notices at its next await and still has a
        // closing write to make. Leaving without waiting let the run outlive
        // the test, writing into a store directory the next case was already
        // deleting — and the failure landed on whichever test ran next.
        await waitUntilIdle(baseURL)
    }

    // The node id becomes a file name under the store root, so it is spelled
    // from letters, digits, dashes and underscores or it is not served at all.
    func testShotRouteServesAKnownNodeAndNothingThatWalksOut() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("explore")
        try FileManager.default.createDirectory(
            at: store.appendingPathComponent("shots"),
            withIntermediateDirectories: true
        )
        try Data(minimalGraphJSON.utf8).write(to: store.appendingPathComponent("graph.json"))
        try Data("not really a png".utf8).write(to: store.appendingPathComponent("shots/s-a.png"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
        let (server, baseURL) = try startServer(sessionsRoot: root.appendingPathComponent("test-sessions"))
        defer { server.stop() }

        let known = try await get(shotURL(baseURL, node: "s-a"))
        XCTAssertEqual(known.status, 200, known.body)

        for payload in [
            "../secret.txt",
            "../../etc/passwd",
            "..",
            ".",
            "s-a/../../secret.txt",
            "%2e%2e%2fsecret.txt",
            "shots/s-a",
            "",
        ] {
            let refused = try await get(shotURL(baseURL, node: payload))
            XCTAssertEqual(refused.status, 404, "node=\(payload) must not be served")
        }
    }


    // --- helpers (mirror MockRouteTests) ---
    private func startServer(
        sessionsRoot: URL,
        app: String? = nil,
        profiles: [LaunchProfile] = []
    ) throws -> (StreamServer, URL) {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(
            host: "127.0.0.1",
            port: port,
            device: device,
            captureEnabled: false,
            defaultLogApp: app,
            testSessionsRoot: sessionsRoot,
            profiles: profiles
        ))
        try server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    /// Waits for the run the server reports to finish. Bounded: a crawl that
    /// will not stop is a failure of its own, not a reason to hang the suite.
    private func waitUntilIdle(_ baseURL: URL, timeout: TimeInterval = 10) async {
        let url = baseURL.appendingPathComponent("api/v1/explore/status")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let status = try? await getJSON(ExploreStatusPayload.self, url: url), status.running else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("the crawl was still running \(timeout)s after /stop")
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("explore-route-\(UUID().uuidString)")
    }

    /// A map with one screen, written the way the crawl writes it — enough for
    /// the shot route to have a node to serve.
    private var minimalGraphJSON: String {
        """
        {
          "schemaVersion": 2,
          "run": {
            "id": "2026-08-19T10-00-00",
            "app": "com.example.app",
            "device": "iPhone 16 Pro",
            "startedAt": "2026-08-19T10:00:00Z"
          },
          "stats": { "screens": 1, "transitions": 0, "steps": 0, "relaunches": 0 },
          "nodes": [
            {
              "id": "s-a",
              "title": "MainScreen",
              "fingerprint": "s-a",
              "key": "MainScreen",
              "screenshot": "shots/s-a.png",
              "depth": 0,
              "visits": 1,
              "actionsTotal": 1,
              "actionsTried": 1,
              "firstSeenAt": "2026-08-19T10:00:00Z"
            }
          ],
          "edges": []
        }
        """
    }

    private func shotURL(_ baseURL: URL, node: String) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/explore/shot"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "node", value: node)]
        return components.url!
    }

    private func get(_ url: URL) async throws -> (status: Int, body: String) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    private func post(_ url: URL, body: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }


    private func getJSON<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSON.decoder.decode(T.self, from: data)
    }

    private func postJSON<T: Decodable>(_ type: T.Type, url: URL, body: Data) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSON.decoder.decode(T.self, from: data)
    }

    private func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
