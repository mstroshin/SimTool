import CoreMedia
import CoreVideo
import Foundation
import SimToolCore
import SimToolNetworkLogger
import SimToolStateLogger
import SimToolStream
import SimToolWeb
import Swifter

public struct StreamServerConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var device: SimulatorDevice
    public var captureEnabled: Bool
    /// When set, log capture defaults to this app (and stdout/print capture) so the
    /// viewers scope to the app's own logs instead of flooding with system OSLog.
    public var defaultLogApp: String?
    /// Where test sessions persist: the project's `.simtool/test-sessions`.
    public var testSessionsRoot: URL
    /// Where declarative YAML UI tests live: the project’s `.simtool/tests`.
    public var testsRoot: URL

    public init(
        host: String = "127.0.0.1",
        port: UInt16,
        device: SimulatorDevice,
        captureEnabled: Bool = true,
        defaultLogApp: String? = nil,
        testSessionsRoot: URL = SimToolDirectory.testSessionsDirectory(in: SimToolDirectory.resolve()),
        testsRoot: URL = SimToolDirectory.testsDirectory(in: SimToolDirectory.resolve())
    ) {
        self.host = host
        self.port = port
        self.device = device
        self.captureEnabled = captureEnabled
        self.defaultLogApp = defaultLogApp
        self.testSessionsRoot = testSessionsRoot
        self.testsRoot = testsRoot
    }
}

public final class StreamServer: @unchecked Sendable {
    public let config: StreamServerConfig

    private let server = HttpServer()
    private let clientManager = ClientManager()
    private let frameCapture = FrameCapture()
    private let h264Encoder = H264Encoder(fps: 60)
    private let directInput = SimulatorDirectInputClient.shared
    private let metrics = StreamMetricsStore()
    private let networkLoggerEvents = NetworkLoggerEventStore(capacity: 1_000)
    private let mockRules = MockRuleRegistry()
    private let stateLoggerEvents = StateLoggerEventStore()
    private let logEntries = LogEntryStore(capacity: 5_000)
    /// App launches detected for the inspected app, shared by the log and network ingest paths and
    /// retained for the server's lifetime so entries stay attributable across relaunches.
    private let launches = AppLaunchRegistry()
    /// Agent test sessions: timeline + screen recording, persisted on disk.
    private let testSessions: TestSessionController
    private let testRuns: TestRunController
    /// OSLog category that, by convention, carries a crash summary of the previous run (apps can
    /// only write it after relaunching - crash handlers cannot safely log at crash time).
    private static let crashReportCategory = "Crash"
    /// Formats state-event epoch timestamps for AppLaunchRegistry, which keys
    /// launches by ISO8601 strings (the network logger sends them pre-formatted).
    private static let stateTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let logLock = NSLock()
    private var logCapture: SimulatorLogCapture?
    private var logCaptureInfo: (device: String, app: String?, captureStdout: Bool)?
    private var logLastPollAt = Date()
    private var logIdleTask: Task<Void, Never>?
    private let logIdleTimeout: TimeInterval = 60
    private let h264Queue = DispatchQueue(label: "simtool.encode.h264", qos: .userInteractive)
    private let stateLock = NSLock()
    private var h264Encoding = false
    private var h264Broadcasting = false
    private var forceKeyframe = false
    private var screenWidth = 0
    private var screenHeight = 0
    private var started = false

    public init(config: StreamServerConfig) {
        self.config = config
        self.testSessions = TestSessionController(
            store: TestSessionStore(root: config.testSessionsRoot),
            device: config.device,
            makeRecorder: { SimctlVideoRecorder() }
        )
        self.testRuns = TestRunController(testsRoot: config.testsRoot)
    }

    public func start() throws {
        guard !started else { return }
        started = true
        installRoutes()
        wireEncoders()
        try server.start(config.port, forceIPv4: true, priority: .userInteractive)
        if config.captureEnabled {
            try frameCapture.start(deviceUDID: config.device.udid, onFrame: frameHandler)
        }
    }

    public func stop() {
        shutdownTestSessions()
        stopLogCapture()
        frameCapture.stop()
        h264Encoder.stop()
        clientManager.closeAll()
        server.stop()
        started = false
    }

    public var baseURL: String { "http://\(config.host):\(config.port)" }
    public var apiURL: String { "\(baseURL)/api/v1" }

