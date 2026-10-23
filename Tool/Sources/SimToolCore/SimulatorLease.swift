import Darwin
import Foundation

/// SimTool's claim on a booted simulator: the promise to power it down once
/// nothing uses it. A booted simulator with its app burns a core or so doing
/// nothing, so nothing SimTool brings up — or takes over — may stay booted
/// idle after the work is done.
///
/// SimTool takes a lease when it boots a simulator, and when one of its servers
/// starts on a simulator someone else booted (a script's `simctl boot` ahead of
/// `serve`, an agent's): the server is what keeps it in use from then on. A
/// command that merely drives an already-booted simulator renews a lease but
/// never takes one, so a simulator SimTool never booted or served — a person's
/// Xcode run, a Device Hub window — is never SimTool's to shut down.
///
/// Leases live on disk, one file per simulator, so every SimTool process sees
/// them: a detached server, the CLI that booted the device before handing it
/// over, the background reaper after a server was SIGKILLed.
public struct SimulatorLease: Codable, Equatable, Sendable {
    public var udid: String
    public var name: String
    /// SimTool booted it; false when a server took over one booted elsewhere.
    public var bootedBySimTool: Bool
    /// The simulator's `launchd_sim` when the lease was taken. A lease covers
    /// one boot: a simulator shut down and booted again by someone else is
    /// theirs, not SimTool's. Nil when it could not be read.
    public var bootPID: Int32?
    public var takenAt: Date
    /// The last time anything used it: a command, a server request, a person
    /// in the viewer, a test run in progress.
    public var lastUsedAt: Date
    /// How long it may sit unused before SimTool shuts it down; nil for the
    /// default, 0 for never.
    public var idleTimeout: TimeInterval?

    public init(
        udid: String,
        name: String,
        bootedBySimTool: Bool,
        bootPID: Int32? = nil,
        takenAt: Date = Date(),
        lastUsedAt: Date? = nil,
        idleTimeout: TimeInterval? = nil
    ) {
        self.udid = udid
        self.name = name
        self.bootedBySimTool = bootedBySimTool
        self.bootPID = bootPID
        self.takenAt = takenAt
        self.lastUsedAt = lastUsedAt ?? takenAt
        self.idleTimeout = idleTimeout
    }

    /// The timeout this lease runs under: its own, else the default.
    public var effectiveIdleTimeout: TimeInterval { idleTimeout ?? SimulatorIdleTimeout.defaultSeconds }

    /// How long nothing has used it.
    public func idle(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(lastUsedAt)) }

    /// Unused for its whole timeout; never, under a timeout of 0.
    public func isIdle(at now: Date) -> Bool {
        let timeout = effectiveIdleTimeout
        return timeout > 0 && idle(at: now) >= timeout
    }
}

/// How long a simulator SimTool holds may go unused: `idleTimeout:` in
/// `.simtool/config.yml`, `SIMTOOL_IDLE_TIMEOUT`, or `--idle-timeout`.
public enum SimulatorIdleTimeout {
    /// Long enough for an agent's build between two checks, short enough that
    /// a simulator left behind stops burning a core within a quarter hour.
    public static let defaultSeconds: TimeInterval = 15 * 60
    public static let environmentKey = "SIMTOOL_IDLE_TIMEOUT"

    /// `15m`, `90s`, `1h`, `900`; `off` or `0` for never (`false` too: what a
    /// YAML 1.1 reader makes of an unquoted `off`).
    public static func parse(_ text: String) throws -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["off", "never", "none", "false"].contains(trimmed) { return 0 }
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600]
        var number = Substring(trimmed)
        var multiplier: TimeInterval = 1
        if let last = trimmed.last, let unit = units[last] {
            number = number.dropLast()
            multiplier = unit
        }
        guard let value = TimeInterval(number), value.isFinite, value >= 0, value * multiplier <= 7 * 86_400 else {
            throw SimToolError("Invalid idle timeout '\(text)': use seconds or a number with s, m or h, as in 900, 15m or 1h, up to a week; off (or 0) to never shut the simulator down.")
        }
        return value * multiplier
    }

    /// The timeout from the environment, when it names a valid one.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval? {
        environment[environmentKey].flatMap { try? parse($0) }
    }

    /// A timeout: `15 min`, `90 s`, `off`.
    public static func describe(_ seconds: TimeInterval) -> String {
        seconds <= 0 ? "off" : duration(seconds)
    }

    /// A stretch of time: `0 s`, `90 s`, `15 min`, `2.5 h`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 120 { return "\(Int(seconds.rounded())) s" }
        if seconds < 2 * 3_600 { return "\(Int((seconds / 60).rounded())) min" }
        return String(format: "%.1f h", seconds / 3_600)
    }
}

