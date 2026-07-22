import Foundation
import SimToolCore

/// Owns the screen-recorder child process for one test session.
public protocol TestVideoRecorder: AnyObject, Sendable {
    /// Spawns the recorder writing to `outputFile`. Throws when it cannot start.
    func start(deviceUDID: String, outputFile: URL) throws
    /// Interrupts the recorder and waits for it to finalize the file.
    func stop() async
}

public enum TestSessionError: Error, LocalizedError, Equatable {
    case alreadyActive(id: String)
    case noActiveSession
    case emptyEntry
    case entryTooLarge(limitBytes: Int)
    case badStatus(TestSessionStatus)
    case sessionNotFound(id: String)
    case sessionRunning(id: String)
    case videoNotReady(id: String)
    case videoMissing(id: String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyActive(id):
            "A test session is already active: \(id). Stop it first."
        case .noActiveSession:
            "No active test session. Run a test or start one via POST /api/v1/tests/start."
        case .emptyEntry:
            "A step entry requires text; a log entry requires at least one log line."
        case let .entryTooLarge(limitBytes):
            "Entry exceeds the \(limitBytes)-byte limit."
        case let .badStatus(status):
            "Stop status must be passed or failed, got \(status.rawValue)."
        case let .sessionNotFound(id):
            "Test session not found: \(id)"
        case let .sessionRunning(id):
            "Test session \(id) is still running. Stop it before deleting."
        case let .videoNotReady(id):
            "Test session \(id) is still recording; the video is available after stop."
        case let .videoMissing(id):
            "Test session \(id) has no video file."
        }
    }
}

/// One active session per server (one simulator, one recording). All mutations
/// persist through `TestSessionStore` immediately so partial sessions survive
/// a crash.
public final class TestSessionController: @unchecked Sendable {
    public static let maxEntryBytes = 64 * 1024

    private let store: TestSessionStore
    private let device: SimulatorDevice
    private let makeRecorder: @Sendable () -> TestVideoRecorder
    private let lock = NSLock()
    private var active: TestSession?
    private var recorder: TestVideoRecorder?
    private var sweptInterrupted = false
    /// First device input since the previous step entry; stamps the next step
    /// so the timeline points at the frame just before the action.
    private var pendingActionStartedAt: Date?

    public init(
        store: TestSessionStore,
        device: SimulatorDevice,
        makeRecorder: @escaping @Sendable () -> TestVideoRecorder
    ) {
        self.store = store
        self.device = device
        self.makeRecorder = makeRecorder
    }

    public func start(title: String) throws -> TestSession {
        lock.lock()
        defer { lock.unlock() }
        sweepLocked()
        if let active { throw TestSessionError.alreadyActive(id: active.id) }
        pendingActionStartedAt = nil
        var session = TestSession(
            id: TestSessionStore.makeId(),
            title: title,
            deviceUdid: device.udid,
            deviceName: device.name,
            startedAt: Date(),
            status: .running
        )
        try store.ensureDirectory(for: session.id)
        let recorder = makeRecorder()
        do {
            try recorder.start(deviceUDID: device.udid, outputFile: store.videoFile(for: session.id))
            session.recordingStartedAt = Date()
            self.recorder = recorder
        } catch {
            // The report matters more than the footage: keep the session usable.
            session.videoError = error.localizedDescription
        }
        do {
            try store.write(session)
        } catch {
            // Don't leak a recording child process if the session can't persist.
            if let recorder = self.recorder {
                self.recorder = nil
                Task { await recorder.stop() }
            }
            throw error
        }
        active = session
        return session
    }

    /// Records the moment a device input (tap, swipe, type, …) was performed.
    /// Only the first input since the previous step is kept: a multi-input
    /// action like a long scroll is anchored at its beginning.
    public func noteInput(at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard active != nil, pendingActionStartedAt == nil else { return }
        pendingActionStartedAt = date
    }

