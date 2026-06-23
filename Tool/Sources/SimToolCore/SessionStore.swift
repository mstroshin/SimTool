import Foundation

public struct SessionInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sessionId }
    public var sessionId: String
    public var pid: Int32
    public var device: SimulatorDevice
    public var url: String
    public var api: String
    public var startedAt: Date
    /// UDIDs this session's process booted itself and should shut down on exit.
    /// Persisted so another SimTool can reap them if this process dies abruptly
    /// (e.g. SIGKILL) without running its own shutdown.
    public var bootedDevices: [String]

    public init(
        sessionId: String,
        pid: Int32,
        device: SimulatorDevice,
        url: String,
        api: String,
        startedAt: Date,
        bootedDevices: [String] = []
    ) {
        self.sessionId = sessionId
        self.pid = pid
        self.device = device
        self.url = url
        self.api = api
        self.startedAt = startedAt
        self.bootedDevices = bootedDevices
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, pid, device, url, api, startedAt, bootedDevices
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

    public func latest() throws -> SessionInfo? {
        try list().first
    }

    public func session(id: String) throws -> SessionInfo? {
        let url = path(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSON.decoder.decode(SessionInfo.self, from: Data(contentsOf: url))
    }
}
