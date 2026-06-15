import Darwin
import Foundation
import XCTest
import SimToolClient
import SimToolCore
import SimToolStateLogger
import SimToolServer

final class StateLoggerRouteTests: XCTestCase {
    func testStateRoutesIngestAndPollIncrementally() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let client = SimToolClient(baseURL: baseURL)

        let response = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [
            makeEvent(seq: 0),
            makeEvent(seq: 1),
        ]))
        XCTAssertEqual(response.acceptedCount, 2)

        let all = try await client.stateLoggerEvents()
        XCTAssertEqual(all.events.map(\.seq), [0, 1])
        XCTAssertEqual(all.nextCursor, 1)

        _ = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [makeEvent(seq: 2)]))
        let incremental = try await client.stateLoggerEvents(since: all.nextCursor)
        XCTAssertEqual(incremental.events.map(\.seq), [2])

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/state/events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("not json".utf8)
        let (_, invalidResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((invalidResponse as? HTTPURLResponse)?.statusCode, 400)
    }

    func testStateBatchesAreTaggedWithLaunch() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        let client = SimToolClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        _ = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [makeEvent(seq: 0)], pid: 100))
        _ = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [makeEvent(seq: 1)], pid: 200))

        let launches = try await client.launches()
        XCTAssertEqual(launches.launches.map(\.pid), [100, 200])

        let events = try await client.stateLoggerEvents()
        XCTAssertEqual(events.events.map(\.launchId), [0, 1])
        XCTAssertEqual(events.events.first?.pid, 100)
    }

    private func makeEvent(seq: Int) -> StateLoggerEvent {
        StateLoggerEvent(
            modelId: "AppModel#0",
            name: "AppModel",
            seq: seq,
            timestamp: 1_700_000_000 + Double(seq),
            snapshot: .object(["count": .number(Double(seq))])
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
