import Foundation

/// Puts simulator state into a known position before a run, from a test's
/// declarative `reset:` block.
///
/// Everything here used to be hand-written `setup:` shell — which encodes one
/// machine's paths, cannot travel with the test, and silently succeeds when it
/// does nothing at all. These operations report what they did, and a failure is
/// an infrastructure result rather than a quiet "the claim does not hold": a run
/// blocked by a permission alert reads exactly like a broken app, and that
/// confusion costs hours.
public enum SimulatorStateReset {
    public struct Outcome: Equatable, Sendable {
        /// Human-readable lines describing what was applied, for the session
        /// timeline.
        public var applied: [String] = []
        /// Why an operation could not be performed. Any entry here makes the run
        /// untrustworthy.
        public var failures: [String] = []

        public var isClean: Bool { failures.isEmpty }
    }

    /// Applies `reset` for `app` on `deviceUDID`. The app must not be running:
    /// call this before launch (a permission change terminates a running app,
    /// and wiping a live container leaves the app holding deleted files).
    public static func apply(
        _ reset: TestReset,
        deviceUDID: String,
        app: String?
    ) async -> Outcome {
        var outcome = Outcome()
        guard !reset.isEmpty else { return outcome }

        if reset.defaults || reset.container {
            guard let app, !app.isEmpty else {
                outcome.failures.append("`reset.defaults`/`reset.container` need the app's bundle id — set `app:` in the test or `bundleId:` in the project config.")
                return outcome
            }
            if reset.defaults {
                // A missing domain exits non-zero; that is "already clean",
                // not a failure.
                let output = try? await ProcessRunner.runXcrun(["simctl", "spawn", deviceUDID, "defaults", "delete", app])
                outcome.applied.append(output?.status == 0 ? "Cleared UserDefaults for \(app)" : "UserDefaults for \(app) already clean")
            }
            if reset.container {
                switch await wipeDataContainer(deviceUDID: deviceUDID, app: app) {
                case .success(let path): outcome.applied.append("Wiped data container at \(path)")
                case .failure(let message): outcome.failures.append(message)
                }
            }
        }

        for permission in reset.permissions {
            guard let app, !app.isEmpty else {
                outcome.failures.append("`reset.permissions` needs the app's bundle id — set `app:` in the test or `bundleId:` in the project config.")
                break
            }
            if let message = await applyPermission(permission, deviceUDID: deviceUDID, app: app) {
                outcome.failures.append(message)
            } else {
                outcome.applied.append("Permission \(permission.service) → \(permission.decision.rawValue)")
            }
        }

        if let language = reset.language { outcome.applied.append("Language → \(language)") }
        if let locale = reset.locale { outcome.applied.append("Locale → \(locale)") }

        return outcome
    }

    // MARK: - container

    /// `.success` carries the wiped container path, `.failure` the reason.
    private enum ContainerWipe {
        case success(String)
        case failure(String)
    }

    private static func wipeDataContainer(deviceUDID: String, app: String) async -> ContainerWipe {
        let output = try? await ProcessRunner.runXcrun(["simctl", "get_app_container", deviceUDID, app, "data"])
        guard let output, output.status == 0 else {
            let detail = (output?.stderrString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("Cannot locate the data container for \(app) on \(deviceUDID)\(detail.isEmpty ? "" : ": \(detail)"). Is the app installed?")
        }
        let path = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return .failure("simctl returned no data container path for \(app).")
        }
        // Emptying the standard subdirectories rather than deleting the
        // container keeps the app installed — a test run does not build or
        // install, so an uninstall would leave nothing to launch.
        let manager = FileManager.default
        for directory in ["Documents", "Library", "tmp", "SystemData"] {
            let url = URL(fileURLWithPath: path).appendingPathComponent(directory, isDirectory: true)
            guard let contents = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { continue }
            for entry in contents {
                do {
                    try manager.removeItem(at: entry)
                } catch {
                    return .failure("Cannot remove \(entry.path): \(error.localizedDescription)")
                }
            }
        }
        return .success(path)
    }

    // MARK: - permissions

    /// Returns nil on success, or a message explaining why the permission could
    /// not be set.
    private static func applyPermission(
        _ permission: TestPermission,
        deviceUDID: String,
        app: String
    ) async -> String? {
        if permission.service == TestPermission.appTrackingService {
            return await applyAppTracking(permission.decision, deviceUDID: deviceUDID, app: app)
        }
        let action: String
        switch permission.decision {
        case .grant: action = "grant"
        case .deny: action = "revoke"
        case .reset: action = "reset"
        }
        let output = try? await ProcessRunner.runXcrun(["simctl", "privacy", deviceUDID, action, permission.service, app])
        guard let output, output.status == 0 else {
            let detail = (output?.stderrString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "simctl privacy \(action) \(permission.service) failed\(detail.isEmpty ? "" : ": \(detail)")"
        }
        return nil
    }

    /// App Tracking Transparency is not a `simctl privacy` service, so it is set
    /// in the device's TCC database directly. Denied is the interesting answer
    /// far more often than granted: apps read the status, and a denied device is
    /// what most real users look like.
    private static func applyAppTracking(
        _ decision: TestPermission.Decision,
        deviceUDID: String,
        app: String
    ) async -> String? {
        let database = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            .appendingPathComponent(deviceUDID)
            .appendingPathComponent("data/Library/TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: database.path) else {
            return "No TCC database for \(deviceUDID) — boot the simulator once before pre-answering `att`."
        }
        let statement: String
        switch decision {
        case .reset:
            statement = "DELETE FROM access WHERE service='kTCCServiceUserTracking' AND client='\(app)';"
        case .grant, .deny:
            // auth_value: 0 denied, 2 allowed. auth_reason 2 = set by the user.
            let value = decision == .grant ? 2 : 0
            statement = """
            INSERT OR REPLACE INTO access \
            (service, client, client_type, auth_value, auth_reason, auth_version) \
            VALUES ('kTCCServiceUserTracking','\(app)',0,\(value),2,1);
            """
        }
        let output = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [database.path, statement],
            timeoutSeconds: 30
        )
        guard let output, output.status == 0 else {
            let detail = (output?.stderrString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "Cannot set App Tracking Transparency in TCC.db\(detail.isEmpty ? "" : ": \(detail)")"
        }
        return nil
    }
}
