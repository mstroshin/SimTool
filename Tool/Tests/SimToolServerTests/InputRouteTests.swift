import Darwin
import Foundation
import XCTest
import SimToolCore
import SimToolServer

final class InputRouteTests: XCTestCase {
    func testLaunchActionWithoutBundleIdFailsWithExplanation() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/input")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"action": "launch"}"#.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("Launch requires an app bundle id"), "unexpected error body: \(body)")
    }

    func testPasteActionWithoutTextFailsBeforeTouchingTheSimulator() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/input")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"action": "paste", "text": ""}"#.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("Paste input requires text"), "unexpected error body: \(body)")
    }

    func testMediaRoutesRejectWhatTheyCannotUseBeforeTouchingTheSimulator() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        func post(_ path: String, contentType: String, body: Data) async throws -> (Int?, String) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode, String(decoding: data, as: UTF8.self))
        }

        let empty = try await post("/api/v1/input/paste-image", contentType: "image/png", body: Data())
        XCTAssertEqual(empty.0, 400)
        XCTAssertTrue(empty.1.contains("must be the file's bytes"), "unexpected error body: \(empty.1)")

        let video = try await post("/api/v1/input/paste-image", contentType: "video/mp4", body: Data([0, 1, 2]))
        XCTAssertEqual(video.0, 400)
        XCTAssertTrue(video.1.contains("not an image"), "unexpected error body: \(video.1)")

        let text = try await post("/api/v1/photos", contentType: "text/plain", body: Data("hi".utf8))
        XCTAssertEqual(text.0, 400)
        XCTAssertTrue(text.1.contains("not an image or a video"), "unexpected error body: \(text.1)")
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
