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

    // --- helpers (mirror MockRouteTests) ---
    private func startServer(sessionsRoot: URL) throws -> (StreamServer, URL) {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(
            host: "127.0.0.1",
            port: port,
            device: device,
            captureEnabled: false,
            testSessionsRoot: sessionsRoot
        ))
        try server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
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
