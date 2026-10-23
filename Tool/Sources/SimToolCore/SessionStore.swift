import Darwin
import Foundation

public struct SessionInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sessionId }
    public var sessionId: String
    public var pid: Int32
    public var device: SimulatorDevice
    public var url: String
    public var api: String
    public var startedAt: Date
    /// UDIDs an older SimTool's server booted itself, for another to shut
    /// down when it died. SimTool now holds them by lease (`SimulatorLease`)
    /// and leaves this empty: a list that outlives its server would shut down
    /// whatever boot of the simulator is running by then.
    public var bootedDevices: [String]
    /// The project this server serves, so a command in another checkout does not
    /// reuse it: its simulator is another project's, and the sessions it records
    /// land in that project's `.simtool`. Nil when it was started outside one.
    public var projectRoot: String?

    public init(
        sessionId: String,
        pid: Int32,
        device: SimulatorDevice,
        url: String,
        api: String,
        startedAt: Date,
        bootedDevices: [String] = [],
        projectRoot: String? = nil
    ) {
        self.sessionId = sessionId
        self.pid = pid
        self.device = device
        self.url = url
        self.api = api
        self.startedAt = startedAt
        self.bootedDevices = bootedDevices
        self.projectRoot = projectRoot
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, pid, device, url, api, startedAt, bootedDevices, projectRoot
    }

    /// True while a process with this PID exists (EPERM means it exists but
    /// belongs to someone else — still alive for our purposes).
    public static func isRunning(pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// When the process with this PID started, as the kernel says; nil when
    /// there is none.
    public static func startTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Whether this session's server is still running: its PID is alive and
    /// is still the process that wrote the session. A session file outlives
    /// its server, and the PID may since belong to some other process — one
    /// that started after the session did, which the server never could.
    public var isServing: Bool {
        guard Self.isRunning(pid: pid) else { return false }
        // `startedAt` is written to the second; the server started before it.
        return Self.startTime(pid: pid).map { $0 <= startedAt.addingTimeInterval(2) } ?? true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        pid = try container.decode(Int32.self, forKey: .pid)
        device = try container.decode(SimulatorDevice.self, forKey: .device)
        url = try container.decode(String.self, forKey: .url)
        api = try container.decode(String.self, forKey: .api)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        // Tolerate session files written before bootedDevices existed.
        bootedDevices = try container.decodeIfPresent([String].self, forKey: .bootedDevices) ?? []
        // Tolerate session files written before projectRoot existed.
        projectRoot = try container.decodeIfPresent(String.self, forKey: .projectRoot)
    }
}

/// Selects which simulators to shut down when reaping sessions whose processes
/// are gone. Pure decision logic so it can be unit-tested without simctl.
public enum SessionReaper {
    /// The UDIDs booted by `dead` sessions, deduplicated in first-seen order,
    /// excluding any still claimed by a `live` session (another running SimTool
    /// is using that simulator, so it must stay up).
    public static func devicesToReap(dead: [SessionInfo], live: [SessionInfo]) -> [String] {
        let claimedByLive = Set(live.flatMap(\.bootedDevices))
        var result: [String] = []
        for udid in dead.flatMap(\.bootedDevices) where !claimedByLive.contains(udid) && !result.contains(udid) {
            result.append(udid)
        }
        return result
    }
}

public struct SessionListPayload: Codable, Equatable, Sendable {
    public var sessions: [SessionInfo]
    public init(sessions: [SessionInfo]) { self.sessions = sessions }
}

public struct StatusPayload: Codable, Equatable, Sendable {
    public var session: SessionInfo?
    public var healthy: Bool
    public var message: String?

    public init(session: SessionInfo?, healthy: Bool, message: String? = nil) {
        self.session = session
        self.healthy = healthy
        self.message = message
    }
}

public final class SessionStore: @unchecked Sendable {
    public static let shared = SessionStore()

    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func path(for sessionId: String) -> URL {
        root.appendingPathComponent("\(sessionId).json")
    }

    public func logPath(for sessionId: String) -> URL {
        root.appendingPathComponent("\(sessionId).log")
    }

    public func write(_ session: SessionInfo) throws {
        try ensureRoot()
        try JSON.data(session).write(to: path(for: session.sessionId), options: [.atomic])
    }

    public func remove(_ sessionId: String) {
        try? FileManager.default.removeItem(at: path(for: sessionId))
    }

    public func list() throws -> [SessionInfo] {
        try ensureRoot()
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSON.decoder.decode(SessionInfo.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Stops a session's server: SIGTERM first, so it runs its own shutdown —
    /// which lets go of its simulator — and SIGKILL when it has not gone within
    /// six seconds. A server already gone is not signalled: its PID may be
    /// another process's by now. The session file goes either way. True when
    /// the server cleaned up after itself; false when it had to be killed, or
    /// was not running.
    @discardableResult
    public func terminate(_ session: SessionInfo) async -> Bool {
        defer { remove(session.sessionId) }
        guard session.isServing else { return false }
        Darwin.kill(session.pid, SIGTERM)
        for _ in 0..<60 where SessionInfo.isRunning(pid: session.pid) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard SessionInfo.isRunning(pid: session.pid) else { return true }
        Darwin.kill(session.pid, SIGKILL)
        return false
    }

    public func latest() throws -> SessionInfo? {
        try list().first
    }

    public func session(id: String) throws -> SessionInfo? {
        let url = path(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSON.decoder.decode(SessionInfo.self, from: Data(contentsOf: url))
    }
}
