import Foundation
import SimToolCore
import SimToolNetworkLogger
import SimToolStateLogger

public struct SimToolClient: Sendable {
    public var baseURL: URL

    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func health() async throws -> [String: String] {
        try await getJSON([String: String].self, url: rootURL.appendingPathComponent("health"))
    }

    public func config() async throws -> ServerConfigPayload {
        try await getJSON(ServerConfigPayload.self, url: rootURL.appendingPathComponent("config"))
    }

    public func status() async throws -> ServerStatusPayload {
        try await getJSON(ServerStatusPayload.self, path: "status")
    }

    public func metrics() async throws -> StreamMetricsPayload {
        try await getJSON(StreamMetricsPayload.self, path: "metrics")
    }

    public func devices() async throws -> DeviceListPayload {
        try await getJSON(DeviceListPayload.self, path: "devices")
    }

    public func input(_ payload: SimulatorInputPayload) async throws -> CommandResultPayload {
        try await sendJSON(CommandResultPayload.self, path: "input", payload: payload, method: "POST")
    }

    public func tap(x: Double? = nil, y: Double? = nil, id: String? = nil, label: String? = nil) async throws -> CommandResultPayload {
        try await input(SimulatorInputPayload(action: "tap", x: x, y: y, id: id, label: label))
    }

    public func typeText(_ text: String) async throws -> CommandResultPayload {
        try await input(SimulatorInputPayload(action: "type", text: text))
    }

    public func swipe(startX: Double, startY: Double, endX: Double, endY: Double, duration: Double? = nil) async throws -> CommandResultPayload {
        try await input(SimulatorInputPayload(
            action: "swipe",
            startX: startX,
            startY: startY,
            endX: endX,
            endY: endY,
            duration: duration
        ))
    }

    public func button(_ name: String) async throws -> CommandResultPayload {
        try await input(SimulatorInputPayload(action: "button", name: name))
    }

    public func accessibilityTree() async throws -> AccessibilityTreePayload {
        try await getJSON(AccessibilityTreePayload.self, path: "ax/tree")
    }

