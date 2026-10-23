import Darwin
import Foundation

/// Acts on the leases: one pass of the reaper, `simtool reap`, and a server
/// letting go of its simulator as it stops. The rules are
/// `SimulatorLeasePolicy`'s; this is what carries them out, with every effect
/// injectable so the passes are tested without simctl.
public struct SimulatorLeaseSweep: Sendable {
    public struct Outcome: Codable, Equatable, Sendable {
        public enum Action: String, Codable, Sendable {
            /// Held and in use, or not idle for long enough yet.
            case kept
            /// Not SimTool's to manage any more: the lease is dropped.
            case released
            /// Used outside SimTool right now: the lease is renewed.
            case inUse
            /// Its SimTool servers were stopped and it was shut down.
            case stoppedServers
            /// Shut down.
            case shutDown
        }

        public var udid: String
        public var name: String
        public var action: Action
        public var reason: String?
        /// How long nothing had used it.
        public var idleSeconds: TimeInterval
        public var idleTimeout: TimeInterval

        public init(udid: String, name: String, action: Action, reason: String?, idleSeconds: TimeInterval, idleTimeout: TimeInterval) {
            self.udid = udid
            self.name = name
            self.action = action
            self.reason = reason
            self.idleSeconds = idleSeconds
            self.idleTimeout = idleTimeout
        }
    }

    public var store: SimulatorLeaseStore
    public var listDevices: @Sendable () async throws -> [SimulatorDevice]
    /// SimTool servers whose process is running.
    public var liveSessions: @Sendable () -> [SessionInfo]
    public var processes: @Sendable () async -> SimulatorProcessSnapshot
    public var stopServer: @Sendable (SessionInfo) async -> Void
    /// True when the simulator went down.
    public var shutDown: @Sendable (String) async -> Bool
    public var now: @Sendable () -> Date

