import Foundation

/// One observed launch (process lifetime) of the inspected app.
///
/// Identified by a monotonic `launchId` that stays stable for the server's lifetime, even if the
/// OS reuses a `pid`. `startedAt`/`endedAt` are ISO8601 strings taken from the evidence that
/// registered/superseded the launch.
public struct AppLaunchInfo: Codable, Equatable, Sendable, Identifiable {
    public var launchId: Int
    public var pid: Int
    public var app: String?
    public var startedAt: String
    public var endedAt: String?

    public var id: Int { launchId }

    public init(launchId: Int, pid: Int, app: String? = nil, startedAt: String, endedAt: String? = nil) {
        self.launchId = launchId
        self.pid = pid
        self.app = app
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// The launches detected for the inspected app, ordered by ascending `launchId`.
public struct AppLaunchesPayload: Codable, Equatable, Sendable {
    public var launches: [AppLaunchInfo]

    public init(launches: [AppLaunchInfo]) {
        self.launches = launches
    }
}

/// Thread-safe, server-lifetime registry that turns observed process identities into stable launch
/// ids shared by the log and network ingest paths.
///
/// A new launch is registered whenever the observed `pid` differs from the most recent launch's
/// `pid`; the prior launch is then stamped with `endedAt`. The same `pid` reported by OSLog and by
/// app-emitted network batches therefore resolves to the same `launchId`.
public final class AppLaunchRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var launches: [AppLaunchInfo] = []
    private var nextLaunchId = 0

    public init() {}

    /// Resolves `pid` to a launch id, registering a new launch when the process identity changes
    /// from the most recently observed one.
    @discardableResult
    public func observe(pid: Int, app: String? = nil, timestamp: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let last = launches.last, last.pid == pid {
            return last.launchId
        }
        if !launches.isEmpty, launches[launches.count - 1].endedAt == nil {
            launches[launches.count - 1].endedAt = timestamp
        }
        let launchId = nextLaunchId
        nextLaunchId += 1
        launches.append(AppLaunchInfo(launchId: launchId, pid: pid, app: app, startedAt: timestamp))
        return launchId
    }

    /// The most recently registered launch id, used to attribute entries that carry no `pid`
    /// (for example stdout/`print` lines), or `nil` when nothing has been observed yet.
    public func currentLaunchId() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return launches.last?.launchId
    }

    /// The launch registered immediately before `launchId`, or `nil` when it is the earliest
    /// known one. Used to attribute entries that describe the previous run (crash summaries).
    public func launchId(preceding launchId: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = launches.firstIndex(where: { $0.launchId == launchId }), index > 0 else {
            return nil
        }
        return launches[index - 1].launchId
    }

    /// Detected launches ordered by ascending `launchId` (which reflects detection order).
    public func snapshot() -> [AppLaunchInfo] {
        lock.lock()
        defer { lock.unlock() }
        return launches
    }
}
