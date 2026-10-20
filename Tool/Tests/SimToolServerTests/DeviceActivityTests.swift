import Darwin
import Foundation
import SimToolCore
import SimToolNetworkLogger
@testable import SimToolServer
import XCTest

// The activity feed: what was done to the device and by whom, as a reader
// polling `since` its last revision sees it.
final class DeviceActivityLogTests: XCTestCase {
    func testAnEntryIsHandedOutAgainEachTimeItChanges() {
        let log = DeviceActivityLog()
        let tap = log.begin(actor: .agent, via: "cli", kind: "tap", title: "Tap “General”")
        let first = log.query(since: nil)
        XCTAssertEqual(first.entries.map(\.status), [.running])

        log.update(id: tap.id) { $0.gesture = DeviceActivityGesture(from: TouchPoint(x: 1, y: 2), to: TouchPoint(x: 1, y: 2), press: 0.06, duration: 0.06) }
        let moved = log.query(since: first.revision)
        XCTAssertEqual(moved.entries.map(\.id), [tap.id])
        XCTAssertNotNil(moved.entries.first?.gesture)

        log.finish(id: tap.id, error: "No element matching label \"General\"")
        let done = log.query(since: moved.revision)
        XCTAssertEqual(done.entries.first?.status, .failed)
        XCTAssertEqual(done.entries.first?.error, "No element matching label \"General\"")
        XCTAssertNotNil(done.entries.first?.endedAt)
        XCTAssertTrue(log.query(since: done.revision).entries.isEmpty, "nothing changed since")
    }

    func testOnlyTheNewestEntriesAreKeptAndAskedFor() {
        let log = DeviceActivityLog(capacity: 3)
        for index in 1...5 { log.record(actor: .agent, via: "api", kind: "tap", title: "Tap \(index)") }
        XCTAssertEqual(log.query(since: nil).entries.map(\.title), ["Tap 3", "Tap 4", "Tap 5"])
        XCTAssertEqual(log.query(since: nil, limit: 2).entries.map(\.title), ["Tap 4", "Tap 5"])
    }

    // A viewer that outlived its server asks from a revision the new one never reached.
    func testARevisionAheadOfTheLogReadsAsAFreshStart() {
        let log = DeviceActivityLog()
        log.record(actor: .test, via: "api", kind: "step", title: "✓ 1/2 tap “General”")
        XCTAssertEqual(log.query(since: 57).entries.count, 1)
    }

    func testAClientReportOpensAndThenFinishesItsEntry() throws {
        let log = DeviceActivityLog()
        let opened = try log.apply(DeviceActivityReport(via: "cli", kind: "scroll", title: "Scroll up 300 pt"))
        XCTAssertEqual(opened.actor, .agent, "a report names no actor: it is an agent")
        XCTAssertEqual(opened.status, .running)
        let closed = try log.apply(DeviceActivityReport(id: opened.id, status: .done))
        XCTAssertEqual(closed.status, .done)
        XCTAssertEqual(closed.title, "Scroll up 300 pt", "finishing keeps what the report said")
        let failed = try log.apply(DeviceActivityReport(title: "Paste an image", status: .failed))
        XCTAssertEqual(failed.error, "failed")
        XCTAssertThrowsError(try log.apply(DeviceActivityReport(kind: "tap")), "a report without words")
        XCTAssertThrowsError(try log.apply(DeviceActivityReport(id: 999, status: .done)), "an id this server never handed out")
    }
}