    public func append(_ request: TestSessionEntryRequest) throws -> TestSession {
        lock.lock()
        defer { lock.unlock() }
        guard var session = active else { throw TestSessionError.noActiveSession }
        let text = request.text ?? ""
        let logs = (request.logs ?? []).filter { !$0.isEmpty }
        switch request.kind {
        case .step:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TestSessionError.emptyEntry
            }
        case .log:
            guard !logs.isEmpty else { throw TestSessionError.emptyEntry }
        }
        let bytes = text.utf8.count + logs.reduce(0) { $0 + $1.utf8.count }
        guard bytes <= Self.maxEntryBytes else {
            throw TestSessionError.entryTooLarge(limitBytes: Self.maxEntryBytes)
        }
        let at: Date
        switch request.kind {
        case .step:
            at = pendingActionStartedAt ?? Date()
            pendingActionStartedAt = nil
        case .log:
            at = Date()
        }
        session.entries.append(TestSessionEntry(
            kind: request.kind,
            at: at,
            text: request.kind == .step ? text : nil,
            logs: logs.isEmpty ? nil : logs
        ))
        try store.write(session)
        active = session
        return session
    }

    public func stop(status: TestSessionStatus) async throws -> TestSession {
        guard status == .passed || status == .failed else {
            throw TestSessionError.badStatus(status)
        }
        lock.lock()
        guard var session = active else {
            lock.unlock()
            throw TestSessionError.noActiveSession
        }
        let recorder = self.recorder
        self.recorder = nil
        self.active = nil
        lock.unlock()

        await recorder?.stop()
        if recorder != nil {
            await normalizeVideo(for: session.id)
            session.videoDurationSeconds = await VideoDurationNormalizer.durationSeconds(of: store.videoFile(for: session.id))
        }
        session.endedAt = Date()
        session.status = status
        try store.write(session)
        return session
    }

    /// simctl's mp4 understates the media duration when the screen is static
    /// at the end of a recording, so browsers cut the last frames off. Remux
    /// in place; on failure keep the original file — a slightly short video
    /// beats no video.
    private func normalizeVideo(for id: String) async {
        let file = store.videoFile(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try await VideoDurationNormalizer.normalize(file: file)
        } catch {
            DebugLog.write("tests", "Video normalize failed for \(id): \(error.localizedDescription)")
        }
    }

    public func list() -> TestSessionListPayload {
        lock.lock()
        sweepLocked()
        lock.unlock()
        return TestSessionListPayload(sessions: store.list())
    }

    public func videoFile(id: String) throws -> URL {
        guard !id.contains("/"), !id.contains("..") else {
            throw TestSessionError.sessionNotFound(id: id)
        }
        lock.lock()
        sweepLocked()
        lock.unlock()
        guard let session = try? store.session(id: id) else {
            throw TestSessionError.sessionNotFound(id: id)
        }
        if session.status == .running { throw TestSessionError.videoNotReady(id: id) }
        let file = store.videoFile(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw TestSessionError.videoMissing(id: id)
        }
        return file
    }

    /// Removes a finished session's directory (session.json + video.mp4).
    /// The active recording is protected: stop it first.
    public func delete(id: String) throws {
        guard !id.contains("/"), !id.contains("..") else {
            throw TestSessionError.sessionNotFound(id: id)
        }
        lock.lock()
        defer { lock.unlock() }
        if active?.id == id { throw TestSessionError.sessionRunning(id: id) }
        let directory = store.directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw TestSessionError.sessionNotFound(id: id)
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// Graceful server shutdown: finalize the recording, mark the open session
    /// interrupted so the timeline stays readable.
    public func shutdown() async {
        lock.lock()
        let recorder = self.recorder
        var session = self.active
        self.recorder = nil
        self.active = nil
        lock.unlock()
        await recorder?.stop()
        if session != nil {
            if recorder != nil {
                await normalizeVideo(for: session!.id)
                session!.videoDurationSeconds = await VideoDurationNormalizer.durationSeconds(of: store.videoFile(for: session!.id))
            }
            session!.endedAt = Date()
            session!.status = .interrupted
            try? store.write(session!)
        }
    }

    /// Marks sessions a dead server left `running` as interrupted. Runs once,
    /// on first touch rather than at construction, so spinning up a server in
    /// unit tests never mutates a real project's `.simtool` directory (the
    /// store root is injected, so tests point it at a temp directory).
    /// Caller must hold `lock`.
    private func sweepLocked() {
        guard !sweptInterrupted else { return }
        sweptInterrupted = true
        store.markInterrupted(except: active?.id)
    }
}
