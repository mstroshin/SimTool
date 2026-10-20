import Darwin
import Foundation
import SimToolClient
import SimToolCore
import SimToolNetworkLogger
import SimToolStateLogger
@testable import SimToolServer
import XCTest

// `GET /api/v1/events` end to end: one stream carries what the viewer used to
// poll, resumes after a drop without losing or repeating anything, and starts
// over from a snapshot when the server it talks to is a new one.
final class InspectorEventsRouteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // Nothing is created up front: the tests folder's watcher would report it.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-events-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAViewerGetsASnapshotThenEachChangeAsItHappens() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }
        let client = SimToolClient(baseURL: baseURL)
        let instance = try await client.config().instanceId

        let stream = try await EventStream.open(baseURL)
        defer { stream.close() }
        XCTAssertEqual(stream.response.value(forHTTPHeaderField: "Content-Type"), "text/event-stream; charset=utf-8")
        XCTAssertNil(stream.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "same-origin only")

        let snapshot = try await stream.next()
        XCTAssertEqual(snapshot.name, "snapshot")
        XCTAssertEqual(snapshot.id, "\(instance ?? ""):0")
        XCTAssertEqual(snapshot.json["instance"] as? String, instance)
        for topic in ["network", "logs", "state", "tests", "launches", "activity"] {
            XCTAssertNotNil(snapshot.json[topic], "the snapshot holds \(topic)")
        }

        _ = try await client.ingestNetworkLoggerEvents(NetworkLoggerBatchPayload(events: [makeCall(id: "a")], pid: 100))
        let launch = try await stream.next()
        XCTAssertEqual(launch.name, "launches", "a new launch comes before its entries")
        XCTAssertEqual((launch.json["launches"] as? [[String: Any]])?.compactMap { $0["pid"] as? Int }, [100])
        let call = try await stream.next()
        XCTAssertEqual(call.name, "network")
        XCTAssertEqual(call.id, "\(instance ?? ""):2")
        XCTAssertEqual((call.json["events"] as? [[String: Any]])?.first?["id"] as? String, "a")
        XCTAssertEqual((call.json["events"] as? [[String: Any]])?.first?["launchId"] as? Int, 0)

        _ = try await client.ingestStateLoggerEvents(StateLoggerBatchPayload(events: [makeModel(seq: 0)], pid: 100))
        let state = try await stream.next()
        XCTAssertEqual(state.name, "state", "the same launch is not announced again")
        XCTAssertEqual((state.json["events"] as? [[String: Any]])?.first?["cursor"] as? Int, 0)
    }

    func testAReconnectingViewerGetsWhatItMissedExactlyOnce() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }
        let client = SimToolClient(baseURL: baseURL)

        let first = try await EventStream.open(baseURL)
        _ = try await first.next()
        _ = try await client.ingestNetworkLoggerEvents(NetworkLoggerBatchPayload(events: [makeCall(id: "a")]))
        let seen = try await first.next()
        first.close()

        _ = try await client.ingestNetworkLoggerEvents(NetworkLoggerBatchPayload(events: [makeCall(id: "b")]))
        _ = try await client.ingestNetworkLoggerEvents(NetworkLoggerBatchPayload(events: [makeCall(id: "c")]))

        // EventSource sends Last-Event-ID itself; a page that had to open a new
        // EventSource passes it in the query instead, encoded as the browser does.
        for resume in [EventStream.Resume.header, .query] {
            let again = try await EventStream.open(baseURL, lastEventID: seen.id, resume: resume)
            defer { again.close() }
            let missed = try await [again.next(), again.next()]
            XCTAssertEqual(missed.map(\.name), ["network", "network"], "no snapshot")
            XCTAssertEqual(missed.compactMap { ($0.json["events"] as? [[String: Any]])?.first?["id"] as? String }, ["b", "c"])
        }
    }

    func testARestartedServerSendsAFreshSnapshot() async throws {
        let port = try availablePort()
        let (old, baseURL) = try startServer(port: port)
        let stream = try await EventStream.open(baseURL)
        _ = try await stream.next()
        _ = try await SimToolClient(baseURL: baseURL).ingestNetworkLoggerEvents(NetworkLoggerBatchPayload(events: [makeCall(id: "a")]))
        let last = try await stream.next()
        stream.close()
        old.stop()

        let (new, _) = try startServer(port: port)
        defer { new.stop() }
        let instance = try await SimToolClient(baseURL: baseURL).config().instanceId
        let again = try await EventStream.open(baseURL, lastEventID: last.id)
        defer { again.close() }
        let snapshot = try await again.next()
        XCTAssertEqual(snapshot.name, "snapshot", "the old run's ids mean nothing to the new one")
        XCTAssertEqual(snapshot.json["instance"] as? String, instance)
        XCTAssertEqual(((snapshot.json["network"] as? [String: Any])?["events"] as? [Any])?.count, 0)
    }

    // What an agent does to the device reaches the viewer the moment the
    // server hears of it, each change of an entry once.
    func testWhatIsDoneToTheDeviceIsPushedAsItChanges() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }
        let stream = try await EventStream.open(baseURL)
        defer { stream.close() }
        let snapshot = try await stream.next(skipping: [])
        XCTAssertEqual((snapshot.json["activity"] as? [String: Any])?["revision"] as? Int, 0)

        let opened = try await send("POST", baseURL, "api/v1/activity", #"{"via":"cli","kind":"tap","title":"Tap “General”","gesture":{"from":{"x":201,"y":406},"to":{"x":201,"y":406},"press":0.06,"duration":0.06}}"#)
        let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: opened) as? [String: Any])?["id"] as? Int)
        let began = try await stream.next(skipping: [])
        XCTAssertEqual(began.name, "activity")
        XCTAssertEqual(began.json["revision"] as? Int, 1)
        let entry = try XCTUnwrap((began.json["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["title"] as? String, "Tap “General”")
        XCTAssertEqual(entry["status"] as? String, "running")
        XCTAssertNotNil(entry["gesture"], "the finger's path goes with it, to draw while it moves")

        _ = try await send("POST", baseURL, "api/v1/activity", #"{"id":\#(id),"status":"done"}"#)
        let finished = try await stream.next(skipping: [])
        XCTAssertEqual((finished.json["entries"] as? [[String: Any]])?.first?["status"] as? String, "done")

        _ = try await send("DELETE", baseURL, "api/v1/mocks")
        let draft = MockRuleDraft(match: MockMatch(method: "*/GetPromotions"), response: MockResponse(kind: .error, grpcStatus: "unavailable"))
        _ = try await send("POST", baseURL, "api/v1/mocks", String(decoding: try JSON.data(draft), as: UTF8.self))
        let mocks = try await stream.next(skipping: [])
        XCTAssertEqual(mocks.name, "network", "the rule first, then what it says in the feed")
        let armed = try await stream.next(skipping: [])
        XCTAssertEqual(armed.name, "activity")
        XCTAssertEqual((armed.json["entries"] as? [[String: Any]])?.map { $0["status"] as? String }, ["done"], "a mock armed is one change, sent once")
    }

    func testDeletionsMocksAndTestRunsArePushedToo() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }
        let stream = try await EventStream.open(baseURL)
        defer { stream.close() }
        _ = try await stream.next()

        let draft = MockRuleDraft(match: MockMatch(method: "/example.v1.Items/List"), response: MockResponse(kind: .success, bodyJSON: "{}"))
        _ = try await send("POST", baseURL, "api/v1/mocks", String(decoding: try JSON.data(draft), as: UTF8.self))
        let mocks = try await stream.next()
        XCTAssertEqual((mocks.json["mocks"] as? [[String: Any]])?.first?["id"] as? String, "mock-1")

        _ = try await send("DELETE", baseURL, "api/v1/network/launches/0")
        let calls = try await stream.next()
        XCTAssertEqual(calls.json["removedLaunch"] as? Int, 0)
        _ = try await send("DELETE", baseURL, "api/v1/logs/launches/0")
        let logs = try await stream.next()
        XCTAssertEqual(logs.name, "logs")
        XCTAssertEqual(logs.json["removedLaunch"] as? Int, 0)

        _ = try await send("POST", baseURL, "api/v1/tests/start", #"{"title":"Checkout","video":false}"#)
        let started = try await stream.next()
        XCTAssertEqual((started.json["session"] as? [String: Any])?["status"] as? String, "running")
        XCTAssertEqual((started.json["run"] as? [String: Any])?["active"] as? Bool, true)
        _ = try await send("POST", baseURL, "api/v1/tests/entries", #"{"kind":"step","text":"Tapped Pay"}"#)
        let stepped = try await stream.next()
        XCTAssertEqual(((stepped.json["session"] as? [String: Any])?["entries"] as? [Any])?.count, 1)
        _ = try await send("POST", baseURL, "api/v1/tests/stop", #"{"status":"passed"}"#)
        let stopped = try await stream.next()
        let session = try XCTUnwrap(stopped.json["session"] as? [String: Any])
        XCTAssertEqual(session["status"] as? String, "passed")
        XCTAssertEqual((stopped.json["run"] as? [String: Any])?["active"] as? Bool, false)
        _ = try await send("DELETE", baseURL, "api/v1/tests/\(session["id"] as? String ?? "")")
        let deleted = try await stream.next()
        XCTAssertEqual(deleted.json["removedSession"] as? String, session["id"] as? String)

        // A test file written by an agent shows up without anyone asking — in a
        // folder that did not exist when the server started.
        let tests = root.appendingPathComponent("tests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try "name: Checkout\nsteps:\n  - tap: { label: Pay }\n".write(
            to: tests.appendingPathComponent("checkout.yml"), atomically: true, encoding: .utf8)
        var files: [String] = []
        for _ in 0..<3 where files.isEmpty {
            let definitions = try await stream.next()
            XCTAssertEqual(definitions.name, "tests")
            files = (definitions.json["definitions"] as? [[String: Any]])?.compactMap { $0["file"] as? String } ?? []
        }
        XCTAssertEqual(files, ["checkout.yml"])
    }

    // MARK: - Helpers

    private func startServer(port: UInt16? = nil) throws -> (StreamServer, URL) {
        let port = try port ?? availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(
            host: "127.0.0.1",
            port: port,
            device: device,
            captureEnabled: false,
            testSessionsRoot: root.appendingPathComponent("test-sessions"),
            testsRoot: root.appendingPathComponent("tests")
        ))
        try server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    @discardableResult
    private func send(_ method: String, _ baseURL: URL, _ path: String, _ body: String? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "\(method) \(path): \(String(decoding: data, as: UTF8.self))")
        return data
    }

    private func makeCall(id: String) -> NetworkLoggerEvent {
        NetworkLoggerEvent(
            id: id,
            appBundleID: "com.example.app",
            networkProtocol: .http,
            durationMilliseconds: 12,
            request: NetworkLoggerRequest(method: "GET", url: "https://example.com/\(id)")
        )
    }

    private func makeModel(seq: Int) -> StateLoggerEvent {
        StateLoggerEvent(modelId: "AppModel#0", name: "AppModel", seq: seq, timestamp: 1_700_000_000, snapshot: .object(["count": .number(Double(seq))]))
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

/// Reads `GET /api/v1/events` the way a browser's EventSource does.
private final class EventStream: @unchecked Sendable {
    enum Resume { case header, query }

    struct Event {
        var id: String?
        var name: String
        var json: [String: Any]
    }

    let response: HTTPURLResponse
    private let bytes: URLSession.AsyncBytes
    private var iterator: URLSession.AsyncBytes.AsyncIterator
    private var buffer = Data()

    private init(bytes: URLSession.AsyncBytes, response: HTTPURLResponse) {
        self.bytes = bytes
        self.iterator = bytes.makeAsyncIterator()
        self.response = response
    }

    static func open(_ baseURL: URL, lastEventID: String? = nil, resume: Resume = .header) async throws -> EventStream {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/events"), resolvingAgainstBaseURL: false)!
        if let lastEventID, resume == .query {
            // encodeURIComponent: the id's `:` goes as %3A.
            components.percentEncodedQuery = "lastEventId=" + (lastEventID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? lastEventID)
        }
        var request = URLRequest(url: components.url!)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID, resume == .header { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        // Nothing for this long means an event that never came: fail, not hang.
        request.timeoutInterval = 10
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        return EventStream(bytes: bytes, response: http)
    }

    /// The next event with data; the retry hint and keep-alive comments are
    /// skipped, and so is the activity feed unless asked for — mocks and test
    /// runs write to it too, between the topics most tests follow.
    func next(skipping skipped: Set<String> = ["activity"]) async throws -> Event {
        while true {
            if let end = buffer.firstRange(of: Data([0x0A, 0x0A])) {
                let block = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<end.upperBound)
                guard let event = ServerSentEvents.parse(block + "\n\n").first, !skipped.contains(event.name) else { continue }
                let json = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any]
                return Event(id: event.id, name: event.name, json: try XCTUnwrap(json))
            }
            guard let byte = try await iterator.next() else { throw URLError(.networkConnectionLost) }
            buffer.append(byte)
        }
    }

    func close() {
        bytes.task.cancel()
    }
}
