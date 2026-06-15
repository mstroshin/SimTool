import Darwin
import Foundation

/// Origin of a captured log line.
public enum LogSource: String, Codable, Equatable, Sendable {
    /// Unified logging (OSLog / `os.Logger` / `NSLog`) sampled from `log stream`.
    case oslog
    /// The app's stdout/stderr (`print`, custom loggers) sampled via `simctl launch --console-pty`.
    case stdout
}

/// A parsed log line before the store assigns it a sequence number.
public struct LogEntryDraft: Equatable, Sendable {
    public var timestamp: String
    public var source: LogSource
    public var message: String
    public var level: String?
    public var subsystem: String?
    public var category: String?
    public var process: String?
    /// Emitting process identifier, when known (OSLog `processID`). Used to attribute the entry to
    /// an app launch. `nil` for stdout/`print`, which has no per-line process identity.
    public var pid: Int?

    public init(
        timestamp: String,
        source: LogSource,
        message: String,
        level: String? = nil,
        subsystem: String? = nil,
        category: String? = nil,
        process: String? = nil,
        pid: Int? = nil
    ) {
        self.timestamp = timestamp
        self.source = source
        self.message = message
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.process = process
        self.pid = pid
    }
}

/// A captured log line with a monotonic `sequence` assigned by the store, used as the poll cursor.
public struct LogEntry: Codable, Equatable, Sendable, Identifiable {
    public var sequence: Int
    public var timestamp: String
    public var source: LogSource
    public var message: String
    public var level: String?
    public var subsystem: String?
    public var category: String?
    public var process: String?
    /// Emitting process identifier, when known. `nil` for stdout/`print`.
    public var pid: Int?
    /// App launch this entry belongs to, assigned by the server's launch registry. Optional so
    /// existing clients and entries without process identity keep decoding.
    public var launchId: Int?

    public var id: Int { sequence }

    public init(
        sequence: Int,
        timestamp: String,
        source: LogSource,
        message: String,
        level: String? = nil,
        subsystem: String? = nil,
        category: String? = nil,
        process: String? = nil,
        pid: Int? = nil,
        launchId: Int? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.source = source
        self.message = message
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.process = process
        self.pid = pid
        self.launchId = launchId
    }

    public init(sequence: Int, draft: LogEntryDraft, launchId: Int? = nil) {
        self.init(
            sequence: sequence,
            timestamp: draft.timestamp,
            source: draft.source,
            message: draft.message,
            level: draft.level,
            subsystem: draft.subsystem,
            category: draft.category,
            process: draft.process,
            pid: draft.pid,
            launchId: launchId
        )
    }

    /// Heuristic for UI highlighting: the entry looks like an error/fault if its OSLog level is
    /// Error/Fault or its message contains an error-family keyword.
    public var isError: Bool {
        if let level = level?.lowercased(), level == "error" || level == "fault" { return true }
        return message.range(
            of: #"(?i)\b(fatal error|error|exception|fault|crash|failure)\b|❌"#,
            options: .regularExpression
        ) != nil
    }
}

/// Incremental poll response: entries after the requested cursor plus the new cursor value.
public struct LogCaptureEntriesPayload: Codable, Equatable, Sendable {
    public var entries: [LogEntry]
    public var cursor: Int
    public var droppedCount: Int?

    public init(entries: [LogEntry], cursor: Int, droppedCount: Int? = nil) {
        self.entries = entries
        self.cursor = cursor
        self.droppedCount = droppedCount
    }
}

/// Describes the currently active capture, if any.
public struct LogCaptureStatusPayload: Codable, Equatable, Sendable {
    public var active: Bool
    public var device: String?
    public var app: String?
    public var captureStdout: Bool
    public var droppedCount: Int?

    public init(active: Bool, device: String? = nil, app: String? = nil, captureStdout: Bool = false, droppedCount: Int? = nil) {
        self.active = active
        self.device = device
        self.app = app
        self.captureStdout = captureStdout
        self.droppedCount = droppedCount
    }
}

/// Request body for starting a capture. All fields optional; the server defaults `device` to its selected simulator.
public struct LogCaptureStartRequest: Codable, Equatable, Sendable {
    public var device: String?
    public var app: String?
    public var captureStdout: Bool?

