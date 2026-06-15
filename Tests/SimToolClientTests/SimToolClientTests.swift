import Foundation
import XCTest
@testable import SimToolClient
import SimToolCore
import SimToolNetworkLogger

final class SimToolClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testBuildsRootAndAPIURLsFromRootURL() {
        let client = SimToolClient(baseURL: URL(string: "http://127.0.0.1:3200")!)
        XCTAssertEqual(client.rootURL.absoluteString, "http://127.0.0.1:3200")
        XCTAssertEqual(client.apiURL.absoluteString, "http://127.0.0.1:3200/api/v1")
    }

    func testBuildsRootAndAPIURLsFromAPIURL() {
        let client = SimToolClient(baseURL: URL(string: "http://127.0.0.1:3200/api/v1")!)
        XCTAssertEqual(client.rootURL.absoluteString, "http://127.0.0.1:3200/")
        XCTAssertEqual(client.apiURL.absoluteString, "http://127.0.0.1:3200/api/v1")
    }

    func testDecodesStatus() async throws {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/status")
            let payload = ServerStatusPayload(
                device: "iPhone",
                udid: "UDID",
                width: 390,
                height: 844,
                healthy: true,
                metrics: StreamMetricsPayload(capturedFrames: 10)
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(payload, pretty: false))
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        let status = try await client.status()
        XCTAssertTrue(status.healthy)
        XCTAssertEqual(status.metrics.capturedFrames, 10)
    }

    func testJSONRequestSendsBody() async throws {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/input")
            XCTAssertEqual(request.httpMethod, "POST")
            let payload = CommandResultPayload(ok: true, stdout: "", stderr: "")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(payload, pretty: false))
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        let result = try await client.button("home")
        XCTAssertTrue(result.ok)
    }

    func testThrowsClientErrorForErrorPayload() async {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            let data = #"{"error":"Server exploded"}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, data)
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        do {
            _ = try await client.screenshot()
            XCTFail("Expected request to throw")
        } catch let error as SimToolClientError {
            XCTAssertEqual(error.statusCode, 500)
            XCTAssertEqual(error.message, "Server exploded")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestsNetworkLoggerEvents() async throws {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/network/events")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["app"], "com.example.app")
            XCTAssertEqual(query["protocol"], "http")
            XCTAssertEqual(query["since"], "2026-01-01T00:00:00.000Z")
            XCTAssertEqual(query["limit"], "5")
            let payload = NetworkLoggerEventsPayload(events: [self.makeLoggerEvent()])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(payload, pretty: false))
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        let payload = try await client.networkLoggerEvents(
            app: "com.example.app",
            networkProtocol: .http,
            since: "2026-01-01T00:00:00.000Z",
            limit: 5
        )

        XCTAssertEqual(payload.eventCount, 1)
        XCTAssertEqual(payload.events[0].appBundleID, "com.example.app")
    }

    func testIngestsNetworkLoggerEventBatch() async throws {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/network/events")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let response = NetworkLoggerIngestionResponse(acceptedCount: 1)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(response, pretty: false))
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        let response = try await client.ingestNetworkLoggerEvents(NetworkLoggerBatchPayload(events: [makeLoggerEvent()]))

        XCTAssertEqual(response.acceptedCount, 1)
    }

    func testStartsLogCaptureWithBody() async throws {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/logs/capture")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = MockURLProtocol.body(of: request)
            let decoded = try JSON.decoder.decode(LogCaptureStartRequest.self, from: body)
            XCTAssertEqual(decoded.app, "com.example.MyApp")
            XCTAssertEqual(decoded.captureStdout, true)
            let payload = LogCaptureStatusPayload(active: true, device: "UDID", app: "com.example.MyApp", captureStdout: true)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(payload, pretty: false))
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        let status = try await client.startLogCapture(app: "com.example.MyApp", captureStdout: true)
        XCTAssertTrue(status.active)
        XCTAssertEqual(status.app, "com.example.MyApp")
    }

    func testPollsLogCaptureEntriesAndRoundTripsEntry() async throws {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/logs/capture")
            XCTAssertEqual(request.httpMethod, "GET")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["since"], "7")
            XCTAssertEqual(query["limit"], "250")
            let entry = LogEntry(
                sequence: 8,
                timestamp: "2026-01-01T00:00:00.000Z",
                source: .oslog,
                message: "hi",
                level: "Error",
                subsystem: "com.example.MyApp",
                category: "ConsoleLogger",
                process: "My App"
            )
            let payload = LogCaptureEntriesPayload(entries: [entry], cursor: 8, droppedCount: 3)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(payload, pretty: false))
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        let payload = try await client.logCaptureEntries(since: 7, limit: 250)
        XCTAssertEqual(payload.cursor, 8)
        XCTAssertEqual(payload.droppedCount, 3)
        let entry = try XCTUnwrap(payload.entries.first)
        XCTAssertEqual(entry.sequence, 8)
        XCTAssertEqual(entry.source, .oslog)
        XCTAssertEqual(entry.message, "hi")
        XCTAssertEqual(entry.level, "Error")
        XCTAssertEqual(entry.subsystem, "com.example.MyApp")
        XCTAssertEqual(entry.process, "My App")
    }

    func testStopsLogCapture() async throws {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/logs/capture/stop")
            XCTAssertEqual(request.httpMethod, "POST")
            let payload = LogCaptureStatusPayload(active: false)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(payload, pretty: false))
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        let status = try await client.stopLogCapture()
        XCTAssertFalse(status.active)
    }

    func testLogCaptureSurfacesHTTPError() async {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            let data = #"{"error":"Capturing stdout/print requires an app bundle identifier"}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, data)
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        do {
            _ = try await client.startLogCapture(captureStdout: true)
            XCTFail("Expected request to throw")
        } catch let error as SimToolClientError {
            XCTAssertEqual(error.statusCode, 400)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestsLaunchesAndRoundTripsPayload() async throws {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/launches")
            XCTAssertEqual(request.httpMethod, "GET")
            let payload = AppLaunchesPayload(launches: [
                AppLaunchInfo(launchId: 0, pid: 100, app: "com.example.MyApp", startedAt: "2026-01-01T00:00:00.000Z", endedAt: "2026-01-01T00:01:00.000Z"),
                AppLaunchInfo(launchId: 1, pid: 200, app: "com.example.MyApp", startedAt: "2026-01-01T00:01:00.000Z"),
            ])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(payload, pretty: false))
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        let payload = try await client.launches()
        XCTAssertEqual(payload.launches.map(\.launchId), [0, 1])
        XCTAssertEqual(payload.launches[0].pid, 100)
        XCTAssertEqual(payload.launches[0].endedAt, "2026-01-01T00:01:00.000Z")
        XCTAssertNil(payload.launches[1].endedAt)
    }

    func testDecodesLaunchTagsOnLogAndNetworkPayloads() async throws {
        let session = makeSession()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v1/logs/capture" {
                let entry = LogEntry(sequence: 1, timestamp: "t", source: .oslog, message: "hi", pid: 4412, launchId: 2)
                let payload = LogCaptureEntriesPayload(entries: [entry], cursor: 1)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(payload, pretty: false))
            }
            var event = self.makeLoggerEvent()
            event.pid = 4412
            event.launchId = 2
            let payload = NetworkLoggerEventsPayload(events: [event])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSON.data(payload, pretty: false))
        }

        let client = SimToolClient(baseURL: URL(string: "http://simtool.test")!, session: session)
        let logs = try await client.logCaptureEntries(since: nil, limit: 10)
        XCTAssertEqual(logs.entries.first?.launchId, 2)
        XCTAssertEqual(logs.entries.first?.pid, 4412)
        let events = try await client.networkLoggerEvents(limit: 10)
        XCTAssertEqual(events.events.first?.launchId, 2)
        XCTAssertEqual(events.events.first?.pid, 4412)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeLoggerEvent() -> NetworkLoggerEvent {
        NetworkLoggerEvent(
            id: "event-1",
            timestamp: "2026-01-01T00:00:00.000Z",
            appBundleID: "com.example.app",
            networkProtocol: .http,
            durationMilliseconds: 12,
            request: NetworkLoggerRequest(method: "GET", url: "https://example.test"),
            response: NetworkLoggerResponse(statusCode: 200)
        )
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// URLSession turns `httpBody` into `httpBodyStream` before the protocol sees it; read either.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: SimToolClientError(statusCode: 500, message: "No mock handler"))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
