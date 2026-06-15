import Foundation
import XCTest
@testable import SimToolNetworkLogger

final class SimToolNetworkLoggerTests: XCTestCase {
    func testPayloadEncodingRoundTrips() throws {
        let event = makeEvent(id: "event-1")
        let payload = NetworkLoggerBatchPayload(events: [event], source: "test")

        let data = try NetworkLoggerJSON.data(payload)
        let decoded = try NetworkLoggerJSON.decoder.decode(NetworkLoggerBatchPayload.self, from: data)

        XCTAssertEqual(decoded.source, "test")
        XCTAssertEqual(decoded.events, [event])
        XCTAssertEqual(decoded.events[0].networkProtocol, .http)
    }

    func testRedactsSensitiveValuesAndBoundsPreview() {
        let redacted = NetworkLoggerRedactor.redacted([
            "Authorization": "Bearer secret",
            "X-Trace": "visible",
            "x-custom-token": "hidden",
        ])

        XCTAssertEqual(redacted["Authorization"], "<redacted>")
        XCTAssertEqual(redacted["X-Trace"], "visible")
        XCTAssertEqual(redacted["x-custom-token"], "<redacted>")
        XCTAssertEqual(NetworkLoggerRedactor.preview(data: Data("abcdef".utf8), maxBytes: 3), "abc")
    }

    func testFileSinkWritesJSONLAndReaderSkipsInvalidLines() async throws {
        let directory = temporaryDirectory()
        let sink = NetworkLoggerFileSink(directoryURL: directory, maxFileBytes: 10_000)
        let event = makeEvent(id: "event-1")

        await sink.record([event])
        let invalid = Data("not json\n".utf8)
        let handle = try FileHandle(forWritingTo: sink.fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: invalid)

        let payload = try NetworkLoggerJSONL.readEvents(
            from: sink.fileURL,
            filter: NetworkLoggerEventFilter(networkProtocol: .http)
        )
        XCTAssertEqual(payload.eventCount, 1)
        XCTAssertEqual(payload.events[0].id, "event-1")
    }

    func testFileSinkFailureIsNonFatal() async throws {
        let directory = temporaryDirectory().appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: directory.path, contents: Data())
        let sink = NetworkLoggerFileSink(directoryURL: directory, maxFileBytes: 10_000)

