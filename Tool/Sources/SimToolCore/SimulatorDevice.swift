import Foundation

public struct SimulatorDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String { udid }
    public var udid: String
    public var name: String
    public var runtime: String
    public var state: String
    public var isAvailable: Bool

    public init(udid: String, name: String, runtime: String, state: String, isAvailable: Bool) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
        self.isAvailable = isAvailable
    }
}

public struct DeviceListPayload: Codable, Equatable, Sendable {
    public var devices: [SimulatorDevice]
    public var selected: String?

    public init(devices: [SimulatorDevice], selected: String? = nil) {
        self.devices = devices
        self.selected = selected
    }
}

public enum SimulatorDeviceClient {
    public static func listDevices() async throws -> [SimulatorDevice] {
        let output = try await ProcessRunner.runXcrun(["simctl", "list", "devices", "--json"])
        guard output.status == 0 else {
            throw SimToolError(output.stderrString.isEmpty ? "simctl list devices failed" : output.stderrString)
        }
        return try parseDevices(output.stdout)
    }

    public static func resolve(_ value: String?) async throws -> SimulatorDevice {
        try selectDevice(value, from: await listDevices())
    }

    /// Picks the device a `value` selects from `devices`. `value` is a UDID, a
    /// (substring) name, the literal "booted", or nil/empty — the last two both
    /// select the first booted+available device, so `simulator: booted` in the
    /// config (and `--device booted`) targets whichever simulator is already
    /// running. Pure and synchronous so it is unit-tested without simctl.
    static func selectDevice(_ value: String?, from devices: [SimulatorDevice]) throws -> SimulatorDevice {
        let booted = devices.filter { $0.state == "Booted" && $0.isAvailable }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("booted") == .orderedSame {
            if let first = booted.first { return first }
            throw SimToolError("No booted simulator found. Boot a simulator, or set `simulator:` to a UDID or name (or pass --device <udid-or-name>).")
        }

        if let byUDID = devices.first(where: { $0.udid.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return byUDID
        }
        let matches = devices.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        if matches.count == 1 { return matches[0] }
        if let bootedMatch = matches.first(where: { $0.state == "Booted" }) { return bootedMatch }
        if matches.isEmpty { throw SimToolError("Unknown simulator: \(trimmed)") }
        throw SimToolError("Ambiguous simulator name '\(trimmed)'. Use a UDID.")
    }

    /// Ensures the given device is booted, booting it (and waiting for boot to
    /// complete) via `simctl bootstatus -b` when it is not. Returns the device
    /// with refreshed state. simctl operations such as install, launch, and
    /// openurl require a booted device.
    public static func ensureBooted(_ device: SimulatorDevice, timeoutSeconds: TimeInterval? = 300) async throws -> SimulatorDevice {
        if device.state == "Booted" { return device }
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "bootstatus", device.udid, "-b"],
            timeoutSeconds: timeoutSeconds
        )
        guard output.status == 0 else {
            let detail = output.stderrString.isEmpty ? output.stdoutString : output.stderrString
            throw SimToolError("Failed to boot simulator \(device.name) (\(device.udid)): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // We booted it, so we own shutting it down on exit (simulators that were
        // already booted take the early return above and are never recorded).
        BootedSimulatorRegistry.shared.record(device.udid)
        if let refreshed = try? await resolve(device.udid) { return refreshed }
        return device
    }

    /// Powers a simulator down. Best-effort: a failure (already shut down, gone)
    /// must never block process teardown, so errors are swallowed.
    public static func shutdown(_ udid: String) async {
        _ = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "shutdown", udid],
            timeoutSeconds: 30
        )
    }

    /// Brings the Simulator.app UI on screen. `simctl` boots devices headless;
    /// flows where a human watches the simulator (such as interactive
    /// deeplinks) call this after booting so the device gets a visible window.
    /// Best-effort: failure to launch Simulator.app never fails the caller.
    public static func revealSimulatorApp() async {
        _ = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-a", "Simulator"]
        )
    }

    public static func parseDevices(_ data: Data) throws -> [SimulatorDevice] {
        let decoded = try JSONDecoder().decode(SimctlDeviceList.self, from: data)
        var devices: [SimulatorDevice] = []
        for (runtime, entries) in decoded.devices.sorted(by: { $0.key < $1.key }) {
            for entry in entries where entry.isAvailable != false {
                devices.append(SimulatorDevice(
                    udid: entry.udid,
                    name: entry.name,
                    runtime: runtime,
                    state: entry.state,
                    isAvailable: entry.isAvailable ?? true
                ))
            }
        }
        return devices
    }
}

private struct SimctlDeviceList: Decodable {
    var devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Decodable {
    var name: String
    var udid: String
    var state: String
    var isAvailable: Bool?
}