    public init(
        store: SimulatorLeaseStore = .shared,
        listDevices: @escaping @Sendable () async throws -> [SimulatorDevice] = { try await SimulatorDeviceClient.listDevices() },
        liveSessions: @escaping @Sendable () -> [SessionInfo] = { ((try? SessionStore.shared.list()) ?? []).filter(\.isServing) },
        processes: @escaping @Sendable () async -> SimulatorProcessSnapshot = { await SimulatorProcessSnapshot.take() },
        stopServer: @escaping @Sendable (SessionInfo) async -> Void = { await SessionStore.shared.terminate($0) },
        shutDown: @escaping @Sendable (String) async -> Bool = { await SimulatorDeviceClient.shutdown($0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.listDevices = listDevices
        self.liveSessions = liveSessions
        self.processes = processes
        self.stopServer = stopServer
        self.shutDown = shutDown
        self.now = now
    }

    /// One pass over every lease: shut down what `scope` takes — by default
    /// what has been idle for its timeout — and drop the leases that are no
    /// longer SimTool's. `dryRun` says what it would do.
    public func run(scope: SimulatorLeasePolicy.Scope = .idle, dryRun: Bool = false) async -> [Outcome] {
        let leases = store.list()
        guard !leases.isEmpty else { return [] }
        // A failed listing proves nothing about any simulator: keep them all.
        guard let devices = try? await listDevices() else {
            let at = now()
            return leases.map { outcome($0, .kept, "simctl could not list the simulators", at: at) }
        }
        let sessions = liveSessions()
        let snapshot = await processes()
        // One moment for the whole pass: what it reports is what it decided on.
        let at = now()
        var outcomes: [Outcome] = []
        await withTaskGroup(of: Outcome.self) { group in
            for lease in leases {
                let device = devices.first { $0.udid == lease.udid }
                let verdict = SimulatorLeasePolicy.verdict(
                    for: lease,
                    device: device,
                    currentBootPID: snapshot.bootPID(of: lease.udid),
                    liveServers: sessions.filter { $0.device.udid == lease.udid }.map(\.pid),
                    externalUse: device.flatMap { snapshot.externalUse(of: $0) },
                    now: at,
                    scope: scope
                )
                group.addTask { await apply(verdict, to: lease, servers: sessions, dryRun: dryRun, at: at) }
            }
            for await outcome in group { outcomes.append(outcome) }
        }
        return outcomes.sorted { ($0.name, $0.udid) < ($1.name, $1.udid) }
    }

    /// A server on `udid` is stopping: shut the simulator down unless another
    /// SimTool server is still on it, something outside SimTool uses it, or —
    /// for a server stopping because the simulator sat unused since
    /// `unusedSince` — something used it after all. A lease left behind is the
    /// reaper's to settle. Nil when SimTool holds no lease on it.
    public func release(udid: String, leaving pid: Int32, unusedSince: Date? = nil) async -> Outcome? {
        guard let lease = store.lease(udid: udid) else { return nil }
        let at = now()
        if liveSessions().contains(where: { $0.device.udid == udid && $0.pid != pid }) {
            return outcome(lease, .kept, "another SimTool server is on it", at: at)
        }
        if let unusedSince, lease.lastUsedAt > unusedSince {
            return outcome(lease, .kept, "used again as its server stopped", at: at)
        }
        let snapshot = await processes()
        if let held = lease.bootPID, let current = snapshot.bootPID(of: udid), held != current {
            store.remove(udid: udid)
            return outcome(lease, .released, "it was booted again outside SimTool", at: at)
        }
        let device = SimulatorDevice(udid: lease.udid, name: lease.name, runtime: "", state: "Booted", isAvailable: true)
        if let use = snapshot.externalUse(of: device) {
            store.touch(udid: udid, at: at)
            return outcome(lease, .inUse, use, at: at)
        }
        return await shutDownAndRelease(lease, reason: "its SimTool server stopped", at: at)
    }

    private func apply(_ verdict: SimulatorLeasePolicy.Verdict, to lease: SimulatorLease, servers: [SessionInfo], dryRun: Bool, at: Date) async -> Outcome {
        switch verdict {
        case .keep:
            return outcome(lease, .kept, nil, at: at)
        case let .release(reason):
            if !dryRun { store.remove(udid: lease.udid) }
            return outcome(lease, .released, reason, at: at)
        case let .inUse(reason):
            if !dryRun { store.touch(udid: lease.udid, at: at) }
            return outcome(lease, .inUse, reason, at: at)
        case let .stopServers(pids, reason):
            guard !dryRun else { return outcome(lease, .stoppedServers, reason, at: at) }
            if let used = usedSince(lease, at: at) { return used }
            for session in servers where pids.contains(session.pid) { await stopServer(session) }
            let result = await shutDownAndRelease(lease, reason: reason, at: at)
            return result.action == .shutDown ? outcome(lease, .stoppedServers, reason, at: at) : result
        case let .shutDown(reason):
            guard !dryRun else { return outcome(lease, .shutDown, reason, at: at) }
            if let used = usedSince(lease, at: at) { return used }
            return await shutDownAndRelease(lease, reason: reason, at: at)
        }
    }

    /// The pass decided on a lease read seconds ago — `simctl` and `ps` take
    /// that long. Something that used the simulator since wins.
    private func usedSince(_ lease: SimulatorLease, at: Date) -> Outcome? {
        guard let fresh = store.lease(udid: lease.udid), fresh.lastUsedAt > lease.lastUsedAt else { return nil }
        return outcome(fresh, .kept, "used again just now", at: at)
    }

    /// Shuts it down and drops the lease — but keeps the lease when `simctl`
    /// failed: the next pass tries again, or lets go of a simulator that did
    /// go down after all.
    private func shutDownAndRelease(_ lease: SimulatorLease, reason: String, at: Date) async -> Outcome {
        guard await shutDown(lease.udid) else {
            return outcome(lease, .kept, "simctl could not shut it down; trying again", at: at)
        }
        store.remove(udid: lease.udid)
        return outcome(lease, .shutDown, reason, at: at)
    }

    private func outcome(_ lease: SimulatorLease, _ action: Outcome.Action, _ reason: String?, at: Date) -> Outcome {
        Outcome(
            udid: lease.udid,
            name: lease.name,
            action: action,
            reason: reason,
            idleSeconds: lease.idle(at: at),
            idleTimeout: lease.effectiveIdleTimeout
        )
    }
}
