import Darwin
import Foundation
import SimToolCore

/// The CLI's side of `SimulatorLease`: taking a lease where SimTool takes on
/// a simulator, and keeping the reaper running while any is held.
enum SimulatorHold {
    /// The idle timeout a command runs under: its flag, then
    /// `SIMTOOL_IDLE_TIMEOUT`, then `idleTimeout:` in the config; nil for the
    /// default.
    static func idleTimeout(
        flag: String?,
        config: ProjectConfig?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TimeInterval? {
        if let flag { return try SimulatorIdleTimeout.parse(flag) }
        if let value = environment[SimulatorIdleTimeout.environmentKey] {
            do {
                return try SimulatorIdleTimeout.parse(value)
            } catch {
                throw SimToolError("\(SimulatorIdleTimeout.environmentKey)=\(value): \((error as? SimToolError)?.message ?? error.localizedDescription)")
            }
        }
        return config?.idleTimeout
    }

    /// Boots `device` when it is not booted, under SimTool's lease unless
    /// `lease` is false, and makes sure the reaper watches it.
    static func boot(_ device: SimulatorDevice, idleTimeout: TimeInterval?, lease: Bool = true) async throws -> SimulatorDevice {
        let booted = try await SimulatorDeviceClient.ensureBooted(device, lease: lease, idleTimeout: idleTimeout)
        LeaseReaper.ensureRunning()
        return booted
    }

    /// A server is starting on `device`: SimTool holds it from now on,
    /// whoever booted it — a script's `simctl boot` ahead of `serve` included.
    static func adopt(_ device: SimulatorDevice, idleTimeout: TimeInterval?) async -> SimulatorLease {
        let bootPID = await SimulatorProcessSnapshot.take().bootPID(of: device.udid)
        let lease = SimulatorLeaseStore.shared.take(device, booted: false, bootPID: bootPID, idleTimeout: idleTimeout)
        LeaseReaper.ensureRunning()
        return lease
    }

    /// Renews the lease on `udid` every half minute until cancelled: a command
    /// busy with the simulator for long without a word to it — a build for it,
    /// above all one in Xcode, where no `xcodebuild` says whose it is — must
    /// not see it shut down under it.
    static func keepAlive(_ udid: String) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                SimulatorLeaseStore.shared.touch(udid: udid)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Said on stderr when a command boots the simulator it was asked to drive.
    static func bootNote(_ device: SimulatorDevice, idleTimeout: TimeInterval?) -> String {
        let timeout = idleTimeout ?? SimulatorIdleTimeout.defaultSeconds
        let after = timeout > 0 ? " — SimTool shuts it down again after \(SimulatorIdleTimeout.describe(timeout)) unused" : ""
        return "Booting \(device.name) (\(device.udid))\(after)."
    }
}

/// The simulator a command acts on — resolved as `resolveConfiguredDevice`
/// does — booted. One that is shut down — SimTool powered it down after it sat
/// idle, or nobody booted it yet — boots first, under SimTool's lease; a lease
/// SimTool already holds on it is renewed.
func resolveDeviceToDrive(_ value: String?) async throws -> SimulatorDevice {
    let config = try ProjectConfigLoader.loadIfPresent()
    let device = try await SimulatorDeviceClient.resolve(value, configuredSimulator: config?.simulator)
    guard device.state != "Booted" else {
        if SimulatorLeaseStore.shared.touch(udid: device.udid) != nil { LeaseReaper.ensureRunning() }
        return device
    }
    let idleTimeout = try SimulatorHold.idleTimeout(flag: nil, config: config)
    FileHandle.standardError.write(Data((SimulatorHold.bootNote(device, idleTimeout: idleTimeout) + "\n").utf8))
    return try await SimulatorHold.boot(device, idleTimeout: idleTimeout)
}

/// The background reaper, `simtool reap --watch`: one per machine, running
/// while SimTool holds any simulator. Every half minute it shuts down the
/// ones idle for their timeout that no server of SimTool's is on — booted by
/// a command, left behind by a server that was SIGKILLed — and it exits once
/// SimTool holds none. A server ends its own simulator's lease; the reaper is
/// for the rest.
enum LeaseReaper {
    static let interval: Duration = .seconds(30)

    static var lockURL: URL { SimulatorLeaseStore.shared.root.appendingPathComponent("reaper.lock") }
    static var logURL: URL { SimulatorLeaseStore.shared.root.appendingPathComponent("reaper.log") }

    /// Starts the reaper unless one runs or SimTool holds nothing.
    static func ensureRunning() {
        guard !SimulatorLeaseStore.shared.list().isEmpty, !isRunning() else { return }
        spawn()
    }

    /// Whether a reaper holds the lock.
    static func isRunning() -> Bool {
        guard let fd = openLock() else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    /// A process of its own session — no terminal's Ctrl-C reaches it — with
    /// none of this one's descriptors: holding a caller's stdout pipe open
    /// would keep `simtool … | tail` waiting until the reaper exits. Signals
    /// start out unblocked and at their defaults: the concurrency threads this
    /// runs on block SIGTERM and friends, and a child inherits that mask —
    /// a reaper deaf to `kill` would never run its cleanup.
    private static func spawn() {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let arguments = [executable, "reap", "--watch"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, &argv, environ)
        guard status == 0 else {
            DebugLog.write("reaper", "could not start \(executable) reap --watch: \(String(cString: strerror(status)))")
            return
        }
        // Collected when it exits, or a long-lived server would keep a zombie.
        DispatchQueue.global(qos: .utility).async {
            var exitStatus: Int32 = 0
            _ = waitpid(pid, &exitStatus, 0)
        }
    }

    /// The reaper's loop. Returns at once when another reaper holds the lock.
    static func watch() async {
        guard let lock = acquire() else { return }
        var held = lock
        log("watching \(SimulatorLeaseStore.shared.root.path)")
        // Stopping the reaper takes down what only it was watching; a server
        // lets go of its own simulator when it stops.
        SignalTrap.shared.installCleanup {
            for outcome in await SimulatorLeaseSweep().run(scope: .unserved) where outcome.action != .kept {
                log(describe(outcome))
            }
        }
        while !Task.isCancelled {
            for outcome in await SimulatorLeaseSweep().run() where outcome.action != .kept {
                log(describe(outcome))
            }
            if SimulatorLeaseStore.shared.list().isEmpty {
                // A lease taken between the listing and the unlock still finds
                // a reaper: either this one sees it on the second look, or the
                // command that took it finds the lock free and starts one.
                flock(held, LOCK_UN)
                close(held)
                guard !SimulatorLeaseStore.shared.list().isEmpty, let again = acquire() else {
                    log("no simulator held — exiting")
                    return
                }
                held = again
            }
            try? await Task.sleep(for: interval)
        }
    }

    static func describe(_ outcome: SimulatorLeaseSweep.Outcome) -> String {
        let what: String
        switch outcome.action {
        case .kept: what = "kept"
        case .released: what = "no longer held"
        case .inUse: what = "in use"
        case .stoppedServers: what = "stopped its servers and shut down"
        case .shutDown: what = "shut down"
        }
        return "\(outcome.name) (\(outcome.udid)): \(what)" + (outcome.reason.map { " — \($0)" } ?? "")
    }

    private static func acquire() -> Int32? {
        guard let fd = openLock() else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func openLock() -> Int32? {
        try? FileManager.default.createDirectory(at: SimulatorLeaseStore.shared.root, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        return fd >= 0 ? fd : nil
    }

    private static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardOutput.write(Data("\(stamp) [\(getpid())] \(line)\n".utf8))
    }
}
