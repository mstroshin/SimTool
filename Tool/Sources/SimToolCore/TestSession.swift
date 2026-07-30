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
    /// When the step finished. With `at` (stamped at the first input of the
    /// step) this bounds the window whose captured logs, network events and
    /// state changes belong to this step — which is how per-step evidence is
    /// sliced without threading server-local cursors through the artifact.
    public var endedAt: Date?
    public var text: String?
    public var logs: [String]?
    /// Log-capture cursor range covering the step, when a capture was armed.
    /// Cursors disambiguate what timestamps cannot: entries logged in the same
    /// millisecond, or a clock that moved.
    public var logCursorFrom: Int?
    public var logCursorTo: Int?
    /// The criterion this step checked, when it was checking one.
    public var criterion: String?

    public init(
        kind: TestSessionEntryKind,
        at: Date,
        endedAt: Date? = nil,
        text: String? = nil,
        logs: [String]? = nil,
        logCursorFrom: Int? = nil,
        logCursorTo: Int? = nil,
        criterion: String? = nil
    ) {
        self.kind = kind
        self.at = at
        self.endedAt = endedAt
        self.text = text
        self.logs = logs
        self.logCursorFrom = logCursorFrom
        self.logCursorTo = logCursorTo
        self.criterion = criterion
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
    /// What the test was verifying, when it verifies a claim.
    public var kind: TestKind?
    /// Free-form origin of the work, copied from the test. Never interpreted.
    public var reference: String?
    /// The claim, one entry per criterion: seeded `unchecked` when the run
    /// starts and replaced with results when it stops.
    public var criteria: [TestCriterionResult]
    /// What the run concluded. Nil while running, and for plain tests that make
    /// no claim.
    public var verdict: TestVerdict?
    /// What each declared mock rule actually did.
    public var mocks: [TestMockOutcome]
    /// Evidence files the run wrote next to `session.json`, relative to the
    /// session directory.
    public var evidence: [String]
    /// Where the run came from: the test itself, the app, the device, the tool.
    public var provenance: TestRunProvenance?
    /// The test file this session is running, as the viewer lists it. Without it
    /// a run started from the CLI is a session the viewer cannot attribute to any
    /// test, so it keeps offering to run that test again.
    public var file: String?

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
        entries: [TestSessionEntry] = [],
        kind: TestKind? = nil,
        reference: String? = nil,
        criteria: [TestCriterionResult] = [],
        verdict: TestVerdict? = nil,
        mocks: [TestMockOutcome] = [],
        evidence: [String] = [],
        provenance: TestRunProvenance? = nil,
        file: String? = nil
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
        self.kind = kind
        self.reference = reference
        self.criteria = criteria
        self.verdict = verdict
        self.mocks = mocks
        self.evidence = evidence
        self.provenance = provenance
        self.file = file
    }

    /// Decoding tolerates sessions recorded before these fields existed, so an
    /// older `.simtool/test-sessions` directory keeps listing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        deviceUdid = try container.decode(String.self, forKey: .deviceUdid)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        recordingStartedAt = try container.decodeIfPresent(Date.self, forKey: .recordingStartedAt)
        status = try container.decode(TestSessionStatus.self, forKey: .status)
        videoError = try container.decodeIfPresent(String.self, forKey: .videoError)
        videoDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .videoDurationSeconds)
        entries = try container.decodeIfPresent([TestSessionEntry].self, forKey: .entries) ?? []
        kind = try container.decodeIfPresent(TestKind.self, forKey: .kind)
        reference = try container.decodeIfPresent(String.self, forKey: .reference)
        criteria = try container.decodeIfPresent([TestCriterionResult].self, forKey: .criteria) ?? []
        verdict = try container.decodeIfPresent(TestVerdict.self, forKey: .verdict)
        mocks = try container.decodeIfPresent([TestMockOutcome].self, forKey: .mocks) ?? []
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        provenance = try container.decodeIfPresent(TestRunProvenance.self, forKey: .provenance)
        file = try container.decodeIfPresent(String.self, forKey: .file)
    }
}

public struct TestSessionListPayload: Codable, Equatable, Sendable {
    public var sessions: [TestSession]
    public init(sessions: [TestSession]) { self.sessions = sessions }
}

public struct TestSessionStartRequest: Codable, Equatable, Sendable {
    public var title: String
    /// The test file being run, so the viewer can show the run against the test
    /// it belongs to even when the run was started from the CLI.
    public var file: String?
    /// Record a screen video for the session; nil means yes (the default).
    public var video: Bool?
    public var kind: TestKind?
    public var reference: String?
    /// Criterion labels the test declares; seeded as `unchecked` so the claim
    /// is visible while the run is still going.
    public var criteria: [String]?
    public var provenance: TestRunProvenance?

    public init(
        title: String,
        file: String? = nil,
        video: Bool? = nil,
        kind: TestKind? = nil,
        reference: String? = nil,
        criteria: [String]? = nil,
        provenance: TestRunProvenance? = nil
    ) {
        self.title = title
        self.file = file
        self.video = video
        self.kind = kind
        self.reference = reference
        self.criteria = criteria
        self.provenance = provenance
    }
}

public struct TestSessionEntryRequest: Codable, Equatable, Sendable {
    public var kind: TestSessionEntryKind
    public var text: String?
    public var logs: [String]?
    public var logCursorFrom: Int?
    public var logCursorTo: Int?
    public var criterion: String?

    public init(
        kind: TestSessionEntryKind,
        text: String? = nil,
        logs: [String]? = nil,
        logCursorFrom: Int? = nil,
        logCursorTo: Int? = nil,
        criterion: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.logs = logs
        self.logCursorFrom = logCursorFrom
        self.logCursorTo = logCursorTo
        self.criterion = criterion
    }
}

public struct TestSessionStopRequest: Codable, Equatable, Sendable {
    public var status: TestSessionStatus
    public var verdict: TestVerdict?
    public var criteria: [TestCriterionResult]?
    public var mocks: [TestMockOutcome]?
    /// Evidence files the run wrote into the session directory.
    public var evidence: [String]?

    public init(
        status: TestSessionStatus,
        verdict: TestVerdict? = nil,
        criteria: [TestCriterionResult]? = nil,
        mocks: [TestMockOutcome]? = nil,
        evidence: [String]? = nil
    ) {
        self.status = status
        self.verdict = verdict
        self.criteria = criteria
        self.mocks = mocks
        self.evidence = evidence
    }
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
