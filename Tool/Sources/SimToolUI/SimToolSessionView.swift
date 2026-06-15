#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SimToolClient
import SimToolCore
import SimToolNetworkLogger
import SwiftUI

public struct SimToolSessionView: View {
    public enum Mode: Sendable {
        case embedded
        case window
    }

    @StateObject private var model: SimToolSessionModel
    @State private var textToType = ""
    private let mode: Mode

    public init(client: SimToolClient, mode: Mode = .embedded, session: SessionInfo? = nil) {
        _model = StateObject(wrappedValue: SimToolSessionModel(client: client, session: session, preferDirectInput: mode == .window))
        self.mode = mode
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if model.networkPanelVisible {
                    HSplitView {
                        renderer
                        networkInspector
                    }
                } else {
                    renderer
                }
                Divider()
                inspector
            }
        }
        .frame(minWidth: mode == .window ? 980 : 720, minHeight: mode == .window ? 680 : 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName)
                    .font(.headline)
                Text(model.client.rootURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
            Button(model.networkPanelVisible ? "Hide Network" : "Network") {
                model.setNetworkPanel(!model.networkPanelVisible)
            }
            Button("Refresh") { Task { await model.refreshAll() } }
        }
        .padding(14)
    }

    private var statusPill: some View {
        let state = model.connectionState
        return Text(state.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(state.color.opacity(0.12), in: Capsule())
    }

    private var renderer: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.black)
                ZStack {
                    NativeSimulatorStreamView(
                        deviceUDID: model.captureDeviceUDID,
                        refreshID: model.inputRefreshID,
                        onFrame: { size in model.frameRendered(size: size) },
                        onError: { message in model.nativeStreamFailed(message) },
                        onTap: { point, sourceSize in
                            model.tap(pixel: point, sourceSize: sourceSize)
                        },
                        onSwipe: { start, end, sourceSize, duration in
                            model.swipe(start: start, end: end, sourceSize: sourceSize, duration: duration)
                        }
                    )
                    StreamInputOverlay(
                        frameSize: model.frameSize,
                        onTap: { point, sourceSize in
                            model.tap(pixel: point, sourceSize: sourceSize)
                        },
                        onSwipe: { start, end, sourceSize, duration in
                            model.swipe(start: start, end: end, sourceSize: sourceSize, duration: duration)
                        }
                    )
                }
                .padding(10)
            }
            .overlay(alignment: .topLeading) {
                Text(nativeFrameSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(14)
                    .allowsHitTesting(false)
            }
            .padding(18)

            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
            }
            if let commandStatus = model.commandStatus {
                Text(commandStatus)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nativeFrameSummary: String {
        if let frameSize = model.frameSize {
            "Native frames: \(model.renderedFrames) · \(Int(frameSize.width))x\(Int(frameSize.height))"
        } else {
            "Native frames: \(model.renderedFrames)"
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                metrics
                logsInspector
            }
            .padding(16)
        }
        .frame(width: mode == .window ? 340 : 300)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Controls").font(.headline)
            HStack {
                Button("Home") { model.pressButton("home") }
                Button("Lock") { model.pressButton("lock") }
                Button("Side") { model.pressButton("side-button") }
                Button("Screenshot") { Task { await model.refreshScreenshotFallback() } }
            }
            HStack {
                TextField("Text to type", text: $textToType)
                    .textFieldStyle(.roundedBorder)
                Button("Type") {
                    let text = textToType
                    textToType = ""
                    model.typeText(text)
                }
                .disabled(textToType.isEmpty)
            }
            Text("Video is direct native capture. Input/API calls are sent through SimToolClient.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stream Metrics").font(.headline)
            if let metrics = model.status?.metrics {
                metricRow("Captured", metrics.capturedFrames)
                metricRow("H.264 Encoded", metrics.h264EncodedFrames)
                metricRow("Dropped H.264", metrics.droppedH264Frames)
                metricRow("Clients", metrics.totalClients)
            } else {
                Text("No metrics yet").foregroundStyle(.secondary)
            }
        }
    }

    private func metricRow(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("\(value)").font(.body.monospacedDigit())
        }
        .font(.caption)
    }

    private var logsInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs").font(.headline)
                Spacer()
                if model.logDroppedCount > 0 {
                    Text("\(model.logDroppedCount) dropped")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Toggle("Capture", isOn: Binding(
                    get: { model.logCaptureEnabled },
                    set: { model.setLogCapture(enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Picker("Source", selection: $model.logSourceFilter) {
                Text("All").tag(SimToolSessionModel.LogSourceFilter.all)
                Text("OSLog").tag(SimToolSessionModel.LogSourceFilter.oslog)
                Text("stdout").tag(SimToolSessionModel.LogSourceFilter.stdout)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("filter message / subsystem", text: $model.logFilter)
                .textFieldStyle(.roundedBorder)
            TextField("bundle id", text: $model.logApp)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.restartLogCapture() }
            if model.filteredLogEntries.isEmpty {
                Text(model.logCaptureEnabled ? "No log lines captured" : "Capture is off")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logRows) { row in
                    switch row {
                    case let .divider(_, label):
                        LaunchDividerRow(label: label)
                    case let .entry(entry):
                        LogEntryRow(entry: entry)
                    }
                }
            }
        }
    }

    /// Log entries with an app-launch divider inserted wherever the launch changes.
    private var logRows: [LogInspectorRow] {
        var rows: [LogInspectorRow] = []
        var lastLaunch: Int?
        // Group by launch rather than by arrival order: entries can be attributed to an earlier
        // launch than their neighbors (crash summaries are ingested during the next launch), and
        // rendering them in arrival order would split that launch's section in two.
        let entries = model.filteredLogEntries.sorted {
            ($0.launchId ?? -1, $0.sequence) < ($1.launchId ?? -1, $1.sequence)
        }
        for entry in entries {
            if let launchId = entry.launchId, launchId != lastLaunch {
                rows.append(.divider(launchId: launchId, label: model.launchLabel(launchId)))
                lastLaunch = launchId
            }
            rows.append(.entry(entry))
        }
        return rows
    }

    /// Network events with an app-launch divider inserted wherever the launch changes.
    private var networkRows: [NetworkInspectorRow] {
        var rows: [NetworkInspectorRow] = []
        var lastLaunch: Int?
        for event in model.filteredNetworkEvents {
            if let launchId = event.launchId, launchId != lastLaunch {
                rows.append(.divider(launchId: launchId, label: model.launchLabel(launchId)))
                lastLaunch = launchId
            }
            rows.append(.event(event))
        }
        return rows
    }

    private var networkInspector: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Network").font(.headline)
                Spacer()
                Text("\(model.filteredNetworkEvents.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            TextField("filter service / status / host", text: $model.networkFilter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            Divider()
            VSplitView {
                List(selection: $model.selectedNetworkEventID) {
                    ForEach(networkRows) { row in
                        switch row {
                        case let .divider(_, label):
                            LaunchDividerRow(label: label)
                        case let .event(event):
                            NetworkEventRow(event: event).tag(event.id)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 120)
                .overlay {
                    if model.filteredNetworkEvents.isEmpty {
                        Text("no requests captured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                NetworkDetailView(event: model.selectedNetworkEvent)
                    .frame(minHeight: 140)
            }
        }
        .frame(minWidth: 320)
    }
}

/// A log-inspector list element: either an app-launch divider or a log entry.
private enum LogInspectorRow: Identifiable {
    case divider(launchId: Int, label: String)
    case entry(LogEntry)

    var id: String {
        switch self {
        case let .divider(launchId, _): return "launch-\(launchId)"
        case let .entry(entry): return "entry-\(entry.sequence)"
        }
    }
}

/// A network-inspector list element: either an app-launch divider or a network event.
private enum NetworkInspectorRow: Identifiable {
    case divider(launchId: Int, label: String)
    case event(NetworkLoggerEvent)

    var id: String {
        switch self {
        case let .divider(launchId, _): return "launch-\(launchId)"
        case let .event(event): return "event-\(event.id)"
        }
    }
}

private struct LaunchDividerRow: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 9).monospaced())
            .foregroundStyle(Color.blue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(Color.blue.opacity(0.1))
    }
}

private struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 4) {
                if let level = entry.level, !level.isEmpty {
                    Text(level)
                        .fontWeight(.semibold)
                        .foregroundStyle(entry.isError ? Color.red : sourceColor)
                }
                Text(entry.message)
                    .foregroundStyle(entry.isError ? Color.red : Color.primary)
                    .fontWeight(entry.isError ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.trailing, 42)
            Text(shortTime)
                .font(.system(size: 8).monospaced())
                .foregroundStyle(sourceColor.opacity(0.6))
        }
        .font(.caption2.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
        .background(entry.isError ? Color.red.opacity(0.08) : Color.clear)
    }

    private var sourceColor: Color {
        entry.source == .stdout ? .green : .blue
    }

    private var shortTime: String {
        let timestamp = entry.timestamp
        guard timestamp.count >= 19 else { return timestamp }
        return String(timestamp.dropFirst(11).prefix(8))
    }
}

