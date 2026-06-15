import Darwin
import Foundation
import XCTest
import SimToolCore
import SimToolServer

final class LogCaptureRouteTests: XCTestCase {
    func testLogCaptureStartPollStopLifecycle() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }

        // Start with an empty body: defaults to the server's selected device, OSLog only.
        let started = try await postJSON(LogCaptureStatusPayload.self, url: baseURL.appendingPathComponent("api/v1/logs/capture"), body: Data())
        XCTAssertTrue(started.active)
        XCTAssertEqual(started.device, "TEST-UDID")
        XCTAssertFalse(started.captureStdout)

        // Poll: a well-formed cursor payload decodes (entries may be empty for a fake device).
        let entries = try await getJSON(LogCaptureEntriesPayload.self, url: baseURL.appendingPathComponent("api/v1/logs/capture"), query: "since=-1&limit=10")
        XCTAssertNotNil(entries.cursor)

        // Stop: capture becomes inactive.
        let stopped = try await postJSON(LogCaptureStatusPayload.self, url: baseURL.appendingPathComponent("api/v1/logs/capture/stop"), body: Data())
        XCTAssertFalse(stopped.active)
    }

    func testCaptureDefaultsToConfiguredApp() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(
            host: "127.0.0.1", port: port, device: device, captureEnabled: false, defaultLogApp: "com.example.MyApp.debug"
        ))
        try server.start()
        defer { server.stop() }
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!

        // Empty body should adopt the configured default app and capture its stdout/print + OSLog.
        let started = try await postJSON(LogCaptureStatusPayload.self, url: baseURL.appendingPathComponent("api/v1/logs/capture"), body: Data())
        XCTAssertTrue(started.active)
        XCTAssertEqual(started.app, "com.example.MyApp.debug")
        XCTAssertTrue(started.captureStdout)

        // /config advertises the default app so viewers can scope automatically.
        let config = try await getJSON(ServerConfigPayload.self, url: baseURL.appendingPathComponent("config"), query: "")
        XCTAssertEqual(config.logApp, "com.example.MyApp.debug")

        _ = try await postJSON(LogCaptureStatusPayload.self, url: baseURL.appendingPathComponent("api/v1/logs/capture/stop"), body: Data())
    }

    func testStdoutCaptureWithoutAppIsRejected() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/logs/capture"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"captureStdout":true}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
    }

    func testExistingLogSnapshotRouteStillResponds() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }

        // The bounded snapshot route is unchanged and still returns a LogTailPayload shape.
        let payload = try await getJSON(LogTailPayload.self, url: baseURL.appendingPathComponent("api/v1/logs"), query: "lines=5&seconds=0.25")
        XCTAssertNotNil(payload.lines)
    }

    // MARK: - Helpers

    private func startServer() throws -> (StreamServer, URL) {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    private func getJSON<T: Decodable>(_ type: T.Type, url: URL, query: String) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = query
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
