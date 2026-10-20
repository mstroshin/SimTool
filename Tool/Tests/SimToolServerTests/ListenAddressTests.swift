import Darwin
import Foundation
import XCTest
import SimToolCore
@testable import SimToolServer

// A server started on 127.0.0.1 answers this Mac only: whoever shares its
// network must not reach the captured traffic, the logs or the screen.
final class ListenAddressTests: XCTestCase {
    func testTheSocketBindsTheConfiguredAddress() {
        XCTAssertEqual(StreamServer.listenAddress(forHost: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(StreamServer.listenAddress(forHost: "localhost"), "127.0.0.1")
        XCTAssertEqual(StreamServer.listenAddress(forHost: "LocalHost"), "127.0.0.1")
        XCTAssertEqual(StreamServer.listenAddress(forHost: "192.168.1.20"), "192.168.1.20")
        // Every interface, as asked for — or a name the socket cannot bind to.
        XCTAssertNil(StreamServer.listenAddress(forHost: "0.0.0.0"))
        XCTAssertNil(StreamServer.listenAddress(forHost: ""))
        XCTAssertNil(StreamServer.listenAddress(forHost: "my-mac.local"))
    }

    func testALoopbackServerIsNotReachableFromTheNetwork() throws {
        guard let lan = nonLoopbackIPv4() else { throw XCTSkip("this Mac has no network address besides loopback") }

        let open = try startServer(host: "0.0.0.0")
        defer { open.server.stop() }
        XCTAssertTrue(accepts(lan, open.port), "with host 0.0.0.0 the network address must answer — else this test proves nothing")

        let loopback = try startServer(host: "127.0.0.1")
        defer { loopback.server.stop() }
        XCTAssertTrue(accepts("127.0.0.1", loopback.port), "the server answers on loopback")
        // Refused, or dropped without an answer when the firewall is in stealth mode.
        XCTAssertFalse(accepts(lan, loopback.port), "\(lan):\(loopback.port) accepted a connection: the server listens on every interface")
    }

    private func startServer(host: String) throws -> (server: StreamServer, port: UInt16) {
        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: host, port: port, device: device, captureEnabled: false))
        try server.start()
        return (server, port)
    }

    private func accepts(_ ip: String, _ port: UInt16) -> Bool {
        guard case let .success(descriptor) = connectTCP(ip, port: port, timeout: 2) else { return false }
        close(descriptor)
        return true
    }
}
