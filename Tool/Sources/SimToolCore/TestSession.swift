import Foundation

public enum TestSessionStatus: String, Codable, Equatable, Sendable {
    case running
    case passed
    case failed
    case interrupted
}

public enum TestSessionEntryKind: String, Codable, Equatable, Sendable {
    case step
    case log
}

/// One timeline entry. A `step` carries the agent's narration (plus optional
/// attached log lines); a `log` carries important log lines not tied to a step.
public struct TestSessionEntry: Codable, Equatable, Sendable {
    public var kind: TestSessionEntryKind
    public var at: Date
    public var text: String?
    public var logs: [String]?

    public init(kind: TestSessionEntryKind, at: Date, text: String? = nil, logs: [String]? = nil) {
        self.kind = kind
        self.at = at
        self.text = text
        self.logs = logs
    }
}

public struct TestSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var deviceUdid: String
    public var deviceName: String
    public var startedAt: Date
    public var endedAt: Date?
    /// Stamped when the recorder process spawned; entry video offsets are
    /// anchored against it client-side.
    public var recordingStartedAt: Date?
    public var status: TestSessionStatus
    /// Set when the recorder failed to start; the session stays usable.
    public var videoError: String?
    /// The finalized video's real length, measured after stop. Step offsets are
    /// wall-clock spans, but simctl's footage runs shorter — recorder
    /// startup/stop latency plus frame-rate drift under load — so the client
    /// scales offsets onto this duration to keep the timeline aligned. Nil for
    /// sessions whose recorder never produced a readable file.
    public var videoDurationSeconds: Double?
    public var entries: [TestSessionEntry]

    public init(
        id: String,
        title: String,
        deviceUdid: String,
        deviceName: String,
        startedAt: Date,
        endedAt: Date? = nil,
        recordingStartedAt: Date? = nil,
        status: TestSessionStatus,
        videoError: String? = nil,
        videoDurationSeconds: Double? = nil,
        entries: [TestSessionEntry] = []
    ) {
        self.id = id
        self.title = title
        self.deviceUdid = deviceUdid
        self.deviceName = deviceName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recordingStartedAt = recordingStartedAt
        self.status = status
        self.videoError = videoError
        self.videoDurationSeconds = videoDurationSeconds
        self.entries = entries
    }
}

public struct TestSessionListPayload: Codable, Equatable, Sendable {
    public var sessions: [TestSession]
    public init(sessions: [TestSession]) { self.sessions = sessions }
}

public struct TestSessionStartRequest: Codable, Equatable, Sendable {
    public var title: String
    /// Record a screen video for the session; nil means yes (the default).
    public var video: Bool?

    public init(title: String, video: Bool? = nil) {
        self.title = title
        self.video = video
    }
}

public struct TestSessionEntryRequest: Codable, Equatable, Sendable {
    public var kind: TestSessionEntryKind
    public var text: String?
    public var logs: [String]?

    public init(kind: TestSessionEntryKind, text: String? = nil, logs: [String]? = nil) {
        self.kind = kind
        self.text = text
        self.logs = logs
    }
}

public struct TestSessionStopRequest: Codable, Equatable, Sendable {
    public var status: TestSessionStatus
    public init(status: TestSessionStatus) { self.status = status }
}

/// Disk layout: `<root>/<session-id>/session.json` + `video.mp4`. The root is
/// the project's `.simtool/test-sessions` directory: test artifacts belong to
/// the project the server was started for and must outlive `$TMPDIR` where
/// daemon sessions live.
public final class TestSessionStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    public func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    public func sessionFile(for id: String) -> URL {
        directory(for: id).appendingPathComponent("session.json")
    }

    public func videoFile(for id: String) -> URL {
        directory(for: id).appendingPathComponent("video.mp4")
    }

    public func ensureDirectory(for id: String) throws {
        try SimToolDirectory.ensureEnclosing(root)
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
    }

    /// Rewritten atomically on every mutation, so a crash loses at most the
    /// in-flight entry.
    public func write(_ session: TestSession) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory(for: session.id)
        try JSON.data(session).write(to: sessionFile(for: session.id), options: [.atomic])
    }

    public func session(id: String) throws -> TestSession? {
        let url = sessionFile(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSON.decoder.decode(TestSession.self, from: Data(contentsOf: url))
    }

    /// All sessions, newest first. Corrupt or partial `session.json` files are
    /// skipped so one bad directory cannot break the list.
    public func list() -> [TestSession] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { url -> TestSession? in
            let file = url.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            do {
                return try JSON.decoder.decode(TestSession.self, from: data)
            } catch {
                DebugLog.write("tests", "Skipping corrupt session file at \(file.path): \(error.localizedDescription)")
                return nil
            }
        }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Marks sessions a dead server left `running` as `interrupted`. Returns
    /// the ids it changed.
    @discardableResult
    public func markInterrupted(except activeId: String? = nil) -> [String] {
        var marked: [String] = []
        for var session in list() where session.status == .running && session.id != activeId {
            session.status = .interrupted
            session.endedAt = session.endedAt ?? Date()
            if (try? write(session)) != nil { marked.append(session.id) }
        }
        return marked
    }

    /// `2026-06-12-1430-a1b2c3`: sortable local-time prefix plus a random suffix.
    public static func makeId(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let suffix = String((0..<6).map { _ in alphabet.randomElement()! })
        return formatter.string(from: now) + "-" + suffix
    }
}