/// The leases on disk, beside the session files.
public final class SimulatorLeaseStore: @unchecked Sendable {
    public static let shared = SimulatorLeaseStore()

    public let root: URL
    private let lock = NSLock()

    public init(root: URL? = nil) {
        self.root = root ?? SessionStore.shared.root
            .deletingLastPathComponent()
            .appendingPathComponent("simulators", isDirectory: true)
    }

    public func path(for udid: String) -> URL {
        root.appendingPathComponent("\(udid).json")
    }

    public func lease(udid: String) -> SimulatorLease? {
        guard let data = try? Data(contentsOf: path(for: udid)) else { return nil }
        return try? JSON.decoder.decode(SimulatorLease.self, from: data)
    }

    public func list() -> [SimulatorLease] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSON.decoder.decode(SimulatorLease.self, from: $0) }
        }.sorted { $0.takenAt < $1.takenAt }
    }

    public func write(_ lease: SimulatorLease) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSON.data(lease) else { return }
        try? data.write(to: path(for: lease.udid), options: [.atomic])
    }

    public func remove(udid: String) {
        try? FileManager.default.removeItem(at: path(for: udid))
    }

    /// Takes the lease on `device`, or renews the one SimTool already holds:
    /// it stays SimTool-booted once it was, keeps the boot it was taken on,
    /// and takes a timeout only when one is given.
    @discardableResult
    public func take(
        _ device: SimulatorDevice,
        booted: Bool,
        bootPID: Int32?,
        idleTimeout: TimeInterval? = nil,
        now: Date = Date()
    ) -> SimulatorLease {
        lock.withLock {
            var lease = lease(udid: device.udid).flatMap { held in
                // Taken on a boot that has ended: it is a new claim.
                held.bootPID != nil && bootPID != nil && held.bootPID != bootPID ? nil : held
            } ?? SimulatorLease(udid: device.udid, name: device.name, bootedBySimTool: booted, bootPID: bootPID, takenAt: now)
            lease.bootedBySimTool = lease.bootedBySimTool || booted
            lease.bootPID = lease.bootPID ?? bootPID
            lease.lastUsedAt = max(lease.lastUsedAt, now)
            if let idleTimeout { lease.idleTimeout = idleTimeout }
            write(lease)
            return lease
        }
    }

    /// Marks a simulator SimTool holds as used at `date`. Without a lease it
    /// does nothing: using a simulator does not make it SimTool's.
    @discardableResult
    public func touch(udid: String, at date: Date = Date()) -> SimulatorLease? {
        lock.withLock {
            guard var lease = lease(udid: udid) else { return nil }
            guard date > lease.lastUsedAt else { return lease }
            lease.lastUsedAt = date
            write(lease)
            return lease
        }
    }
}

/// What the Mac's process table says about simulators: which boot each one is
/// on, and whether something outside SimTool is using it right now.
public struct SimulatorProcessSnapshot: Sendable {
    public struct Entry: Equatable, Sendable {
        public var pid: Int32
        public var command: String

        public init(pid: Int32, command: String) {
            self.pid = pid
            self.command = command
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// `ps` of every process, full command lines. Empty when `ps` fails, which
    /// reads as "no boot known, nothing in use".
    public static func take() async -> SimulatorProcessSnapshot {
        guard let output = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=,command="],
            timeoutSeconds: 10
        ), output.status == 0 else { return SimulatorProcessSnapshot(entries: []) }
        return parse(output.stdoutString)
    }

    public static func parse(_ text: String) -> SimulatorProcessSnapshot {
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            entries.append(Entry(pid: pid, command: trimmed[space...].trimmingCharacters(in: .whitespaces)))
        }
        return SimulatorProcessSnapshot(entries: entries)
    }

    /// The `launchd_sim` running the simulator's current boot.
    public func bootPID(of udid: String) -> Int32? {
        let marker = "/\(udid.uppercased())/"
        return entries.first { entry in
            entry.command.hasPrefix("launchd_sim ") && entry.command.uppercased().contains(marker)
        }?.pid
    }

    /// Why the simulator is in use outside SimTool, or nil: an `xcodebuild`
    /// whose destination is it — a test run takes as long as it takes, and
    /// shutting the simulator under it fails it. Matched by UDID or by
    /// `name=<its name>` in the destination.
    public func externalUse(of device: SimulatorDevice) -> String? {
        let udid = device.udid.uppercased()
        let name = "name=" + device.name
        for entry in entries where Self.isXcodebuild(entry.command) {
            let command = entry.command
            if command.uppercased().contains(udid) || Self.names(name, in: command) {
                return "xcodebuild (pid \(entry.pid)) is running on it"
            }
        }
        return nil
    }

