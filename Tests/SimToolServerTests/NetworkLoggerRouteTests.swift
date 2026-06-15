import Darwin
import Foundation
import XCTest
import SimToolClient
import SimToolCore
import SimToolNetworkLogger
import SimToolServer

final class NetworkLoggerRouteTests: XCTestCase {
    func testNetworkLoggerRoutesIngestFilterAndRejectInvalidJSON() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let client = SimToolClient(baseURL: baseURL)
        let response = try await client.ingestNetworkLoggerEvents(NetworkLoggerBatchPayload(events: [
            makeEvent(id: "http", networkProtocol: .http),
            makeEvent(id: "grpc", networkProtocol: .grpc),
        ]))
        XCTAssertEqual(response.acceptedCount, 2)

        let payload = try await client.networkLoggerEvents(app: "com.example.app", networkProtocol: .grpc, limit: 1)
        XCTAssertEqual(payload.events.map(\.id), ["grpc"])

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/network/events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("not json".utf8)
        let (_, invalidResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((invalidResponse as? HTTPURLResponse)?.statusCode, 400)
    }

    func testNetworkBatchesAreTaggedWithLaunchAndExposedViaLaunchesRoute() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        let client = SimToolClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)

        // No app process observed yet.
        let empty = try await client.launches()
        XCTAssertTrue(empty.launches.isEmpty)

        // First launch (pid 100).
        _ = try await client.ingestNetworkLoggerEvents(NetworkLoggerBatchPayload(events: [makeEvent(id: "a", networkProtocol: .http)], pid: 100))
        // Relaunch (pid 200) — a distinct launch.
        _ = try await client.ingestNetworkLoggerEvents(NetworkLoggerBatchPayload(events: [makeEvent(id: "b", networkProtocol: .http)], pid: 200))

        let launches = try await client.launches()
        XCTAssertEqual(launches.launches.map(\.pid), [100, 200])
        XCTAssertEqual(launches.launches.map(\.launchId), [0, 1])
        XCTAssertNotNil(launches.launches[0].endedAt)
        XCTAssertNil(launches.launches[1].endedAt)

        let events = try await client.networkLoggerEvents(limit: 10)
        let byId = Dictionary(uniqueKeysWithValues: events.events.map { ($0.id, $0) })
        XCTAssertEqual(byId["a"]?.launchId, 0)
        XCTAssertEqual(byId["a"]?.pid, 100)
        XCTAssertEqual(byId["b"]?.launchId, 1)
    }

    private func makeEvent(id: String, networkProtocol: NetworkLoggerProtocol) -> NetworkLoggerEvent {
        NetworkLoggerEvent(
            id: id,
            timestamp: "2026-01-01T00:00:00.000Z",
            appBundleID: "com.example.app",
            networkProtocol: networkProtocol,
            durationMilliseconds: 1,
            request: NetworkLoggerRequest(method: networkProtocol == .http ? "GET" : nil, url: "https://example.test"),
            response: NetworkLoggerResponse(statusCode: networkProtocol == .http ? 200 : nil, grpcStatusCode: networkProtocol == .grpc ? "0" : nil)
        )
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