    public func accessibilityMatches(query: String) async throws -> AccessibilityFindPayload {
        var components = URLComponents(url: apiURL.appendingPathComponent("ax/find"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return try await getJSON(AccessibilityFindPayload.self, url: components.url!)
    }

    public func logs(lines: Int = 200, seconds: Double = 2, app: String? = nil) async throws -> LogTailPayload {
        var components = URLComponents(url: apiURL.appendingPathComponent("logs"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lines", value: "\(lines)"),
            URLQueryItem(name: "seconds", value: "\(seconds)"),
        ]
        if let app, !app.isEmpty { components.queryItems?.append(URLQueryItem(name: "app", value: app)) }
        return try await getJSON(LogTailPayload.self, url: components.url!)
    }

    public func startLogCapture(device: String? = nil, app: String? = nil, captureStdout: Bool = false) async throws -> LogCaptureStatusPayload {
        try await sendJSON(
            LogCaptureStatusPayload.self,
            path: "logs/capture",
            payload: LogCaptureStartRequest(device: device, app: app, captureStdout: captureStdout),
            method: "POST"
        )
    }

    public func logCaptureEntries(since: Int? = nil, limit: Int = 500) async throws -> LogCaptureEntriesPayload {
        var components = URLComponents(url: apiURL.appendingPathComponent("logs/capture"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let since { queryItems.append(URLQueryItem(name: "since", value: "\(since)")) }
        components.queryItems = queryItems
        return try await getJSON(LogCaptureEntriesPayload.self, url: components.url!)
    }

    public func launches() async throws -> AppLaunchesPayload {
        try await getJSON(AppLaunchesPayload.self, path: "launches")
    }

    public func startTestSession(title: String) async throws -> TestSession {
        try await sendJSON(TestSession.self, path: "tests/start", payload: TestSessionStartRequest(title: title), method: "POST")
    }

    public func appendTestSessionEntry(_ entry: TestSessionEntryRequest) async throws -> TestSession {
        try await sendJSON(TestSession.self, path: "tests/entries", payload: entry, method: "POST")
    }

    public func stopTestSession(status: TestSessionStatus) async throws -> TestSession {
        try await sendJSON(TestSession.self, path: "tests/stop", payload: TestSessionStopRequest(status: status), method: "POST")
    }

    public func testSessions() async throws -> TestSessionListPayload {
        try await getJSON(TestSessionListPayload.self, path: "tests")
    }

    @discardableResult
    public func stopLogCapture() async throws -> LogCaptureStatusPayload {
        try await sendJSON(
            LogCaptureStatusPayload.self,
            path: "logs/capture/stop",
            payload: LogCaptureStartRequest(),
            method: "POST"
        )
    }

    public func network(seconds: Double = 2, limit: Int = 200) async throws -> NetworkSnapshotPayload {
        var components = URLComponents(url: apiURL.appendingPathComponent("network"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "seconds", value: "\(seconds)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        return try await getJSON(NetworkSnapshotPayload.self, url: components.url!)
    }

    public func networkLoggerEvents(
        app: String? = nil,
        networkProtocol: NetworkLoggerProtocol? = nil,
        since: String? = nil,
        limit: Int = 200
    ) async throws -> NetworkLoggerEventsPayload {
        var components = URLComponents(url: apiURL.appendingPathComponent("network/events"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let app, !app.isEmpty { queryItems.append(URLQueryItem(name: "app", value: app)) }
        if let networkProtocol { queryItems.append(URLQueryItem(name: "protocol", value: networkProtocol.rawValue)) }
        if let since, !since.isEmpty { queryItems.append(URLQueryItem(name: "since", value: since)) }
        components.queryItems = queryItems
        return try await getJSON(NetworkLoggerEventsPayload.self, url: components.url!)
    }

    public func ingestNetworkLoggerEvents(_ batch: NetworkLoggerBatchPayload) async throws -> NetworkLoggerIngestionResponse {
        try await sendJSON(NetworkLoggerIngestionResponse.self, path: "network/events", payload: batch, method: "POST")
    }

    public func stateLoggerEvents(since: Int? = nil, limit: Int = 500) async throws -> StateLoggerEventsPayload {
        var components = URLComponents(url: apiURL.appendingPathComponent("state/events"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let since { queryItems.append(URLQueryItem(name: "since", value: "\(since)")) }
        components.queryItems = queryItems
        return try await getJSON(StateLoggerEventsPayload.self, url: components.url!)
    }

    public func ingestStateLoggerEvents(_ batch: StateLoggerBatchPayload) async throws -> StateLoggerIngestionResponse {
        try await sendJSON(StateLoggerIngestionResponse.self, path: "state/events", payload: batch, method: "POST")
    }

    public func screenshot() async throws -> Data {
        let request = makeRequest(url: apiURL.appendingPathComponent("screenshot"), method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    public var rootURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        if components.path.hasSuffix("/api/v1") {
            components.path.removeLast("/api/v1".count)
            if components.path.isEmpty { components.path = "/" }
        }
        return components.url!
    }

    public var apiURL: URL {
        if baseURL.path.hasSuffix("/api/v1") { return baseURL }
        return rootURL.appendingPathComponent("api/v1")
    }

    private func getJSON<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        try await getJSON(type, url: apiURL.appendingPathComponent(path))
    }

    private func getJSON<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let request = makeRequest(url: url, method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSON.decoder.decode(T.self, from: data)
    }

    private func sendJSON<T: Decodable, Body: Encodable>(
        _ type: T.Type,
        path: String,
        payload: Body,
        method: String
    ) async throws -> T {
        var request = makeRequest(url: apiURL.appendingPathComponent(path), method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSON.data(payload, pretty: false)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSON.decoder.decode(T.self, from: data)
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSON.decoder.decode(SimToolErrorPayload.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw SimToolClientError(statusCode: response.statusCode, message: message)
        }
    }
}

public struct SimToolClientError: Error, LocalizedError, Equatable, Sendable {
    public var statusCode: Int
    public var message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? { message }
}

private struct SimToolErrorPayload: Decodable {
    var error: String
}