    public init(device: String? = nil, app: String? = nil, captureStdout: Bool? = nil) {
        self.device = device
        self.app = app
        self.captureStdout = captureStdout
    }
}

/// Bounded, sequence-stamped in-memory buffer of captured log entries supporting cursor-based incremental reads.
public final class LogEntryStore: @unchecked Sendable {
    public let capacity: Int

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var nextSequence = 0
    private var dropped = 0

    public init(capacity: Int = 5_000) {
        self.capacity = max(0, capacity)
    }

    @discardableResult
    public func append(_ draft: LogEntryDraft, launchId: Int? = nil) -> LogEntry {
        lock.lock()
        defer { lock.unlock() }
        let entry = LogEntry(sequence: nextSequence, draft: draft, launchId: launchId)
        nextSequence += 1
        guard capacity > 0 else {
            dropped += 1
            return entry
        }
        entries.append(entry)
        if entries.count > capacity {
            let overflow = entries.count - capacity
            entries.removeFirst(overflow)
            dropped += overflow
        }
        return entry
    }

    /// Returns entries after `since` (or the newest `limit` when `since` is nil) and the resulting cursor.
    public func query(since: Int?, limit: Int) -> LogCaptureEntriesPayload {
        lock.lock()
        let snapshot = entries
        let droppedCount = dropped
        lock.unlock()

        let bounded = max(0, limit)
        let selected: [LogEntry]
        if let since {
            // Take the oldest entries newer than the cursor so polling never skips lines.
            selected = Array(snapshot.filter { $0.sequence > since }.prefix(bounded))
        } else {
            // Initial load: most recent entries.
            selected = Array(snapshot.suffix(bounded))
        }
        let cursor = selected.last?.sequence ?? snapshot.last?.sequence ?? since ?? -1
        return LogCaptureEntriesPayload(entries: selected, cursor: cursor, droppedCount: droppedCount)
    }

    public func droppedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        dropped = 0
        lock.unlock()
    }

    /// Removes every captured entry attributed to `launchId`, returning how many were dropped.
    @discardableResult
    public func deleteEntries(launchId: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let before = entries.count
        entries.removeAll { $0.launchId == launchId }
        return before - entries.count
    }
}