private struct NetworkEventRow: View {
    let event: NetworkLoggerEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(event.timestamp.dropFirst(11).prefix(8))
                .foregroundStyle(.secondary)
            Text(event.displayRequest)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(event.displayStatus.isEmpty ? "—" : event.displayStatus)
                .foregroundStyle(event.statusColor)
                .fontWeight(.semibold)
            Text(event.displayDuration)
                .foregroundStyle(.secondary)
        }
        .font(.caption2.monospaced())
    }
}

private struct NetworkDetailView: View {
    let event: NetworkLoggerEvent?

    var body: some View {
        ScrollView {
            if let event {
                VStack(alignment: .leading, spacing: 6) {
                    section("Overview")
                    block([
                        event.displayRequest,
                        "\(event.networkProtocol.rawValue) · \(event.displayDuration) · \(event.displayStatus)",
                        event.timestamp,
                        event.appBundleID ?? ""
                    ].filter { !$0.isEmpty }.joined(separator: "\n"))

                    section("Request")
                    let requestMetadata = event.networkProtocol == .grpc ? event.request.metadata : event.request.headers
                    if !requestMetadata.isEmpty { block(format(requestMetadata)) }
                    if let preview = event.request.bodyPreview { block(preview) }

                    if let response = event.response {
                        section("Response")
                        let responseMetadata = event.networkProtocol == .grpc ? response.metadata : response.headers
                        if !responseMetadata.isEmpty { block(format(responseMetadata)) }
                        if let preview = response.bodyPreview { block(preview) }
                    }

                    if let error = event.error {
                        section("Error")
                        block(error.message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            } else {
                Text("select a request")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
    }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func format(_ pairs: [String: String]) -> String {
        pairs.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

private extension NetworkLoggerEvent {
    var statusColor: Color {
        if error != nil { return .red }
        switch networkProtocol {
        case .grpc:
            guard let code = response?.grpcStatusCode else { return .gray }
            return code == "0" ? .green : .red
        case .http:
            guard let code = response?.statusCode else { return .gray }
            if code >= 500 { return .red }
            if code >= 300 { return .orange }
            return .green
        }
    }
}

@MainActor
final class SimToolSessionModel: ObservableObject {
    let client: SimToolClient
    let fallbackDeviceName: String?
    let fallbackDeviceUDID: String?
    let preferDirectInput: Bool

    enum LogSourceFilter: String, CaseIterable, Identifiable, Sendable {
        case all, oslog, stdout
        var id: String { rawValue }
    }

    @Published var status: ServerStatusPayload?
    @Published var frameSize: CGSize?
    @Published var logEntries: [LogEntry] = []
    @Published var logFilter = ""
    @Published var logSourceFilter: LogSourceFilter = .all
    @Published var logCaptureEnabled = true
    @Published var logApp = ""
    @Published var logDroppedCount = 0
    @Published var networkEvents: [NetworkLoggerEvent] = []
    @Published var networkFilter = ""
    @Published var selectedNetworkEventID: String?
    @Published var networkPanelVisible = false
    /// App launches detected by the server, used to draw a divider between launches in the log and
    /// network inspectors after the app is killed and relaunched.
    @Published var launches: [AppLaunchInfo] = []
    @Published var error: String?
    @Published var commandStatus: String?
    @Published var inputRefreshID = 0
    @Published var renderedFrames = 0

    private var pollTask: Task<Void, Never>?
    private var networkPollTask: Task<Void, Never>?
    private var logPollTask: Task<Void, Never>?
    private var logCursor: Int?
    private var nativeFrameCounter = 0
    private let directInput = SimulatorDirectInputClient.shared

    init(client: SimToolClient, session: SessionInfo? = nil, preferDirectInput: Bool = false) {
        self.client = client
        self.fallbackDeviceName = session?.device.name
        self.fallbackDeviceUDID = session?.device.udid
        self.preferDirectInput = preferDirectInput
    }

    var deviceName: String { status?.device ?? fallbackDeviceName ?? "SimTool" }
    var captureDeviceUDID: String? { status?.udid ?? fallbackDeviceUDID }
    var connectionState: (title: String, color: Color) {
        if renderedFrames > 0 { return ("Native Live", .green) }
        if status?.healthy == true && error == nil { return ("API Live", .green) }
        return ("Offline", .orange)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { await pollStatus() }
        Task { await refreshAll() }
        Task {
            await applyServerConfigDefaults()
            if logCaptureEnabled { startLogCapture() }
        }
    }

    private func applyServerConfigDefaults() async {
        do {
            let config = try await client.config()
            if let logApp = config.logApp, !logApp.isEmpty {
                // Scope to the app; capture then includes its stdout/print plus OSLog. Capture starts
                // once (relaunching the app once); the server keeps it alive so it never relaunches again.
                self.logApp = logApp
            }
        } catch {
            // Server config is optional; capture still runs OSLog-only without a default app.
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        networkPollTask?.cancel()
        networkPollTask = nil
        stopLogCapture(stopServer: true)
    }

    var filteredNetworkEvents: [NetworkLoggerEvent] {
        let query = networkFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let newestFirst = Array(networkEvents.reversed())
        guard !query.isEmpty else { return newestFirst }
        return newestFirst.filter { event in
            [event.displayRequest, event.displayStatus, event.networkProtocol.rawValue, event.request.host ?? ""]
                .joined(separator: " ")
                .lowercased()
                .contains(query)
        }
    }

    var selectedNetworkEvent: NetworkLoggerEvent? {
        networkEvents.first { $0.id == selectedNetworkEventID }
    }

    func setNetworkPanel(_ visible: Bool) {
        networkPanelVisible = visible
        if visible {
            guard networkPollTask == nil else { return }
            networkPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshNetworkEvents()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        } else {
            networkPollTask?.cancel()
            networkPollTask = nil
        }
    }

    func frameRendered(size: CGSize) {
        nativeFrameCounter += 1
        guard frameSize != size || nativeFrameCounter - renderedFrames >= 15 else { return }
        frameSize = size
        renderedFrames = nativeFrameCounter
    }

    func nativeStreamFailed(_ message: String) {
        error = message
    }

    func refreshAll() async {
        await refreshStatus()
        if networkPanelVisible {
            await refreshNetworkEvents()
        }
    }

    var filteredLogEntries: [LogEntry] {
        let query = logFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return logEntries.filter { entry in
            if logSourceFilter != .all && entry.source.rawValue != logSourceFilter.rawValue { return false }
            guard !query.isEmpty else { return true }
            return [entry.message, entry.subsystem ?? "", entry.category ?? "", entry.process ?? "", entry.level ?? ""]
                .joined(separator: " ")
                .lowercased()
                .contains(query)
        }
    }

    func setLogCapture(enabled: Bool) {
        logCaptureEnabled = enabled
        if enabled {
            startLogCapture()
        } else {
            stopLogCapture(stopServer: true)
        }
    }

    func restartLogCapture() {
        guard logCaptureEnabled else { return }
        startLogCapture()
    }

    private func startLogCapture() {
        logPollTask?.cancel()
        logEntries = []
        logCursor = nil
        logDroppedCount = 0
        let app = logApp.trimmingCharacters(in: .whitespacesAndNewlines)
        let appFilter = app.isEmpty ? nil : app
        // Always capture stdout/print alongside OSLog when scoped to an app. The server keeps the
        // default-app capture alive, so this relaunches the app at most once per session.
        let captureStdout = appFilter != nil
        let client = client
        logPollTask = Task { [weak self] in
            do {
                _ = try await client.startLogCapture(app: appFilter, captureStdout: captureStdout)
            } catch {
                await MainActor.run { self?.error = error.localizedDescription }
            }
            while !Task.isCancelled {
                await self?.pollLogCapture()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func pollLogCapture() async {
        do {
            await refreshLaunches()
            let payload = try await client.logCaptureEntries(since: logCursor, limit: 500)
            if !payload.entries.isEmpty {
                logEntries.append(contentsOf: payload.entries)
                if logEntries.count > 2_000 {
                    logEntries.removeFirst(logEntries.count - 2_000)
                }
            }
            logCursor = payload.cursor
            if let dropped = payload.droppedCount { logDroppedCount = dropped }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stopLogCapture(stopServer: Bool) {
        logPollTask?.cancel()
        logPollTask = nil
        guard stopServer else { return }
        let client = client
        Task { try? await client.stopLogCapture() }
    }

    func refreshStatus() async {
        do {
            status = try await client.status()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshNetworkEvents() async {
        do {
            await refreshLaunches()
            networkEvents = try await client.networkLoggerEvents(limit: 200).events
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshLaunches() async {
        if let payload = try? await client.launches() {
            launches = payload.launches
        }
    }

    /// Label for an app-launch divider, e.g. `App launch · 12:03:20 · pid 4530`.
    func launchLabel(_ launchId: Int) -> String {
        guard let launch = launches.first(where: { $0.launchId == launchId }) else { return "App launch" }
        var parts = ["App launch"]
        let time = Self.shortTime(launch.startedAt)
        if !time.isEmpty { parts.append(time) }
        parts.append("pid \(launch.pid)")
        return parts.joined(separator: " · ")
    }

    /// Extracts the `HH:MM:SS` portion from an ISO8601 or OSLog-style timestamp.
    static func shortTime(_ timestamp: String) -> String {
        guard timestamp.count >= 19 else { return timestamp }
        return String(timestamp.dropFirst(11).prefix(8))
    }

    func refreshScreenshotFallback() async {
        do {
            let data = try await client.screenshot()
            if let image = NSImage(data: data) {
                frameSize = image.size
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func pressButton(_ name: String) {
        commandStatus = "Sending button \(name)..."
        requestFrameRefresh()
        Self.logInput("button \(name) target=\(captureDeviceUDID ?? "http")")
        let client = client
        let deviceUDID = captureDeviceUDID
        let preferDirectInput = preferDirectInput
        Task.detached(priority: .userInitiated) { [self] in
            do {
                if preferDirectInput, let deviceUDID {
                    if name.lowercased() == "home" {
                        _ = try await ProcessRunner.runXcrun(["simctl", "launch", deviceUDID, "com.apple.springboard"])
                    } else {
                        _ = try await SimulatorInputClient.button(name, deviceUDID: deviceUDID)
                    }
                } else {
                    _ = try await client.button(name)
                }
                await MainActor.run {
                    self.error = nil
                    self.commandStatus = "Sent button \(name)"
                    self.requestFrameRefresh()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.error = message
                    self.commandStatus = "Button \(name) failed: \(message)"
                }
            }
        }
    }

    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        commandStatus = "Typing text..."
        requestFrameRefresh()
        Self.logInput("type target=\(captureDeviceUDID ?? "http") chars=\(text.count)")
        let client = client
        let deviceUDID = captureDeviceUDID
        let preferDirectInput = preferDirectInput
        Task.detached(priority: .userInitiated) { [self] in
            do {
                if preferDirectInput, let deviceUDID {
                    _ = try await SimulatorInputClient.typeText(text, deviceUDID: deviceUDID)
                } else {
                    _ = try await client.typeText(text)
                }
                await MainActor.run {
                    self.error = nil
                    self.commandStatus = "Typed text"
                    self.requestFrameRefresh()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.error = message
                    self.commandStatus = "Type failed: \(message)"
                }
            }
        }
    }

    func tap(pixel: CGPoint, sourceSize: CGSize) {
        commandStatus = "Sending tap..."
        requestFrameRefresh()
        Self.logInput("tap pixel=\(Int(pixel.x)),\(Int(pixel.y)) source=\(Int(sourceSize.width))x\(Int(sourceSize.height)) target=\(captureDeviceUDID ?? "http")")
        let client = client
        let deviceUDID = captureDeviceUDID
        let preferDirectInput = preferDirectInput
        let directInput = directInput
        let ratio = Self.simulatorRatio(pixel: pixel, sourceSize: sourceSize)
        let pixelX = Int(pixel.x)
        let pixelY = Int(pixel.y)
        let pixelXValue = Double(pixel.x)
        let pixelYValue = Double(pixel.y)
        let sourceWidth = Double(sourceSize.width)
        let sourceHeight = Double(sourceSize.height)
        Task.detached(priority: .userInitiated) { [self] in
            do {
                if preferDirectInput, let deviceUDID {
                    Self.logInput("direct tap ratio=\(String(format: "%.4f", ratio.x)),\(String(format: "%.4f", ratio.y)) udid=\(deviceUDID)")
                    try await directInput.tap(xRatio: ratio.x, yRatio: ratio.y, deviceUDID: deviceUDID)
                } else {
                    _ = try await client.input(SimulatorInputPayload(
                        action: "tap",
                        x: pixelXValue,
                        y: pixelYValue,
                        coordinateSpace: "pixels",
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight
                    ))
                }
                Self.logInput("tap sent")
                await MainActor.run {
                    self.error = nil
                    self.commandStatus = "Sent tap at \(pixelX), \(pixelY)"
                    self.requestFrameRefresh()
                }
            } catch {
                let message = error.localizedDescription
                Self.logInput("tap failed: \(message)")
                await MainActor.run {
                    self.error = message
                    self.commandStatus = "Tap failed: \(message)"
                }
            }
        }
    }

    func swipe(start: CGPoint, end: CGPoint, sourceSize: CGSize, duration: Double) {
        commandStatus = "Sending swipe..."
        requestFrameRefresh()
        Self.logInput("swipe start=\(Int(start.x)),\(Int(start.y)) end=\(Int(end.x)),\(Int(end.y)) source=\(Int(sourceSize.width))x\(Int(sourceSize.height)) target=\(captureDeviceUDID ?? "http")")
        let client = client
        let deviceUDID = captureDeviceUDID
        let preferDirectInput = preferDirectInput
        let directInput = directInput
        let startRatio = Self.simulatorRatio(pixel: start, sourceSize: sourceSize)
        let endRatio = Self.simulatorRatio(pixel: end, sourceSize: sourceSize)
        let startX = Double(start.x)
        let startY = Double(start.y)
        let endX = Double(end.x)
        let endY = Double(end.y)
        let sourceWidth = Double(sourceSize.width)
        let sourceHeight = Double(sourceSize.height)
        Task.detached(priority: .userInitiated) { [self] in
            do {
                if preferDirectInput, let deviceUDID {
                    Self.logInput("direct swipe ratio=\(String(format: "%.4f", startRatio.x)),\(String(format: "%.4f", startRatio.y))->\(String(format: "%.4f", endRatio.x)),\(String(format: "%.4f", endRatio.y)) udid=\(deviceUDID)")
                    try await directInput.swipe(
                        startXRatio: startRatio.x,
                        startYRatio: startRatio.y,
                        endXRatio: endRatio.x,
                        endYRatio: endRatio.y,
                        duration: duration,
                        deviceUDID: deviceUDID
                    )
                } else {
                    _ = try await client.input(SimulatorInputPayload(
                        action: "swipe",
                        startX: startX,
                        startY: startY,
                        endX: endX,
                        endY: endY,
                        duration: duration,
                        coordinateSpace: "pixels",
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight
                    ))
                }
                Self.logInput("swipe sent")
                await MainActor.run {
                    self.error = nil
                    self.commandStatus = "Sent swipe"
                    self.requestFrameRefresh()
                }
            } catch {
                let message = error.localizedDescription
                Self.logInput("swipe failed: \(message)")
                await MainActor.run {
                    self.error = message
                    self.commandStatus = "Swipe failed: \(message)"
                }
            }
        }
    }

    private nonisolated static func simulatorRatio(pixel: CGPoint, sourceSize: CGSize) -> CGPoint {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        return CGPoint(
            x: (Double(pixel.x) / Double(sourceSize.width)).clamped(),
            y: (Double(pixel.y) / Double(sourceSize.height)).clamped()
        )
    }

    private nonisolated static func logInput(_ message: String) {
        DebugLog.write("SimToolUI input", message)
    }

    private func requestFrameRefresh() {
        inputRefreshID += 1
    }

    private func pollStatus() async {
        while !Task.isCancelled {
            await refreshStatus()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

private struct StreamInputOverlay: View {
    var frameSize: CGSize?
    var onTap: (CGPoint, CGSize) -> Void
    var onSwipe: (CGPoint, CGPoint, CGSize, Double) -> Void

    @State private var dragStartLocation: CGPoint?
    @State private var dragStartTime = Date()

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(inputGesture(viewSize: proxy.size))
                .allowsHitTesting(frameSize != nil)
        }
    }

    private func inputGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard dragStartLocation == nil else { return }
                dragStartLocation = value.startLocation
                dragStartTime = value.time
            }
            .onEnded { value in
                guard let frameSize,
                      let startLocation = dragStartLocation else {
                    dragStartLocation = nil
                    return
                }
                dragStartLocation = nil
                guard let start = pixelPoint(for: startLocation, viewSize: viewSize, frameSize: frameSize, clamp: false),
                      let end = pixelPoint(for: value.location, viewSize: viewSize, frameSize: frameSize, clamp: true) else {
                    return
                }
                let distance = hypot(end.x - start.x, end.y - start.y)
                let duration = max(0.05, value.time.timeIntervalSince(dragStartTime))
                if distance < 8 {
                    onTap(end, frameSize)
                } else {
                    onSwipe(start, end, frameSize, duration)
                }
            }
    }

    private func pixelPoint(for location: CGPoint, viewSize: CGSize, frameSize: CGSize, clamp: Bool) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0, frameSize.width > 0, frameSize.height > 0 else { return nil }
        let viewAspect = viewSize.width / viewSize.height
        let frameAspect = frameSize.width / frameSize.height
        let drawn: CGRect
        if frameAspect > viewAspect {
            let height = viewSize.width / frameAspect
            drawn = CGRect(x: 0, y: (viewSize.height - height) / 2, width: viewSize.width, height: height)
        } else {
            let width = viewSize.height * frameAspect
            drawn = CGRect(x: (viewSize.width - width) / 2, y: 0, width: width, height: viewSize.height)
        }
        guard drawn.contains(location) || clamp else { return nil }
        let mapped = clamp
            ? CGPoint(x: location.x.clamped(to: drawn.minX...drawn.maxX), y: location.y.clamped(to: drawn.minY...drawn.maxY))
            : location
        return CGPoint(
            x: ((mapped.x - drawn.minX) / drawn.width).clamped() * frameSize.width,
            y: ((mapped.y - drawn.minY) / drawn.height).clamped() * frameSize.height
        )
    }
}

private extension CGFloat {
    func clamped() -> CGFloat { Swift.max(0, Swift.min(1, self)) }
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.max(range.lowerBound, Swift.min(range.upperBound, self)) }
}
#endif