    private func installRoutes() {
        server.middleware.append { request in
            guard request.method == "OPTIONS" else { return nil }
            return self.emptyResponse(statusCode: 204, reason: "No Content")
        }

        server["/"] = { _ in
            .ok(.html(WebViewer.html()))
        }

        server["/health"] = { _ in
            self.jsonResponse(["status": "ok"])
        }

        server["/config"] = { _ in
            do { return try self.jsonEncodedResponse(self.configPayload()) }
            catch { return self.errorResponse(error) }
        }

        server["/api/v1/status"] = { _ in
            do { return try self.jsonEncodedResponse(self.statusPayload()) }
            catch { return self.errorResponse(error) }
        }

        server.GET["/api/v1/metrics"] = { _ in
            do { return try self.jsonEncodedResponse(self.metricsPayload()) }
            catch { return self.errorResponse(error) }
        }

        server.GET["/api/v1/devices"] = { _ in
            self.asyncJSONResponse {
                let devices = try await SimulatorDeviceClient.listDevices()
                return DeviceListPayload(devices: devices, selected: self.config.device.udid)
            }
        }

        server.POST["/api/v1/input"] = { request in self.handleInput(request) }

        server.GET["/api/v1/ax/tree"] = { request in
            let includeRaw = request.queryFlag("raw")
            if request.queryValue("format")?.lowercased() == "flat" {
                let labeledOnly = request.queryFlag("labeled")
                return self.asyncJSONResponse {
                    SimulatorAccessibilityClient.flatten(
                        try await SimulatorAccessibilityClient.normalizedTree(deviceUDID: self.config.device.udid),
                        labeledOnly: labeledOnly
                    )
                }
            }
            return self.asyncJSONResponse {
                try await SimulatorAccessibilityClient.normalizedTree(deviceUDID: self.config.device.udid, includeRaw: includeRaw)
            }
        }

        server.GET["/api/v1/ax/raw"] = { _ in
            do {
                let data = try self.waitForAsync {
                    try await SimulatorAccessibilityClient.tree(deviceUDID: self.config.device.udid)
                }
                return self.dataResponse(data, contentType: "application/json")
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/ax/find"] = { request in
            guard let needle = request.queryValue("q") ?? request.queryValue("needle"), !needle.isEmpty else {
                return self.errorResponse(SimToolError("Missing q query parameter"), statusCode: 400, reason: "Bad Request")
            }
            let includeRaw = request.queryFlag("raw")
            return self.asyncJSONResponse {
                try await SimulatorAccessibilityClient.findNodes(needle: needle, deviceUDID: self.config.device.udid, includeRaw: includeRaw)
            }
        }

        server.GET["/api/v1/logs"] = { request in
            let lines = request.queryInt("lines") ?? 200
            let seconds = request.queryDouble("seconds") ?? 2
            let app = request.queryValue("app")
            return self.asyncJSONResponse {
                let payload = try await SimulatorLogsClient.tail(
                    deviceUDID: self.config.device.udid,
                    app: app,
                    lines: lines,
                    seconds: seconds
                )
                return LogTailPayload(lines: payload)
            }
        }

        server.GET["/api/v1/network"] = { request in
            let seconds = request.queryDouble("seconds") ?? 2
            let limit = request.queryInt("limit") ?? 200
            return self.asyncJSONResponse {
                try await SimulatorNetworkClient.snapshot(
                    deviceUDID: self.config.device.udid,
                    seconds: seconds,
                    limit: limit
                )
            }
        }

        server.POST["/api/v1/network/events"] = { request in
            self.handleNetworkLoggerIngestion(request)
        }

        server.GET["/api/v1/network/events"] = { request in
            do {
                let filter = try self.networkLoggerFilter(from: request)
                return try self.jsonEncodedResponse(self.networkLoggerEvents.query(filter: filter))
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }

        server.POST["/api/v1/mocks"] = { request in
            do {
                let draft = try self.decodeJSON(MockRuleDraft.self, from: request)
                return try self.jsonEncodedResponse(self.mockRules.add(draft))
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }

        server.GET["/api/v1/mocks"] = { request in
            do {
                return try self.jsonEncodedResponse(self.mockRules.list(since: request.queryInt("since")))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.DELETE["/api/v1/mocks/:id"] = { request in
            guard let id = request.params[":id"], !id.isEmpty else {
                return self.errorResponse(SimToolError("Missing mock id"), statusCode: 400, reason: "Bad Request")
            }
            let removed = self.mockRules.remove(id: id)
            return self.jsonResponse(["ok": true, "removed": removed ? 1 : 0])
        }

        server.DELETE["/api/v1/mocks"] = { _ in
            let removed = self.mockRules.clear()
            return self.jsonResponse(["ok": true, "removed": removed])
        }

        server.DELETE["/api/v1/network/launches/:launchId"] = { request in
            guard let raw = request.params[":launchId"], let launchId = Int(raw) else {
                return self.errorResponse(SimToolError("Missing launch id"), statusCode: 400, reason: "Bad Request")
            }
            let removed = self.networkLoggerEvents.deleteEvents(launchId: launchId)
            return self.jsonResponse(["ok": true, "removed": removed])
        }

        server.DELETE["/api/v1/logs/launches/:launchId"] = { request in
            guard let raw = request.params[":launchId"], let launchId = Int(raw) else {
                return self.errorResponse(SimToolError("Missing launch id"), statusCode: 400, reason: "Bad Request")
            }
            let removed = self.logEntries.deleteEntries(launchId: launchId)
            return self.jsonResponse(["ok": true, "removed": removed])
        }

        server.POST["/api/v1/state/events"] = { request in
            self.handleStateLoggerIngestion(request)
        }

        server.GET["/api/v1/state/events"] = { request in
            let since = request.queryInt("since")
            let limit = request.queryInt("limit") ?? 500
            do {
                return try self.jsonEncodedResponse(self.stateLoggerEvents.query(since: since, limit: limit))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.POST["/api/v1/logs/capture"] = { request in
            do {
                let start = (try? self.decodeJSON(LogCaptureStartRequest.self, from: request)) ?? LogCaptureStartRequest()
                return try self.jsonEncodedResponse(try self.startLogCapture(start))
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }

        server.GET["/api/v1/logs/capture"] = { request in
            let since = request.queryInt("since")
            let limit = request.queryInt("limit") ?? 500
            do {
                return try self.jsonEncodedResponse(self.logCaptureEntries(since: since, limit: limit))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.POST["/api/v1/logs/capture/stop"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.stopLogCapture())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/launches"] = { _ in
            do {
                return try self.jsonEncodedResponse(AppLaunchesPayload(launches: self.launches.snapshot()))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.POST["/api/v1/tests/start"] = { request in
            do {
                let start = try self.decodeJSON(TestSessionStartRequest.self, from: request)
                return try self.jsonEncodedResponse(self.testSessions.start(title: start.title, video: start.video ?? true))
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.POST["/api/v1/tests/entries"] = { request in
            do {
                let entry = try self.decodeJSON(TestSessionEntryRequest.self, from: request)
                return try self.jsonEncodedResponse(self.testSessions.append(entry))
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.POST["/api/v1/tests/stop"] = { request in
            do {
                let stop = try self.decodeJSON(TestSessionStopRequest.self, from: request)
                let session = try self.waitForAsync { try await self.testSessions.stop(status: stop.status) }
                return try self.jsonEncodedResponse(session)
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.GET["/api/v1/tests"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.testSessions.list())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/tests/definitions"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.testRuns.list())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.GET["/api/v1/tests/run"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.testRuns.status())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.POST["/api/v1/tests/run"] = { request in
            do {
                let body = try self.decodeJSON(TestRunRequest.self, from: request)
                guard let serverURL = URL(string: self.baseURL) else {
                    return self.errorResponse(SimToolError("Cannot resolve own base URL"))
                }
                let status = try self.testRuns.start(file: body.file, serverURL: serverURL, video: body.video ?? true)
                return try self.jsonEncodedResponse(status)
            } catch {
                return self.errorResponse(error, statusCode: 409, reason: "Conflict")
            }
        }

        server.POST["/api/v1/tests/run/stop"] = { _ in
            do {
                return try self.jsonEncodedResponse(self.testRuns.stop())
            } catch {
                return self.errorResponse(error)
            }
        }

        server.DELETE["/api/v1/tests/:id"] = { request in
            guard let id = request.params[":id"], !id.isEmpty else {
                return self.errorResponse(SimToolError("Missing session id"), statusCode: 400, reason: "Bad Request")
            }
            do {
                try self.testSessions.delete(id: id)
                return self.jsonResponse(["ok": true])
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.GET["/api/v1/tests/:id/video"] = { request in
            guard let id = request.params[":id"], !id.isEmpty else {
                return self.errorResponse(SimToolError("Missing session id"), statusCode: 400, reason: "Bad Request")
            }
            do {
                let file = try self.testSessions.videoFile(id: id)
                return self.videoFileResponse(file, rangeHeader: request.headers["range"])
            } catch {
                return self.testSessionErrorResponse(error)
            }
        }

        server.GET["/api/v1/screenshot"] = { request in
            let maxDimension = request.queryInt("maxDim")
            if let maxDimension, maxDimension <= 0 {
                return self.errorResponse(SimToolError("maxDim must be positive"), statusCode: 400, reason: "Bad Request")
            }
            do {
                let data = try self.waitForAsync {
                    try await SimulatorScreenshotClient.png(deviceUDID: self.config.device.udid, maxDimension: maxDimension)
                }
                return self.dataResponse(data, contentType: "image/png")
            } catch {
                return self.errorResponse(error)
            }
        }

        server["/stream.avcc"] = { _ in
            let client = self.clientManager.addAvccClient()
            return .raw(200, "OK", [
                "Content-Type": "application/octet-stream",
                "Cache-Control": "no-cache, no-store",
                "Connection": "keep-alive",
                "Access-Control-Allow-Origin": "*",
            ]) { writer in
                let semaphore = DispatchSemaphore(value: 0)
                client.setWriter { data in
                    do {
                        try writer.write(data)
                        return true
                    } catch {
                        semaphore.signal()
                        return false
                    }
                }
                self.clientManager.sendInitialAvcc(to: client)
                semaphore.wait()
                self.clientManager.removeAvccClient(client)
            }
        }
    }

    private func configPayload() -> ServerConfigPayload {
        ServerConfigPayload(
            device: config.device.name,
            udid: config.device.udid,
            width: screenWidth,
            height: screenHeight,
            stream: StreamPaths(),
            metrics: metricsPayload(),
            logApp: config.defaultLogApp
        )
    }

    private func statusPayload() -> ServerStatusPayload {
        ServerStatusPayload(
            device: config.device.name,
            udid: config.device.udid,
            width: screenWidth,
            height: screenHeight,
            healthy: true,
            metrics: metricsPayload()
        )
    }

    private func metricsPayload() -> StreamMetricsPayload {
        metrics.snapshot(clients: clientManager.clientCounts())
    }

    private func handleInput(_ request: HttpRequest) -> HttpResponse {
        do {
            let input = try decodeJSON(SimulatorInputPayload.self, from: request)
            let action = (input.action ?? input.type ?? "").lowercased()
            // Stamped before the gesture so a step entry lands on the frame
            // just before its action; failed inputs never reach noteInput.
            let startedAt = Date()
            let output = try waitForAsync { try await self.perform(input: input, action: action) }
            testSessions.noteInput(at: startedAt)
            return try jsonEncodedResponse(CommandResultPayload(
                ok: true,
                stdout: output.stdoutString,
                stderr: output.stderrString
            ))
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    private func handleNetworkLoggerIngestion(_ request: HttpRequest) -> HttpResponse {
        do {
            let batch = try decodeJSON(NetworkLoggerBatchPayload.self, from: request)
            return try jsonEncodedResponse(networkLoggerEvents.ingest(taggedWithLaunch(batch)))
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// Attributes an ingested batch to an app launch using its process id, stamping each event with
    /// the resolved `launchId`. Batches without a `pid` (older app builds) are stored untagged.
    private func taggedWithLaunch(_ batch: NetworkLoggerBatchPayload) -> [NetworkLoggerEvent] {
        guard let pid = batch.pid, !batch.events.isEmpty else { return batch.events }
        let timestamp = batch.events.map(\.timestamp).min() ?? batch.events[0].timestamp
        let launchId = launches.observe(pid: pid, app: batch.events.first?.appBundleID, timestamp: timestamp)
        return batch.events.map { event in
            var event = event
            event.pid = event.pid ?? pid
            event.launchId = launchId
            return event
        }
    }

    private func handleStateLoggerIngestion(_ request: HttpRequest) -> HttpResponse {
        do {
            let batch = try decodeJSON(StateLoggerBatchPayload.self, from: request)
            return try jsonEncodedResponse(stateLoggerEvents.ingest(stateEventsTaggedWithLaunch(batch)))
        } catch {
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        }
    }

    /// Mirrors `taggedWithLaunch(_:)` for state events: attributes a batch to an app
    /// launch by its pid and stamps each event with the resolved `launchId`.
    private func stateEventsTaggedWithLaunch(_ batch: StateLoggerBatchPayload) -> [StateLoggerEvent] {
        guard let pid = batch.pid, !batch.events.isEmpty else { return batch.events }
        let earliest = batch.events.map(\.timestamp).min() ?? batch.events[0].timestamp
        let timestamp = Self.stateTimestampFormatter.string(from: Date(timeIntervalSince1970: earliest))
        let launchId = launches.observe(pid: pid, timestamp: timestamp)
        return batch.events.map { event in
            var event = event
            event.pid = event.pid ?? pid
            event.launchId = launchId
            return event
        }
    }

    private func networkLoggerFilter(from request: HttpRequest) throws -> NetworkLoggerEventFilter {
        let networkProtocol: NetworkLoggerProtocol?
        if let rawProtocol = request.queryValue("protocol"), !rawProtocol.isEmpty {
            guard let parsed = NetworkLoggerProtocol(rawValue: rawProtocol.lowercased()) else {
                throw SimToolError("Unsupported network logger protocol: \(rawProtocol)")
            }
            networkProtocol = parsed
        } else {
            networkProtocol = nil
        }
        return NetworkLoggerEventFilter(
            app: request.queryValue("app"),
            networkProtocol: networkProtocol,
            since: request.queryValue("since"),
            limit: request.queryInt("limit") ?? 200
        )
    }

    private func startLogCapture(_ request: LogCaptureStartRequest) throws -> LogCaptureStatusPayload {
        let device = request.device.flatMap { $0.isEmpty ? nil : $0 } ?? config.device.udid
        // Scope to the server's configured app and capture its stdout/print plus OSLog. Starting
        // capture relaunches the app once (`--console-pty`); the idempotent + server-owned logic
        // below ensures reopening the viewer never relaunches it again.
        let app = request.app.flatMap { $0.isEmpty ? nil : $0 } ?? config.defaultLogApp
        let captureStdout = request.captureStdout ?? (app != nil)
        if captureStdout && app == nil {
            throw SimToolError("Capturing stdout/print requires an app bundle identifier")
        }

        logLock.lock()
        // Idempotent: identical parameters reuse the running capture.
        if let info = logCaptureInfo, logCapture != nil,
           info.device == device, info.app == app, info.captureStdout == captureStdout {
            logLastPollAt = Date()
            logLock.unlock()
            return currentLogStatus()
        }
        // Different parameters: last-writer-wins restart.
        logCapture?.stop()
        logCapture = nil
        logCaptureInfo = nil
        logEntries.clear()

        let capture = SimulatorLogCapture(
            options: SimulatorLogCapture.Options(deviceUDID: device, app: app, captureStdout: captureStdout, bundleID: app)
        ) { [weak self] draft in
            guard let self else { return }
            // OSLog lines carry a process id, so they drive launch detection; stdout/print has no
            // per-line pid and adopts the current launch.
            var launchId: Int?
            if let pid = draft.pid {
                launchId = self.launches.observe(pid: pid, app: app, timestamp: draft.timestamp)
                // Crash summaries are logged by the launch that follows the crash but describe
                // the previous one - file them under the launch that actually crashed.
                if draft.category == Self.crashReportCategory,
                   let current = launchId,
                   let crashed = self.launches.launchId(preceding: current) {
                    launchId = crashed
                }
            } else {
                launchId = self.launches.currentLaunchId()
            }
            self.logEntries.append(draft, launchId: launchId)
        }
        do {
            try capture.start()
        } catch {
            logLock.unlock()
            throw error
        }
        logCapture = capture
        logCaptureInfo = (device, app, captureStdout)
        logLastPollAt = Date()
        startLogIdleWatchLocked()
        logLock.unlock()
        return currentLogStatus()
    }

    private func logCaptureEntries(since: Int?, limit: Int) throws -> LogCaptureEntriesPayload {
        logLock.lock()
        logLastPollAt = Date()
        logLock.unlock()
        return logEntries.query(since: since, limit: limit)
    }

    @discardableResult
    private func stopLogCapture() -> LogCaptureStatusPayload {
        logLock.lock()
        logCapture?.stop()
        logCapture = nil
        logCaptureInfo = nil
        logIdleTask?.cancel()
        logIdleTask = nil
        logLock.unlock()
        return currentLogStatus()
    }

    /// Caller must hold `logLock`.
    private func startLogIdleWatchLocked() {
        logIdleTask?.cancel()
        // The server-owned capture for the configured default app is never idle-reaped: it lives
        // for the server's lifetime, so reopening the viewer reuses it without relaunching the app.
        // Only ad-hoc captures (a different app) are torn down on idle.
        if let app = logCaptureInfo?.app, app == config.defaultLogApp {
            logIdleTask = nil
            return
        }
        let timeout = logIdleTimeout
        logIdleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                let snapshot = self.logIdleSnapshot()
                guard snapshot.active else { return }
                if snapshot.idle > timeout {
                    self.stopLogCapture()
                    return
                }
            }
        }
    }

    private func logIdleSnapshot() -> (active: Bool, idle: TimeInterval) {
        logLock.lock()
        defer { logLock.unlock() }
        return (logCapture != nil, Date().timeIntervalSince(logLastPollAt))
    }

    private func currentLogStatus() -> LogCaptureStatusPayload {
        logLock.lock()
        let info = logCaptureInfo
        logLock.unlock()
        return LogCaptureStatusPayload(
            active: info != nil,
            device: info?.device,
            app: info?.app,
            captureStdout: info?.captureStdout ?? false,
            droppedCount: logEntries.droppedCount()
        )
    }

    private func perform(input: SimulatorInputPayload, action: String) async throws -> ProcessOutput {
        switch action {
        case "tap":
            if (input.x == nil) != (input.y == nil) {
                throw SimToolError("Tap requires both x and y when using coordinates")
            }
            if input.coordinateSpace?.lowercased() == "pixels" {
                guard let inputX = input.x,
                      let inputY = input.y,
                      let sourceWidth = input.sourceWidth,
                      let sourceHeight = input.sourceHeight,
                      sourceWidth > 0,
                      sourceHeight > 0 else {
                    throw SimToolError("Pixel tap requires x, y, sourceWidth, and sourceHeight")
                }
                try await directInput.tap(
                    xRatio: ratio(inputX, in: sourceWidth),
                    yRatio: ratio(inputY, in: sourceHeight),
                    deviceUDID: config.device.udid
                )
                return ProcessOutput(status: 0)
            }
            return try await SimulatorInputClient.tap(
                deviceUDID: config.device.udid,
                x: input.x,
                y: input.y,
                id: input.id,
                label: input.label
            )
        case "longpress", "long-press":
            if (input.x == nil) != (input.y == nil) {
                throw SimToolError("Long press requires both x and y when using coordinates")
            }
            return try await SimulatorInputClient.longPress(
                deviceUDID: config.device.udid,
                x: input.x,
                y: input.y,
                id: input.id,
                label: input.label,
                duration: input.duration ?? 1.0
            )
        case "type", "typetext", "text":
            guard let text = input.text else { throw SimToolError("Type input requires text") }
            return try await SimulatorInputClient.typeText(text, deviceUDID: config.device.udid)
        case "swipe":
            guard let startX = input.startX,
                  let startY = input.startY,
                  let endX = input.endX,
                  let endY = input.endY else {
                throw SimToolError("Swipe requires startX, startY, endX, and endY")
            }
            if input.coordinateSpace?.lowercased() == "pixels" {
                guard let sourceWidth = input.sourceWidth,
                      let sourceHeight = input.sourceHeight,
                      sourceWidth > 0,
                      sourceHeight > 0 else {
                    throw SimToolError("Pixel swipe requires sourceWidth and sourceHeight")
                }
                try await directInput.swipe(
                    startXRatio: ratio(startX, in: sourceWidth),
                    startYRatio: ratio(startY, in: sourceHeight),
                    endXRatio: ratio(endX, in: sourceWidth),
                    endYRatio: ratio(endY, in: sourceHeight),
                    duration: input.duration,
                    deviceUDID: config.device.udid
                )
                return ProcessOutput(status: 0)
            }
            return try await SimulatorInputClient.swipe(
                deviceUDID: config.device.udid,
                startX: startX,
                startY: startY,
                endX: endX,
                endY: endY,
                duration: input.duration
            )
        case "shake":
            // Same darwin notification Simulator.app's Device > Shake menu posts;
            // UIKit in the simulated OS turns it into motionEnded(.motionShake).
            return try await ProcessRunner.runXcrun(["simctl", "spawn", config.device.udid, "notifyutil", "-p", "com.apple.UIKit.SimulatorShake"])
        case "terminate":
            // Kills the app outright (same as `simctl terminate`), so the next launch is cold.
            guard let bundleId = input.name.flatMap({ $0.isEmpty ? nil : $0 }) ?? config.defaultLogApp else {
                throw SimToolError("Terminate requires an app bundle id: start the server with --app or pass name")
            }
            return try await ProcessRunner.runXcrun(["simctl", "terminate", config.device.udid, bundleId])
        case "launch", "relaunch":
            // Relaunches through simctl so the app inherits the server's SIMCTL_CHILD_*
            // environment and the state/network loggers re-arm; an icon-tap launch in the
            // Simulator loses that environment and those tabs go silent.
            guard let bundleId = input.name.flatMap({ $0.isEmpty ? nil : $0 }) ?? config.defaultLogApp else {
                throw SimToolError("Launch requires an app bundle id: start the server with --app or pass name")
            }
            return try await ProcessRunner.runXcrun(["simctl", "launch", "--terminate-running-process", config.device.udid, bundleId])
        case "button":
            guard let name = input.name else { throw SimToolError("Button input requires name") }
            if name.lowercased() == "home" {
                return try await ProcessRunner.runXcrun(["simctl", "launch", config.device.udid, "com.apple.springboard"])
            }
            return try await SimulatorInputClient.button(name, deviceUDID: config.device.udid)
        default:
            throw SimToolError("Unsupported input action: \(action.isEmpty ? "<missing>" : action)")
        }
    }

    private func ratio(_ value: Double, in size: Double) -> Double {
        return max(0, min(1, value / size))
    }

    private func wireEncoders() {
        h264Encoder.onEncoded = { [weak self] encoded in
            guard let self else { return }
            if let description = encoded.description {
                self.clientManager.broadcastAvcc(AVCCEnvelope.description(avcc: description), isDescription: true) { sent in
                    self.metrics.recordAVCCDescription(sent: sent)
                }
            }
            // Keep the TCP stream current: if the previous write is still blocking,
            // skip the next source frame before encode instead of queuing stale P-frames.
            self.stateLock.lock()
            self.h264Broadcasting = true
            self.stateLock.unlock()
            switch encoded.kind {
            case .keyframe:
                self.clientManager.broadcastAvcc(AVCCEnvelope.keyframe(avcc: encoded.avcc)) { sent in
                    self.metrics.recordH264Encoded(kind: .keyframe, sent: sent)
                    self.stateLock.lock(); self.h264Broadcasting = false; self.stateLock.unlock()
                }
            case .delta:
                self.clientManager.broadcastAvcc(AVCCEnvelope.delta(avcc: encoded.avcc)) { sent in
                    self.metrics.recordH264Encoded(kind: .delta, sent: sent)
                    self.stateLock.lock(); self.h264Broadcasting = false; self.stateLock.unlock()
                }
            }
        }
        clientManager.onAvccClientConnect = { [weak self] in
            self?.requestKeyframe()
        }
    }

    private func requestKeyframe() {
        h264Queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.forceKeyframe = true
            self.stateLock.unlock()
        }
    }

    private func frameHandler(pixelBuffer: CVPixelBuffer, timestamp _: CMTime) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        metrics.recordCapturedFrame()
        stateLock.lock()
        screenWidth = width
        screenHeight = height
        let hasAvcc = clientManager.hasAvccClients()
        stateLock.unlock()

        guard hasAvcc else { return }
        h264Queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            if self.h264Encoding || self.h264Broadcasting {
                self.stateLock.unlock()
                self.metrics.recordDroppedH264Frame()
                return
            }
            self.h264Encoding = true
            let force = self.forceKeyframe
            self.forceKeyframe = false
            self.stateLock.unlock()
            self.h264Encoder.encode(pixelBuffer, forceKeyframe: force) {
                self.h264Queue.async {
                    self.stateLock.lock(); self.h264Encoding = false; self.stateLock.unlock()
                }
            }
        }
    }

    private func asyncJSONResponse<T: Encodable>(_ operation: @escaping @Sendable () async throws -> T) -> HttpResponse {
        do {
            return try jsonEncodedResponse(waitForAsync(operation))
        } catch {
            return errorResponse(error)
        }
    }

    private func waitForAsync<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    private func shutdownTestSessions() {
        let semaphore = DispatchSemaphore(value: 0)
        let controller = testSessions
        Task {
            await controller.shutdown()
            semaphore.signal()
        }
        // Bounded: stop() can run from a signal handler; a hung recorder must
        // delay exit, not deadlock it.
        _ = semaphore.wait(timeout: .now() + .seconds(8))
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from request: HttpRequest) throws -> T {
        let data = Data(request.body)
        guard !data.isEmpty else { throw SimToolError("Request body must be JSON") }
        return try JSON.decoder.decode(type, from: data)
    }

    private func jsonEncodedResponse<T: Encodable>(_ value: T, statusCode: Int = 200, reason: String = "OK") throws -> HttpResponse {
        let data = try JSON.data(value, pretty: false)
        return dataResponse(data, contentType: "application/json", statusCode: statusCode, reason: reason)
    }

    private func jsonResponse(_ object: [String: Any], statusCode: Int = 200, reason: String = "OK") -> HttpResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return .internalServerError
        }
        return dataResponse(data, contentType: "application/json", statusCode: statusCode, reason: reason)
    }

    private func errorResponse(_ error: Error, statusCode: Int = 500, reason: String = "Internal Server Error") -> HttpResponse {
        jsonResponse(["error": error.localizedDescription], statusCode: statusCode, reason: reason)
    }

    private func testSessionErrorResponse(_ error: Error) -> HttpResponse {
        switch error {
        case TestSessionError.alreadyActive, TestSessionError.noActiveSession, TestSessionError.videoNotReady,
             TestSessionError.sessionRunning:
            return errorResponse(error, statusCode: 409, reason: "Conflict")
        case TestSessionError.sessionNotFound, TestSessionError.videoMissing:
            return errorResponse(error, statusCode: 404, reason: "Not Found")
        case TestSessionError.emptyEntry, TestSessionError.entryTooLarge, TestSessionError.badStatus,
             is DecodingError, is SimToolError:
            // Validation and decode failures are the client's fault.
            return errorResponse(error, statusCode: 400, reason: "Bad Request")
        default:
            // Anything else (store I/O) is a server-side failure.
            return errorResponse(error)
        }
    }

    private func videoFileResponse(_ url: URL, rangeHeader: String?) -> HttpResponse {
        guard let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue else {
            return errorResponse(SimToolError("Video file unreadable"), statusCode: 404, reason: "Not Found")
        }
        var headers = [
            "Content-Type": "video/mp4",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache, no-store",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        ]
        switch HTTPRange.parse(header: rangeHeader, fileSize: size) {
        case .unsatisfiable:
            headers["Content-Range"] = "bytes */\(size)"
            headers["Content-Length"] = "0"
            return .raw(416, "Range Not Satisfiable", headers, nil)
        case let .partial(range):
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return errorResponse(SimToolError("Video file unreadable"), statusCode: 404, reason: "Not Found")
            }
            headers["Content-Range"] = "bytes \(range.offset)-\(range.offset + range.length - 1)/\(size)"
            headers["Content-Length"] = "\(range.length)"
            return .raw(206, "Partial Content", headers) { writer in
                Self.streamFile(handle, offset: range.offset, length: range.length, to: writer)
            }
        case .full:
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return errorResponse(SimToolError("Video file unreadable"), statusCode: 404, reason: "Not Found")
            }
            headers["Content-Length"] = "\(size)"
            return .raw(200, "OK", headers) { writer in
                Self.streamFile(handle, offset: 0, length: size, to: writer)
            }
        }
    }

    /// Streams `length` bytes from `offset` in bounded chunks so a long
    /// recording never has to fit in memory. Closes the handle when done.
    private static func streamFile(_ handle: FileHandle, offset: Int, length: Int, to writer: HttpResponseBodyWriter) {
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return }
        var remaining = length
        let chunkSize = 1 << 20
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else { return }
            guard (try? writer.write(chunk)) != nil else { return }
            remaining -= chunk.count
        }
    }

    private func dataResponse(
        _ data: Data,
        contentType: String,
        statusCode: Int = 200,
        reason: String = "OK"
    ) -> HttpResponse {
        return .raw(statusCode, reason, [
            "Content-Type": contentType,
            "Cache-Control": "no-cache, no-store",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Content-Length": "\(data.count)",
        ]) { writer in
            try? writer.write(data)
        }
    }

    private func emptyResponse(statusCode: Int, reason: String) -> HttpResponse {
        .raw(statusCode, reason, [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Content-Length": "0",
        ], nil)
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private extension HttpRequest {
    func queryValue(_ name: String) -> String? {
        queryParams.last { $0.0 == name }?.1
    }

    func queryInt(_ name: String) -> Int? {
        queryValue(name).flatMap(Int.init)
    }

    func queryFlag(_ name: String) -> Bool {
        guard let value = queryValue(name)?.lowercased() else { return false }
        return value.isEmpty || value == "1" || value == "true" || value == "yes"
    }

    func queryDouble(_ name: String) -> Double? {
        queryValue(name).flatMap(Double.init)
    }
}
