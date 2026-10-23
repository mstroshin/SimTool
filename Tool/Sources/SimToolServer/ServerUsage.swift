import Foundation

/// When the server was last of use to anyone — what tells a server someone
/// works with from one left running for nobody, whose simulator SimTool then
/// shuts down (`SimulatorLease`).
///
/// Use is what someone does through it: a request from the CLI, an agent's
/// curl or a test run's steps; a person in the viewer — a touch, a key, a hand
/// on the page (`POST /api/v1/presence`); anything done to the device that
/// lands in the activity feed. What keeps running by itself is not: the
/// viewer's streams and polls in a tab nobody looks at, the app's loggers
/// posting events and polling for mock rules.
final class ServerUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date

    init(now: Date = Date()) {
        last = now
    }

    var lastUse: Date {
        lock.withLock { last }
    }

    func note(at date: Date = Date()) {
        lock.withLock { last = max(last, date) }
    }

    /// Whether a request is someone using the server. `headers` are keyed by
    /// lowercased name, as Swifter parses them; `path` has no query.
    static func counts(method: String, path: String, headers: [String: String]) -> Bool {
        // A browser names the page behind the request: the viewer, whose
        // traffic runs whether or not anyone is looking — its presence pings
        // say when someone is.
        if headers["sec-fetch-mode"] != nil || headers["origin"] != nil { return false }
        return !appTraffic.contains(method + " " + path)
    }

    /// What the app's loggers send by themselves while it runs.
    private static let appTraffic: Set<String> = [
        "POST /api/v1/network/events",
        "POST /api/v1/state/events",
        "GET /api/v1/mocks",
    ]
}

/// What a server reports about its use: the last time anyone used it, and
/// whether it is busy with something that sends no requests while it runs —
/// a test run it is executing itself, a screen recording.
public struct ServerUsageState: Equatable, Sendable {
    public var lastUse: Date
    public var busy: Bool

    public init(lastUse: Date, busy: Bool) {
        self.lastUse = lastUse
        self.busy = busy
    }
}
