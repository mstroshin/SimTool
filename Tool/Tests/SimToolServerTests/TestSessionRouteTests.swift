import Darwin
import Foundation
import XCTest
import SimToolCore
@testable import SimToolServer

final class TestSessionRouteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-test-routes-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSessionLifecycleOverHTTP() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }

        // Start. The recorder is real simctl against a fake UDID: spawn either
        // fails fast (videoError) or records nothing — the session must run
        // regardless.
        let started = try await postJSON(
            TestSession.self,
            url: baseURL.appendingPathComponent("api/v1/tests/start"),
            body: Data(#"{"title":"Verify preference editing"}"#.utf8)
        )
        XCTAssertEqual(started.status, .running)
        XCTAssertEqual(started.title, "Verify preference editing")

        // Append a step and a log entry.
        let stepped = try await postJSON(
            TestSession.self,
            url: baseURL.appendingPathComponent("api/v1/tests/entries"),
            body: Data(#"{"kind":"step","text":"Tapped Save","logs":["[Settings] save OK"]}"#.utf8)
        )
        XCTAssertEqual(stepped.entries.count, 1)
        let logged = try await postJSON(
            TestSession.self,
            url: baseURL.appendingPathComponent("api/v1/tests/entries"),
            body: Data(#"{"kind":"log","logs":["[Sync] cache refreshed"]}"#.utf8)
        )
        XCTAssertEqual(logged.entries.count, 2)

        // List shows the running session.
        let running = try await getJSON(TestSessionListPayload.self, url: baseURL.appendingPathComponent("api/v1/tests"), query: "")
        XCTAssertEqual(running.sessions.first?.id, started.id)
        XCTAssertEqual(running.sessions.first?.status, .running)

        // Video while running -> 409.
        let videoURL = baseURL.appendingPathComponent("api/v1/tests/\(started.id)/video")
        let videoWhileRunning = try await statusCode(for: videoURL)
        XCTAssertEqual(videoWhileRunning, 409)

        // Stop with a final status.
        let stopped = try await postJSON(
            TestSession.self,
            url: baseURL.appendingPathComponent("api/v1/tests/stop"),
            body: Data(#"{"status":"passed"}"#.utf8)
        )
        XCTAssertEqual(stopped.status, .passed)
        XCTAssertNotNil(stopped.endedAt)
    }

    func testConflictAndValidationStatusCodes() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }

        // No active session: entries and stop are conflicts.
        let entryWithoutSession = try await statusCode(
            forPost: baseURL.appendingPathComponent("api/v1/tests/entries"), body: #"{"kind":"step","text":"x"}"#
        )
        XCTAssertEqual(entryWithoutSession, 409)
        let stopWithoutSession = try await statusCode(
            forPost: baseURL.appendingPathComponent("api/v1/tests/stop"), body: #"{"status":"passed"}"#
        )
        XCTAssertEqual(stopWithoutSession, 409)

        _ = try await postJSON(
            TestSession.self,
            url: baseURL.appendingPathComponent("api/v1/tests/start"),
            body: Data(#"{"title":"First"}"#.utf8)
        )
        // Second start: conflict.
        let secondStart = try await statusCode(
            forPost: baseURL.appendingPathComponent("api/v1/tests/start"), body: #"{"title":"Second"}"#
        )
        XCTAssertEqual(secondStart, 409)
        // Empty step: bad request.
        let emptyStep = try await statusCode(
            forPost: baseURL.appendingPathComponent("api/v1/tests/entries"), body: #"{"kind":"step","text":"  "}"#
        )
        XCTAssertEqual(emptyStep, 400)
        // Non-terminal stop status: bad request.
        let nonTerminalStop = try await statusCode(
            forPost: baseURL.appendingPathComponent("api/v1/tests/stop"), body: #"{"status":"running"}"#
        )
        XCTAssertEqual(nonTerminalStop, 400)
        // Unknown session video: not found.
        let unknownVideo = try await statusCode(
            for: baseURL.appendingPathComponent("api/v1/tests/nope/video")
        )
        XCTAssertEqual(unknownVideo, 404)
    }

    func testVideoServingHonorsRangeRequests() async throws {
        // Pre-seed a finished session with a known video payload, then serve it.
        let store = TestSessionStore(root: root)
        let session = TestSession(
            id: "2026-06-12-1400-seeded",
            title: "Seeded",
            deviceUdid: "TEST-UDID",
            deviceName: "iPhone",
            startedAt: Date(timeIntervalSinceNow: -120),
            endedAt: Date(timeIntervalSinceNow: -60),
            recordingStartedAt: Date(timeIntervalSinceNow: -119),
            status: .passed
        )
        try store.write(session)
        let videoBytes = Data((0..<1000).map { UInt8($0 % 251) })
        try videoBytes.write(to: store.videoFile(for: session.id))

        let (server, baseURL) = try startServer()
        defer { server.stop() }
        let videoURL = baseURL.appendingPathComponent("api/v1/tests/\(session.id)/video")

        // Full fetch: 200, whole payload, advertises range support.
        let (fullData, fullResponse) = try await URLSession.shared.data(from: videoURL)
        let full = fullResponse as! HTTPURLResponse
        XCTAssertEqual(full.statusCode, 200)
        XCTAssertEqual(fullData, videoBytes)
        XCTAssertEqual(full.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(full.value(forHTTPHeaderField: "Content-Type"), "video/mp4")

        // Range fetch: 206 with the right slice and Content-Range.
        var rangeRequest = URLRequest(url: videoURL)
        rangeRequest.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (partData, partResponse) = try await URLSession.shared.data(for: rangeRequest)
        let part = partResponse as! HTTPURLResponse
        XCTAssertEqual(part.statusCode, 206)
        XCTAssertEqual(partData, videoBytes.subdata(in: 100..<200))
        XCTAssertEqual(part.value(forHTTPHeaderField: "Content-Range"), "bytes 100-199/1000")

        // Unsatisfiable range: 416 with the size.
        var badRequest = URLRequest(url: videoURL)
        badRequest.setValue("bytes=2000-", forHTTPHeaderField: "Range")
        let (_, badResponse) = try await URLSession.shared.data(for: badRequest)
        let bad = badResponse as! HTTPURLResponse
        XCTAssertEqual(bad.statusCode, 416)
        XCTAssertEqual(bad.value(forHTTPHeaderField: "Content-Range"), "bytes */1000")
        XCTAssertEqual(bad.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
    }

    func testOpenEndedRangeStreamsFromOffsetToEnd() async throws {
        let store = TestSessionStore(root: root)
        let session = TestSession(
            id: "2026-06-12-1500-seeded",
            title: "Seeded open-ended",
            deviceUdid: "TEST-UDID",
            deviceName: "iPhone",
            startedAt: Date(timeIntervalSinceNow: -120),
            endedAt: Date(timeIntervalSinceNow: -60),
            recordingStartedAt: Date(timeIntervalSinceNow: -119),
            status: .passed
        )
        try store.write(session)
        let videoBytes = Data((0..<1000).map { UInt8($0 % 251) })
        try videoBytes.write(to: store.videoFile(for: session.id))

        let (server, baseURL) = try startServer()
        defer { server.stop() }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/tests/\(session.id)/video"))
        request.setValue("bytes=200-", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data, videoBytes.subdata(in: 200..<1000))
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 200-999/1000")
    }

    func testDeleteSessionOverHTTP() async throws {
        // Pre-seed a finished session with a video file, then delete it.
        let store = TestSessionStore(root: root)
        let session = TestSession(
            id: "2026-06-12-1600-seeded",
            title: "Seeded for delete",
            deviceUdid: "TEST-UDID",
            deviceName: "iPhone",
            startedAt: Date(timeIntervalSinceNow: -120),
            endedAt: Date(timeIntervalSinceNow: -60),
            status: .passed
        )
        try store.write(session)
        try Data("video".utf8).write(to: store.videoFile(for: session.id))

        let (server, baseURL) = try startServer()
        defer { server.stop() }

        let deleted = try await statusCode(
            forDelete: baseURL.appendingPathComponent("api/v1/tests/\(session.id)")
        )
        XCTAssertEqual(deleted, 200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: session.id).path))

        // Unknown id: not found.
        let unknown = try await statusCode(forDelete: baseURL.appendingPathComponent("api/v1/tests/nope"))
        XCTAssertEqual(unknown, 404)
    }

    // MARK: - Helpers

    private func startServer() throws -> (StreamServer, URL) {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(
            host: "127.0.0.1", port: port, device: device, captureEnabled: false, testSessionsRoot: root
        ))
        try server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    private func statusCode(for url: URL) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(from: url)
        return (response as! HTTPURLResponse).statusCode
    }

    private func statusCode(forDelete url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    private func statusCode(forPost url: URL, body: String) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    private func getJSON<T: Decodable>(_ type: T.Type, url: URL, query: String) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = query.isEmpty ? nil : query
        let (data, _) = try await URLSession.shared.data(from: components.url!)
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
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(descriptor, rebound, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return UInt16(bigEndian: address.sin_port)
    }
}