final class DeviceActivityRouteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-activity-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheCLIReportsWhatItDidAndTheFeedShowsIt() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }
        let gesture = DeviceActivityGesture(from: TouchPoint(x: 201, y: 655), to: TouchPoint(x: 201, y: 345), press: 0, duration: 0.8)
        let opened = try await post(DeviceActivity.self, baseURL, "api/v1/activity", DeviceActivityReport(
            actor: .agent, via: "cli", kind: "scroll", title: "Scroll up 300 pt", gesture: gesture
        ))
        let feed = try await activity(baseURL)
        XCTAssertEqual(feed.entries.map(\.title), ["Scroll up 300 pt"])
        XCTAssertEqual(feed.entries.first?.gesture, gesture)
        XCTAssertNil(feed.run, "nothing is running a test")

        _ = try await post(DeviceActivity.self, baseURL, "api/v1/activity", DeviceActivityReport(id: opened.id, status: .done))
        let changed = try await activity(baseURL, since: feed.revision)
        XCTAssertEqual(changed.entries.map(\.status), [.done])
    }

    // No simulator is needed: an input the server refuses is still something
    // somebody tried to do, and the feed says who.
    func testAnInputIsAttributedToWhoeverSentIt() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }
        _ = try await postRaw(baseURL, "api/v1/input", #"{"action": "paste", "text": ""}"#, headers: ["X-SimTool-Source": "viewer"])
        _ = try await postRaw(baseURL, "api/v1/input", #"{"action": "launch"}"#)
        let feed = try await activity(baseURL)
        XCTAssertEqual(feed.entries.map(\.actor), [.viewer, .agent])
        XCTAssertEqual(feed.entries.map(\.via), ["viewer", "api"])
        XCTAssertEqual(feed.entries.map(\.title), ["Paste", "Launch the app"])
        XCTAssertEqual(feed.entries.map(\.status), [.failed, .failed])
        XCTAssertTrue(feed.entries[1].error?.contains("Launch requires an app bundle id") == true)
    }

    func testMocksAndTestRunsLandInTheFeed() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }
        let draft = MockRuleDraft(match: MockMatch(method: "*/GetPromotions"), response: MockResponse(kind: .error, grpcStatus: "unavailable"))
        _ = try await post(MockRuleCreateResponse.self, baseURL, "api/v1/mocks", draft)
        _ = try await postRaw(baseURL, "api/v1/tests/start", #"{"title":"Promotions fail over","video":false}"#)
        // While a session records, API input is the run driving the device.
        _ = try await postRaw(baseURL, "api/v1/input", #"{"action": "launch"}"#)
        _ = try await postRaw(baseURL, "api/v1/tests/entries", #"{"kind":"step","text":"✓ 1/1 wait for “Promotions”"}"#)
        _ = try await postRaw(baseURL, "api/v1/tests/entries", #"{"kind":"log","logs":["On screen:","Button Retry"]}"#)
        let during = try await activity(baseURL)
        XCTAssertEqual(during.run?.active, true, "the feed says a run drives the device")
        _ = try await postRaw(baseURL, "api/v1/tests/stop", #"{"status":"passed"}"#)
        _ = try await delete(baseURL, "api/v1/mocks")

        let feed = try await activity(baseURL)
        XCTAssertEqual(feed.entries.map(\.title), [
            "Mock armed: */GetPromotions",
            "Test started: Promotions fail over",
            "Launch the app",
            "✓ 1/1 wait for “Promotions”",
            "Test passed: Promotions fail over",
            "1 mock cleared",
        ], "a failure's screen dump is not an activity")
        XCTAssertEqual(feed.entries.map(\.actor), [.agent, .test, .test, .test, .test, .agent])
        XCTAssertEqual(feed.entries.first?.detail, "fails with unavailable · mock-1")
        XCTAssertNil(feed.run)
    }

    // MARK: - helpers

    private func startServer() throws -> (StreamServer, URL) {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(
            host: "127.0.0.1",
            port: port,
            device: device,
            captureEnabled: false,
            testSessionsRoot: root.appendingPathComponent("test-sessions"),
            testsRoot: root.appendingPathComponent("tests")
        ))
        try server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    private func activity(_ baseURL: URL, since: Int? = nil) async throws -> DeviceActivityPayload {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/activity"), resolvingAgainstBaseURL: false)!
        if let since { components.queryItems = [URLQueryItem(name: "since", value: String(since))] }
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSON.decoder.decode(DeviceActivityPayload.self, from: data)
    }

    private func post<T: Decodable, Body: Encodable>(_ type: T.Type, _ baseURL: URL, _ path: String, _ body: Body) async throws -> T {
        let data = try await postRaw(baseURL, path, String(decoding: try JSON.encoder.encode(body), as: UTF8.self))
        return try JSON.decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func postRaw(_ baseURL: URL, _ path: String, _ body: String, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body.utf8)
        return try await URLSession.shared.data(for: request).0
    }

    private func delete(_ baseURL: URL, _ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "DELETE"
        return try await URLSession.shared.data(for: request).0
    }

    private func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        return UInt16(bigEndian: address.sin_port)
    }
}