/// Reassembles newline-delimited lines from arbitrary `Data` chunks, tolerating splits across reads and `\r\n`.
struct LogLineBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            lines.append(Self.decode(lineData))
        }
        return lines
    }

    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let line = Self.decode(buffer)
        buffer.removeAll()
        return line.isEmpty ? nil : line
    }

    private static func decode(_ data: Data) -> String {
        var line = String(decoding: data, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}

/// Shape of a `log stream --style ndjson` record. All fields optional to tolerate version drift.
private struct OSLogStreamLine: Decodable {
    var timestamp: String?
    var eventMessage: String?
    var messageType: String?
    var subsystem: String?
    var category: String?
    var process: String?
    var processImagePath: String?
    var processID: Int?
}

/// Long-lived capture that merges OSLog streaming and (optionally) app stdout/print into one entry callback.
///
/// External capture only — no app instrumentation. OSLog is sampled with a persistent
/// `simctl spawn <udid> log stream`; stdout/print is sampled with `simctl launch --console-pty`,
/// which terminates and relaunches the target app to attach its console.
public final class SimulatorLogCapture: @unchecked Sendable {
    public struct Options: Equatable, Sendable {
        public var deviceUDID: String
        public var app: String?
        public var captureStdout: Bool
        public var bundleID: String?

        public init(deviceUDID: String, app: String? = nil, captureStdout: Bool = false, bundleID: String? = nil) {
            self.deviceUDID = deviceUDID
            self.app = app
            self.captureStdout = captureStdout
            self.bundleID = bundleID
        }
    }

    private let options: Options
    private let onEntry: @Sendable (LogEntryDraft) -> Void

    private let lock = NSLock()
    private var processes: [Process] = []
    private var oslogBuffer = LogLineBuffer()
    private var stdoutBuffer = LogLineBuffer()
    private var started = false
    private var stopped = false

    public init(options: Options, onEntry: @escaping @Sendable (LogEntryDraft) -> Void) {
        self.options = options
        self.onEntry = onEntry
    }

    public func start() throws {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        if options.captureStdout {
            guard let bundleID = (options.bundleID ?? options.app), !bundleID.isEmpty else {
                throw SimToolError("Capturing stdout/print requires an app bundle identifier")
            }
            try startStdout(bundleID: bundleID)
        }
        try startOSLog()
    }

    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let running = processes
        processes.removeAll()
        lock.unlock()
        for process in running {
            Self.detachHandlers(process)
            SimulatorLogCapture.terminate(process)
        }
    }

    // MARK: - OSLog source

    private func startOSLog() throws {
        var arguments = ["simctl", "spawn", options.deviceUDID, "log", "stream", "--style", "ndjson", "--level", "info"]
        if let predicate = SimulatorLogsClient.appLogPredicate(app: options.app) {
            arguments += ["--predicate", predicate]
        }
        try spawn(arguments: arguments, onLine: { [weak self] line in self?.emitOSLog(line: line) })
    }

    private func emitOSLog(line: String) {
        guard let draft = Self.parseOSLogLine(line) else { return }
        onEntry(draft)
    }

    /// Parses one `log stream --style ndjson` line into a draft, or returns a raw-message fallback.
    /// Returns nil only for empty/whitespace lines.
    static func parseOSLogLine(_ line: String) -> LogEntryDraft? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // `log stream` prints an informational predicate banner before the NDJSON; drop it as noise.
        if trimmed.hasPrefix("Filtering the log data using") { return nil }
        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSON.decoder.decode(OSLogStreamLine.self, from: data) {
            let process = parsed.process ?? parsed.processImagePath.map { ($0 as NSString).lastPathComponent }
            return LogEntryDraft(
                timestamp: parsed.timestamp ?? isoNow(),
                source: .oslog,
                message: parsed.eventMessage ?? "",
                level: parsed.messageType,
                subsystem: parsed.subsystem,
                category: parsed.category,
                process: process,
                pid: parsed.processID
            )
        }
        // Defensive fallback: surface the raw line rather than dropping it or failing the capture.
        return LogEntryDraft(timestamp: isoNow(), source: .oslog, message: trimmed)
    }

    // MARK: - stdout/print source

    private func startStdout(bundleID: String) throws {
        let arguments = ["simctl", "launch", "--console-pty", "--terminate-running-process", options.deviceUDID, bundleID]
        try spawn(arguments: arguments, onLine: { [weak self] line in self?.emitStdout(line: line) })
    }

    private func emitStdout(line: String) {
        guard !line.isEmpty else { return }
        onEntry(LogEntryDraft(timestamp: Self.isoNow(), source: .stdout, message: line))
    }

    // MARK: - Process plumbing

    private func spawn(arguments: [String], onLine: @escaping @Sendable (String) -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let isOSLog = arguments.contains("stream")
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleReadable(handle, isOSLog: isOSLog, onLine: onLine)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleReadable(handle, isOSLog: isOSLog, onLine: onLine)
        }

        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            proc.terminationHandler = nil
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw SimToolError("Failed to start log capture (\(arguments.joined(separator: " "))): \(error.localizedDescription)")
        }

        lock.lock()
        if stopped {
            lock.unlock()
            Self.detachHandlers(process)
            SimulatorLogCapture.terminate(process)
            return
        }
        processes.append(process)
        lock.unlock()
    }

    private func handleReadable(_ handle: FileHandle, isOSLog: Bool, onLine: @escaping @Sendable (String) -> Void) {
        let data = handle.availableData
        if data.isEmpty {
            // EOF: flush any buffered remainder, then detach.
            lock.lock()
            let remainder = isOSLog ? oslogBuffer.flush() : stdoutBuffer.flush()
            lock.unlock()
            if let remainder { onLine(remainder) }
            handle.readabilityHandler = nil
            return
        }
        lock.lock()
        let lines = isOSLog ? oslogBuffer.append(data) : stdoutBuffer.append(data)
        lock.unlock()
        for line in lines { onLine(line) }
    }

    private static func detachHandlers(_ process: Process) {
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    /// Escalating teardown matching `ProcessRunner.runFor`: SIGTERM, then SIGINT, then SIGKILL.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { process.interrupt() }
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func isoNow() -> String {
        isoFormatter.string(from: Date())
    }
}
