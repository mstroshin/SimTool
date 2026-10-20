import Darwin
import Foundation
import XCTest
import SimToolCore
import SimToolServer

final class ConfigRouteTests: XCTestCase {
    // The viewer resets its log and state cursors when the instance changes: a
    // restarted server numbers entries from zero, and an old cursor skips them.
    func testConfigIdentifiesTheServerInstanceRuntimeAndVersion() async throws {
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-4", state: "Booted", isAvailable: true)
        let first = try await config(of: device)
        let again = try await config(of: device)

        XCTAssertEqual(first.runtime, "com.apple.CoreSimulator.SimRuntime.iOS-26-4")
        XCTAssertEqual(first.version, SimToolVersion.current)
        let instance = try XCTUnwrap(first.instanceId)
        XCTAssertFalse(instance.isEmpty)
        XCTAssertNotEqual(again.instanceId, instance, "every server start is a new instance")
    }

    // A client built before the fields existed reads a payload without them.
    func testAPayloadWithoutTheNewFieldsStillDecodes() throws {
        let old = ServerConfigPayload(device: "iPhone", udid: "U", width: 1, height: 2, stream: StreamPaths(), metrics: StreamMetricsPayload())
        let json = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("instanceId"))
        let decoded = try JSONDecoder().decode(ServerConfigPayload.self, from: json)
        XCTAssertNil(decoded.instanceId)
        XCTAssertNil(decoded.runtime)
        XCTAssertNil(decoded.version)
    }

    private func config(of device: SimulatorDevice) async throws -> ServerConfigPayload {
        let port = try availablePort()
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/config")!)
        return try JSONDecoder().decode(ServerConfigPayload.self, from: data)
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