        await sink.record([makeEvent(id: "event-1")])
    }

    func testHTTPRecordingEmitsRedactedEvent() async throws {
        let sink = CollectingSink()
        let logger = SimToolNetworkLogger(
            configuration: NetworkLoggerConfiguration(
                appBundleID: "com.example.app",
                appDisplayName: "Example",
                fileSinkEnabled: false,
                captureBodyPreviews: true,
                maxBodyPreviewBytes: 4
            ),
            sinks: [sink]
        )
        var request = URLRequest(url: URL(string: "https://api.example.test/v1/items")!)
        request.httpMethod = "POST"
        request.httpBody = Data("abcdef".utf8)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 201,
            httpVersion: nil,
            headerFields: ["Set-Cookie": "secret", "X-Trace": "visible"]
        )!

        let event = await logger.recordHTTP(
            request: request,
            response: response,
            responseBody: Data("response".utf8),
            durationMilliseconds: 12
        )

        XCTAssertEqual(event.appBundleID, "com.example.app")
        XCTAssertEqual(event.request.headers["Authorization"], "<redacted>")
        XCTAssertEqual(event.request.headers["Content-Type"], "application/json")
        XCTAssertEqual(event.request.bodyPreview, "abcd")
        XCTAssertEqual(event.response?.statusCode, 201)
        XCTAssertEqual(event.response?.headers["Set-Cookie"], "<redacted>")
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 1)
    }

    func testGRPCRecorderEmitsEventWithoutGRPCDependency() async {
        let sink = CollectingSink()
        let logger = SimToolNetworkLogger(
            configuration: NetworkLoggerConfiguration(appBundleID: "com.example.app", fileSinkEnabled: false),
            sinks: [sink]
        )

        let recorder = logger.startGRPCCall(
            service: "EchoService",
            method: "Echo",
            fullMethod: "/EchoService/Echo",
            authority: "grpc.example.test",
            requestMetadata: ["authorization": "secret"],
            requestMessageBytes: 42
        )
        let event = await recorder.finish(
            responseMetadata: ["trace-id": "abc"],
            statusCode: "0",
            statusMessage: "OK",
            responseMessageBytes: 24
        )

        XCTAssertEqual(event.networkProtocol, .grpc)
        XCTAssertEqual(event.request.grpcService, "EchoService")
        XCTAssertEqual(event.request.metadata["authorization"], "<redacted>")
        XCTAssertEqual(event.response?.grpcStatusCode, "0")
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 1)
    }

    func testEventStoreEvictsAndFilters() {
        let store = NetworkLoggerEventStore(capacity: 2)
        store.ingest([
            makeEvent(id: "old", timestamp: "2026-01-01T00:00:00.000Z"),
            makeEvent(id: "http", timestamp: "2026-01-01T00:00:01.000Z"),
            makeEvent(id: "grpc", timestamp: "2026-01-01T00:00:02.000Z", networkProtocol: .grpc),
        ])

        XCTAssertEqual(store.query().events.map(\.id), ["http", "grpc"])
        let filtered = store.query(filter: NetworkLoggerEventFilter(networkProtocol: .grpc, limit: 1))
        XCTAssertEqual(filtered.events.map(\.id), ["grpc"])
    }

    func testDeleteEventsDropsOnlyMatchingLaunch() {
        let store = NetworkLoggerEventStore(capacity: 10)
        var first = makeEvent(id: "a", timestamp: "2026-01-01T00:00:00.000Z")
        first.launchId = 1
        var second = makeEvent(id: "b", timestamp: "2026-01-01T00:00:01.000Z")
        second.launchId = 2
        var third = makeEvent(id: "c", timestamp: "2026-01-01T00:00:02.000Z")
        third.launchId = 1
        store.ingest([first, second, third])

        let removed = store.deleteEvents(launchId: 1)

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.query().events.map(\.id), ["b"])
        XCTAssertEqual(store.deleteEvents(launchId: 99), 0)
    }

    func testSinceFilterParsesISO8601Timestamps() {
        let events = [
            makeEvent(id: "before", timestamp: "2026-01-01T09:59:59.000Z"),
            makeEvent(id: "after", timestamp: "2026-01-01T12:00:00.000+02:00"),
        ]
        let filtered = NetworkLoggerEventFilter(since: "2026-01-01T10:00:00Z").apply(to: events)

        XCTAssertEqual(filtered.map(\.id), ["after"])
    }

    func testDisplaySummariesMatchCLIColumns() {
        let http = makeEvent(id: "http")
        let grpc = makeEvent(id: "grpc", networkProtocol: .grpc)

        XCTAssertEqual(http.displayApp, "com.example.app")
        XCTAssertEqual(http.displayRequest, "GET https://example.test")
        XCTAssertEqual(http.displayStatus, "200")
        XCTAssertEqual(http.displayDuration, "10ms")
        XCTAssertEqual(grpc.displayRequest, "EchoService/Echo")
        XCTAssertEqual(grpc.displayStatus, "0")
    }

    func testEnvironmentBootstrapEnabledWithServerURL() {
        let config = NetworkLoggerConfiguration.fromEnvironment([
            "SIMTOOL_NETWORK_LOGGER": "1",
            "SIMTOOL_SERVER_URL": "http://127.0.0.1:3311",
        ])

        XCTAssertNotNil(config)
        XCTAssertEqual(config?.serverSinkURL, URL(string: "http://127.0.0.1:3311"))
        XCTAssertEqual(config?.fileSinkEnabled, false)
        XCTAssertEqual(config?.captureBodyPreviews, true)
        XCTAssertNotNil(SimToolNetworkLogger.makeFromEnvironment([
            "SIMTOOL_NETWORK_LOGGER": "true",
            "SIMTOOL_SERVER_URL": "http://127.0.0.1:3311",
        ]))
    }

    func testEnvironmentBootstrapDisabledWhenAbsentOrFalsey() {
        XCTAssertNil(NetworkLoggerConfiguration.fromEnvironment([:]))
        XCTAssertNil(NetworkLoggerConfiguration.fromEnvironment(["SIMTOOL_NETWORK_LOGGER": "0"]))
        XCTAssertNil(NetworkLoggerConfiguration.fromEnvironment(["SIMTOOL_NETWORK_LOGGER": "false"]))
        XCTAssertNil(SimToolNetworkLogger.makeFromEnvironment([:]))
    }

    func testEnvironmentBootstrapOmitsServerSinkForMissingOrInvalidURL() {
        let missing = NetworkLoggerConfiguration.fromEnvironment(["SIMTOOL_NETWORK_LOGGER": "yes"])
        XCTAssertNotNil(missing)
        XCTAssertNil(missing?.serverSinkURL)

        let invalid = NetworkLoggerConfiguration.fromEnvironment([
            "SIMTOOL_NETWORK_LOGGER": "on",
            "SIMTOOL_SERVER_URL": "http://invalid url with spaces",
        ])
        XCTAssertNotNil(invalid)
        XCTAssertNil(invalid?.serverSinkURL)

        let schemeless = NetworkLoggerConfiguration.fromEnvironment([
            "SIMTOOL_NETWORK_LOGGER": "1",
            "SIMTOOL_SERVER_URL": "127.0.0.1:3311",
        ])
        XCTAssertNil(schemeless?.serverSinkURL)
    }

    func testGRPCMessagePreviewsPopulateBoundedBodyPreview() async {
        let logger = SimToolNetworkLogger(
            configuration: NetworkLoggerConfiguration(fileSinkEnabled: false, captureBodyPreviews: true, maxBodyPreviewBytes: 8),
            sinks: [CollectingSink()]
        )

        let event = await logger.recordGRPC(
            service: "Catalog",
            method: "List",
            fullMethod: "/Catalog/List",
            statusCode: "0",
            requestMessageBytes: 10,
            responseMessageBytes: 20,
            requestMessagePreview: "req-body-very-long",
            responseMessagePreview: "resp",
            durationMilliseconds: 5
        )

        XCTAssertEqual(event.request.bodyPreview, "req-body")
        XCTAssertEqual(event.response?.bodyPreview, "resp")
        XCTAssertEqual(event.request.messageByteCount, 10)
        XCTAssertEqual(event.response?.messageByteCount, 20)
    }

    func testGRPCRecorderForwardsMessagePreviews() async {
        let logger = SimToolNetworkLogger(
            configuration: NetworkLoggerConfiguration(fileSinkEnabled: false, captureBodyPreviews: true, maxBodyPreviewBytes: 64),
            sinks: [CollectingSink()]
        )

        let recorder = logger.startGRPCCall(
            service: "Sync",
            method: "Refresh",
            fullMethod: "/Sync/Refresh",
            requestMessagePreview: "{request}"
        )
        let event = await recorder.finish(statusCode: "0", responseMessagePreview: "{result}")

        XCTAssertEqual(event.request.bodyPreview, "{request}")
        XCTAssertEqual(event.response?.bodyPreview, "{result}")
    }

    func testGRPCPreviewsOmittedOrDisabledLeaveBodyPreviewUnset() async {
        let enabled = SimToolNetworkLogger(
            configuration: NetworkLoggerConfiguration(fileSinkEnabled: false, captureBodyPreviews: true),
            sinks: [CollectingSink()]
        )
        let withoutPreviews = await enabled.recordGRPC(
            service: "Catalog",
            method: "List",
            statusCode: "0",
            requestMessageBytes: 3,
            durationMilliseconds: 1
        )
        XCTAssertNil(withoutPreviews.request.bodyPreview)
        XCTAssertNil(withoutPreviews.response?.bodyPreview)
        XCTAssertEqual(withoutPreviews.request.messageByteCount, 3)
        XCTAssertEqual(withoutPreviews.response?.grpcStatusCode, "0")

        let disabled = SimToolNetworkLogger(
            configuration: NetworkLoggerConfiguration(fileSinkEnabled: false, captureBodyPreviews: false),
            sinks: [CollectingSink()]
        )
        let dropped = await disabled.recordGRPC(
            service: "Catalog",
            method: "List",
            statusCode: "0",
            requestMessagePreview: "secret",
            responseMessagePreview: "secret",
            durationMilliseconds: 1
        )
        XCTAssertNil(dropped.request.bodyPreview)
        XCTAssertNil(dropped.response?.bodyPreview)
    }

    func testEventAndBatchRoundTripWithAndWithoutProcessIdentity() throws {
        var tagged = makeEvent(id: "e1")
        tagged.pid = 4412
        tagged.launchId = 2
        let batch = NetworkLoggerBatchPayload(events: [tagged], source: "ios-app", pid: 4412)
        let decoded = try NetworkLoggerJSON.decoder.decode(
            NetworkLoggerBatchPayload.self,
            from: try NetworkLoggerJSON.data(batch)
        )
        XCTAssertEqual(decoded.pid, 4412)
        XCTAssertEqual(decoded.events[0].pid, 4412)
        XCTAssertEqual(decoded.events[0].launchId, 2)

        // An event/batch without process identity omits the keys and decodes them as nil.
        let plain = makeEvent(id: "e2")
        let decodedPlain = try NetworkLoggerJSON.decoder.decode(
            NetworkLoggerEvent.self,
            from: try NetworkLoggerJSON.data(plain)
        )
        XCTAssertNil(decodedPlain.pid)
        XCTAssertNil(decodedPlain.launchId)
        let plainBatch = try NetworkLoggerJSON.decoder.decode(
            NetworkLoggerBatchPayload.self,
            from: try NetworkLoggerJSON.data(NetworkLoggerBatchPayload(events: [plain], source: "ios-app"))
        )
        XCTAssertNil(plainBatch.pid)
    }

    func testResolvedArmsFromEnvironmentAndPersistsMarker() {
        let store = InMemoryActivationStore()
        let config = NetworkLoggerConfiguration.resolved(
            environment: ["SIMTOOL_NETWORK_LOGGER": "1", "SIMTOOL_SERVER_URL": "http://127.0.0.1:3311"],
            isSimulator: true,
            activationStore: store
        )
        XCTAssertEqual(config?.serverSinkURL, URL(string: "http://127.0.0.1:3311"))
        XCTAssertEqual(store.saved, NetworkLoggerActivation(enabled: true, serverURL: "http://127.0.0.1:3311"))
    }

    func testResolvedSelfActivatesFromPersistedMarkerWithoutEnvironment() {
        let store = InMemoryActivationStore()
        store.saved = NetworkLoggerActivation(enabled: true, serverURL: "http://127.0.0.1:3311")
        let config = NetworkLoggerConfiguration.resolved(environment: [:], isSimulator: true, activationStore: store)
        XCTAssertEqual(config?.serverSinkURL, URL(string: "http://127.0.0.1:3311"))
    }

    func testResolvedDefaultsServerURLWhenMarkerHasNone() {
        let store = InMemoryActivationStore()
        store.saved = NetworkLoggerActivation(enabled: true, serverURL: nil)
        let config = NetworkLoggerConfiguration.resolved(
            environment: [:],
            isSimulator: true,
            activationStore: store,
            defaultServerURL: URL(string: "http://127.0.0.1:3200")
        )
        XCTAssertEqual(config?.serverSinkURL, URL(string: "http://127.0.0.1:3200"))
    }

    func testResolvedExplicitOptOutWinsOverMarker() {
        let store = InMemoryActivationStore()
        store.saved = NetworkLoggerActivation(enabled: true, serverURL: "http://127.0.0.1:3311")
        XCTAssertNil(NetworkLoggerConfiguration.resolved(
            environment: ["SIMTOOL_NETWORK_LOGGER": "0"],
            isSimulator: true,
            activationStore: store
        ))
    }

    func testResolvedIgnoresMarkerOutsideSimulator() {
        let store = InMemoryActivationStore()
        store.saved = NetworkLoggerActivation(enabled: true, serverURL: "http://127.0.0.1:3311")
        XCTAssertNil(NetworkLoggerConfiguration.resolved(environment: [:], isSimulator: false, activationStore: store))
    }

    func testResolvedRequiresMarkerWhenNoEnvironment() {
        let store = InMemoryActivationStore()
        XCTAssertNil(NetworkLoggerConfiguration.resolved(environment: [:], isSimulator: true, activationStore: store))
    }

    private func makeEvent(
        id: String,
        timestamp: String = "2026-01-01T00:00:00.000Z",
        networkProtocol: NetworkLoggerProtocol = .http
    ) -> NetworkLoggerEvent {
        NetworkLoggerEvent(
            id: id,
            timestamp: timestamp,
            appBundleID: "com.example.app",
            appDisplayName: "Example",
            networkProtocol: networkProtocol,
            durationMilliseconds: 10,
            request: NetworkLoggerRequest(
                method: networkProtocol == .http ? "GET" : nil,
                url: networkProtocol == .http ? "https://example.test" : nil,
                headers: ["Accept": "application/json"],
                grpcService: networkProtocol == .grpc ? "EchoService" : nil,
                grpcMethod: networkProtocol == .grpc ? "Echo" : nil
            ),
            response: NetworkLoggerResponse(statusCode: networkProtocol == .http ? 200 : nil, grpcStatusCode: networkProtocol == .grpc ? "0" : nil)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-network-logger-tests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor CollectingSink: NetworkLoggerSink {
    private var events: [NetworkLoggerEvent] = []

    func record(_ events: [NetworkLoggerEvent]) async {
        self.events.append(contentsOf: events)
    }

    func snapshot() -> [NetworkLoggerEvent] { events }
}

private final class InMemoryActivationStore: NetworkLoggerActivationStore, @unchecked Sendable {
    var saved: NetworkLoggerActivation?
    func load() -> NetworkLoggerActivation? { saved }
    func save(_ activation: NetworkLoggerActivation) { saved = activation }
}
