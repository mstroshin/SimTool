import Foundation
import SimToolCore
@testable import SimToolServer
import XCTest

final class LiveInputChannelTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        private var storedDowns = 0
        var lines: [String] { lock.withLock { stored } }
        var downs: Int { lock.withLock { storedDowns } }
        func record(_ event: LiveInputEvent) { lock.withLock { stored.append(Self.describe(event)) } }

        /// The helper's own line format, rebuilt from the public fields.
        static func describe(_ event: LiveInputEvent) -> String {
            switch event {
            case let .touch(touch):
                let points = [touch.first] + (touch.second.map { [$0] } ?? [])
                let coordinates = points.flatMap { [$0.x, $0.y] }.map { String(format: "%.5f", $0) }
                return ([touch.phase.rawValue + (touch.second == nil ? "" : "2")] + coordinates).joined(separator: " ")
            case let .key(key):
                return "key \(key.key.usage) \(key.isDown ? 1 : 0)"
            }
        }
        func noteDown() { lock.withLock { storedDowns += 1 } }
    }

    private func makeChannel() -> (LiveInputChannel, Recorder) {
        let recorder = Recorder()
        let channel = LiveInputChannel(emit: { recorder.record($0) }, onDown: { recorder.noteDown() })
        return (channel, recorder)
    }

    func testFramesBecomeHelperEventsInOrder() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"down","x":0.5,"y":0.7}"#)
        channel.receive(#"{"t":"move","x":0.5,"y":0.6}"#)
        channel.receive(#"{"t":"up","x":0.5,"y":0.5}"#)
        XCTAssertEqual(recorder.lines, ["down 0.50000 0.70000", "move 0.50000 0.60000", "up 0.50000 0.50000"])
        XCTAssertEqual(recorder.downs, 1)
        XCTAssertFalse(channel.isTouching)
    }

    func testSecondFingerRidesAlong() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"down","x":0.4,"y":0.4,"x2":0.6,"y2":0.6}"#)
        channel.receive(#"{"t":"move","x":0.3,"y":0.3,"x2":0.7,"y2":0.7}"#)
        XCTAssertEqual(recorder.lines, ["down2 0.40000 0.40000 0.60000 0.60000", "move2 0.30000 0.30000 0.70000 0.70000"])
    }

    func testMovesAndUpsWithoutAFingerDownAreDropped() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"move","x":0.5,"y":0.6}"#)
        channel.receive(#"{"t":"up","x":0.5,"y":0.6}"#)
        XCTAssertEqual(recorder.lines, [])
    }

    func testMalformedFramesAreIgnored() {
        let (channel, recorder) = makeChannel()
        channel.receive("not json")
        channel.receive(#"{"t":"wiggle","x":0.5,"y":0.5}"#)
        channel.receive(#"{"t":"down","x":0.5}"#)
        XCTAssertEqual(recorder.lines, [])
        XCTAssertEqual(recorder.downs, 0)
    }

    func testCoordinatesOutsideTheScreenAreClamped() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"down","x":-0.5,"y":1.5}"#)
        XCTAssertEqual(recorder.lines, ["down 0.00000 1.00000"])
    }

    func testAViewerThatVanishesMidGestureLiftsItsFingerWhereItWas() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"down","x":0.2,"y":0.2,"x2":0.8,"y2":0.8}"#)
        channel.receive(#"{"t":"move","x":0.25,"y":0.3,"x2":0.75,"y2":0.7}"#)
        channel.disconnect()
        XCTAssertEqual(recorder.lines.last, "up2 0.25000 0.30000 0.75000 0.70000")
        // Nothing gets through once the viewer is gone, and nothing is lifted twice.
        channel.receive(#"{"t":"down","x":0.5,"y":0.5}"#)
        channel.disconnect()
        XCTAssertEqual(recorder.lines.count, 3)
    }

    func testKeysBecomeHelperEventsInOrderWithTheFinger() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"down","x":0.5,"y":0.2}"#)
        channel.receive(#"{"t":"up","x":0.5,"y":0.2}"#)
        channel.receive(#"{"t":"keydown","code":"ShiftLeft"}"#)
        channel.receive(#"{"t":"keydown","code":"KeyH"}"#)
        channel.receive(#"{"t":"keyup","code":"KeyH"}"#)
        channel.receive(#"{"t":"keyup","code":"ShiftLeft"}"#)
        XCTAssertEqual(recorder.lines, [
            "down 0.50000 0.20000", "up 0.50000 0.20000",
            "key 225 1", "key 11 1", "key 11 0", "key 225 0",
        ])
        XCTAssertEqual(recorder.downs, 3, "a key press starts an input like a touch does")
    }

    func testAKeyGoesDownOnceAndUpOnlyAfterItWentDown() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"keyup","code":"KeyA"}"#)
        channel.receive(#"{"t":"keydown","code":"KeyA"}"#)
        channel.receive(#"{"t":"keydown","code":"KeyA"}"#)
        channel.receive(#"{"t":"keyup","code":"KeyA"}"#)
        channel.receive(#"{"t":"keyup","code":"KeyA"}"#)
        XCTAssertEqual(recorder.lines, ["key 4 1", "key 4 0"])
    }

    func testKeysWithoutAKeyboardUsageAreIgnored() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"keydown","code":"Fn"}"#)
        channel.receive(#"{"t":"keydown"}"#)
        channel.receive(#"{"t":"keydown","code":7}"#)
        XCTAssertEqual(recorder.lines, [])
        XCTAssertEqual(recorder.downs, 0)
    }

    func testAViewerThatVanishesWhileTypingReleasesItsKeysLastPressedFirst() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"down","x":0.5,"y":0.5}"#)
        channel.receive(#"{"t":"keydown","code":"MetaLeft"}"#)
        channel.receive(#"{"t":"keydown","code":"ShiftLeft"}"#)
        channel.receive(#"{"t":"keydown","code":"ArrowLeft"}"#)
        channel.receive(#"{"t":"keyup","code":"ShiftLeft"}"#)
        channel.disconnect()
        XCTAssertEqual(Array(recorder.lines.suffix(3)), ["up 0.50000 0.50000", "key 80 0", "key 227 0"])
        channel.receive(#"{"t":"keydown","code":"KeyA"}"#)
        channel.disconnect()
        XCTAssertEqual(recorder.lines.count, 8, "nothing gets through once the viewer is gone")
    }

    func testDisconnectWithoutAFingerDownSendsNothing() {
        let (channel, recorder) = makeChannel()
        channel.receive(#"{"t":"down","x":0.5,"y":0.5}"#)
        channel.receive(#"{"t":"up","x":0.5,"y":0.5}"#)
        channel.disconnect()
        XCTAssertEqual(recorder.lines.count, 2)
    }

    func testStreamRouteUpgradesToAWebSocket() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/api/v1/input/stream")!)
        task.resume()
        // A frame that is not a touch is dropped without closing the socket,
        // so a ping still gets its pong afterwards.
        try await task.send(.string(#"{"t":"wiggle","x":0,"y":0}"#))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        task.cancel(with: .normalClosure, reason: nil)
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
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