    /// The executable is `xcodebuild` — a path to it may hold spaces
    /// (`/Applications/Xcode 27.app/…`), so it is found before the first option
    /// rather than as the first word.
    private static func isXcodebuild(_ command: String) -> Bool {
        let executable = command.range(of: " -").map { String(command[..<$0.lowerBound]) } ?? command
        guard let found = executable.range(of: "xcodebuild") else { return false }
        let before: Character = found.lowerBound == executable.startIndex ? "/" : executable[executable.index(before: found.lowerBound)]
        let after: Character = found.upperBound == executable.endIndex ? " " : executable[found.upperBound]
        return before == "/" && after == " "
    }

    /// `name=Foo` in a destination, not `name=Foo Bar`. `ps` shows the
    /// arguments joined by spaces with the shell's quotes gone, so a name ends
    /// where the destination does: at a comma, the end of the line, the next
    /// option, or an action (`… name=iPhone 16 Pro test`).
    private static func names(_ needle: String, in command: String) -> Bool {
        var searchRange = command.startIndex..<command.endIndex
        while let found = command.range(of: needle, range: searchRange) {
            let rest = command[found.upperBound...]
            if rest.isEmpty || rest.hasPrefix(",") || rest.hasPrefix(" -") { return true }
            if rest.hasPrefix(" "), let word = rest.dropFirst().split(separator: " ", maxSplits: 1).first, actions.contains(String(word)) {
                return true
            }
            searchRange = found.upperBound..<command.endIndex
        }
        return false
    }

    private static let actions: Set<String> = [
        "build", "build-for-testing", "test", "test-without-building", "analyze", "archive", "clean", "docbuild",
    ]
}

/// What to do about one lease. Pure, so every rule is unit-tested.
public enum SimulatorLeasePolicy {
    /// How long a live server may outstay an idle lease before the reaper
    /// stops it — a server stops itself once its simulator is idle; this is
    /// for one that is wedged, or too old to know about leases.
    public static let serverGrace: TimeInterval = 120

    /// What counts as in use right now when the reaper stops: a command busy
    /// with the simulator renews its lease every half minute.
    public static let recentUse: TimeInterval = 90

    public enum Verdict: Equatable, Sendable {
        /// Still in use, or not idle for long enough yet.
        case keep
        /// No longer SimTool's to manage: drop the lease, touch nothing.
        case release(String)
        /// Used outside SimTool right now: renew the lease.
        case inUse(String)
        /// Idle, with SimTool servers still on it that should have stopped.
        case stopServers([Int32], String)
        /// Idle, nothing of SimTool's on it: shut it down.
        case shutDown(String)
    }

    /// Which leases a pass may end.
    public enum Scope: String, Codable, Sendable {
        /// The ones idle for their timeout: the reaper's pass.
        case idle
        /// Every one no SimTool server is on and nothing has used lately, idle
        /// for its timeout or not: the reaper being stopped takes down what
        /// only it was watching.
        case unserved
        /// Every one, stopping the SimTool servers on it: `simtool reap --all`.
        case all
    }

    /// - Parameters:
    ///   - device: the simulator as simctl lists it now; nil when it is gone.
    ///   - currentBootPID: its `launchd_sim` now, when known.
    ///   - liveServers: PIDs of running SimTool servers on it.
    ///   - externalUse: why something outside SimTool uses it right now.
    public static func verdict(
        for lease: SimulatorLease,
        device: SimulatorDevice?,
        currentBootPID: Int32?,
        liveServers: [Int32],
        externalUse: String?,
        now: Date,
        scope: Scope = .idle
    ) -> Verdict {
        guard let device else { return .release("the simulator no longer exists") }
        if device.state == "Booting" { return .keep }
        guard device.state == "Booted" else { return .release("it is \(device.state.lowercased())") }
        if let held = lease.bootPID, let current = currentBootPID, held != current {
            return .release("it was booted again outside SimTool")
        }
        if let externalUse { return .inUse(externalUse) }
        let idle = lease.idle(at: now)
        let idleFor = "unused for \(SimulatorIdleTimeout.duration(idle))"
        switch scope {
        case .all:
            return liveServers.isEmpty ? .shutDown("asked to; \(idleFor)") : .stopServers(liveServers, "asked to; \(idleFor)")
        case .unserved:
            return liveServers.isEmpty && idle >= recentUse ? .shutDown("SimTool's reaper stopped; \(idleFor)") : .keep
        case .idle:
            guard lease.isIdle(at: now) else { return .keep }
            if liveServers.isEmpty { return .shutDown(idleFor) }
            return idle >= lease.effectiveIdleTimeout + serverGrace ? .stopServers(liveServers, idleFor) : .keep
        }
    }
}
