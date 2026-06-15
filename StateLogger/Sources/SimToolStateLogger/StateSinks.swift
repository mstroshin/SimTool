import Foundation
import OSLog

public protocol StateLoggerSink: Sendable {
    func record(_ events: [StateLoggerEvent]) async
}

/// POSTs event batches to the SimTool server. Mirrors NetworkLoggerServerSink:
/// best-effort, never throws into the host app, short timeout.
public final class StateLoggerServerSink: StateLoggerSink, @unchecked Sendable {
    public let serverURL: URL
    public let timeout: TimeInterval
    public let maxEventBytes: Int

    private let session: URLSession
    private let warnLock = NSLock()
    private var warnedOnce = false

    public init(
        serverURL: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 2,
        maxEventBytes: Int = 256_000
    ) {
        self.serverURL = serverURL
        self.session = session
        self.timeout = timeout
        self.maxEventBytes = maxEventBytes
    }

    public func record(_ events: [StateLoggerEvent]) async {
        guard !events.isEmpty else { return }
        do {
            var request = URLRequest(url: Self.endpointURL(for: serverURL))
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(StateLoggerBatchPayload(
                events: events.map { Self.capped($0, maxBytes: maxEventBytes) },
                pid: Int(ProcessInfo.processInfo.processIdentifier)
            ))
            _ = try await session.data(for: request)
        } catch {
            // Live export is best-effort and must not affect the host app:
            // drop events silently after one os_log warning per session.
            if claimFirstWarning() {
                Logger(subsystem: "SimToolStateLogger", category: "Transport")
                    .warning("State event export failed; further failures are dropped silently: \(String(describing: error))")
            }
        }
    }

    /// Synchronous wrapper so the NSLock usage stays out of async contexts
    /// (NSLock.lock/unlock are unavailable there in Swift 6 language mode).
    private func claimFirstWarning() -> Bool {
        warnLock.lock()
        defer { warnLock.unlock() }
        let shouldWarn = !warnedOnce
        warnedOnce = true
        return shouldWarn
    }

    static func endpointURL(for serverURL: URL) -> URL {
        let path = serverURL.path
        if path.hasSuffix("/api/v1/state/events") { return serverURL }
        if path.hasSuffix("/api/v1") { return serverURL.appendingPathComponent("state/events") }
        return serverURL.appendingPathComponent("api/v1/state/events")
    }

    /// Replaces snapshots whose encoded size exceeds `maxBytes` with a marker string,
    /// so one huge model can't flood the channel.
    static func capped(_ event: StateLoggerEvent, maxBytes: Int) -> StateLoggerEvent {
        guard maxBytes > 0,
              let size = try? JSONEncoder().encode(event.snapshot).count,
              size > maxBytes else { return event }
        var event = event
        event.snapshot = .string("<truncated: snapshot was \(size) bytes, cap is \(maxBytes)>")
        return event
    }
}

/// Arms the logger from the environment, following the SimToolNetworkLogger convention:
/// SimTool launches the app with SIMTOOL_STATE_LOGGER=1 and SIMTOOL_SERVER_URL set.
public enum StateLoggerEnvironment {
    public static let enabledKey = "SIMTOOL_STATE_LOGGER"
    public static let serverURLKey = "SIMTOOL_SERVER_URL"

    public static func resolveSink(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> StateLoggerSink? {
        guard environment[enabledKey] == "1",
              let raw = environment[serverURLKey],
              let url = URL(string: raw) else { return nil }
        return StateLoggerServerSink(serverURL: url)
    }
}
