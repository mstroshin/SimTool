import Darwin
import Foundation
import XCTest
import SimToolCore
import SimToolNetworkLogger
import SimToolServer
import SimToolClient

final class MockRouteTests: XCTestCase {
    func testCreateListRemoveLifecycle() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }

        let draft = MockRuleDraft(match: MockMatch(method: "/example.v1.FooService/GetBar"), response: MockResponse(kind: .success, bodyJSON: "{\"ok\":true}"))
        let created = try await postJSON(MockRuleCreateResponse.self, url: baseURL.appendingPathComponent("api/v1/mocks"), body: try JSON.encoder.encode(draft))
        XCTAssertEqual(created.id, "mock-1")

        let list = try await getJSON(MockRuleListPayload.self, url: baseURL.appendingPathComponent("api/v1/mocks"), query: "")
        XCTAssertEqual(list.rules.count, 1)

        let unchanged = try await getJSON(MockRuleListPayload.self, url: baseURL.appendingPathComponent("api/v1/mocks"), query: "since=\(created.generation)")
        XCTAssertTrue(unchanged.unchanged)

        try await delete(url: baseURL.appendingPathComponent("api/v1/mocks/\(created.id)"))
        let afterDelete = try await getJSON(MockRuleListPayload.self, url: baseURL.appendingPathComponent("api/v1/mocks"), query: "")
        XCTAssertEqual(afterDelete.rules.count, 0)
    }

    func testClientRoundTrip() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }
        let client = SimToolClient(baseURL: baseURL)
        let created = try await client.setMock(MockRuleDraft(match: MockMatch(method: "/m"), response: MockResponse(kind: .error, grpcStatus: "unavailable")))
        XCTAssertEqual(created.id, "mock-1")
        let listAfterCreate = try await client.mocks(since: nil)
        XCTAssertEqual(listAfterCreate.rules.count, 1)
        let removed = try await client.removeMock(id: created.id)
        XCTAssertTrue(removed)
        let listAfterRemove = try await client.mocks(since: nil)
        XCTAssertEqual(listAfterRemove.rules.count, 0)
    }

    // --- helpers (mirror LogCaptureRouteTests) ---
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

    private func delete(url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: request)
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
