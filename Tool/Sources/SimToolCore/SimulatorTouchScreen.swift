import Foundation

/// Whether iOS still takes the touches the helper sends a booted simulator.
///
/// The helper touches through Indigo, which reaches iOS as a SimulatorHID touch
/// screen in backboardd. When the simulator's HID daemon, dtuhidd, starts,
/// backboardd stands down the touch screens nothing has used yet in that boot;
/// the next touch brings the screen back, but backboardd never takes it as a
/// digitizer again, and every Indigo touch after that is dropped without a trace
/// while the helper reports success. Measured on iOS 26.4 and 27.0 under
/// CoreSimulator 1171.7. dtuhidd starts with its first client: often at boot,
/// which is harmless (the screen comes up later, with the first touch), or
/// later — with the helper's first key, as in the case that found this. The
/// helper claims the screen when it starts, so nothing started after it can
/// do this; a screen stood down before SimTool first reached the device stays
/// lost until the simulator reboots.
///
/// backboardd's log is the only witness: a touch screen stood down in this boot
/// and not attached since means touches go nowhere.
public enum SimulatorTouchScreen {
    /// SimulatorHID connecting or standing down a touch screen, BackBoard
    /// attaching a digitizer, and the dtuhidd state every backboardd logs once
    /// it is up.
    static let logPredicate = """
        process == "backboardd" AND (eventMessage CONTAINS "ScreenTouchService" \
        OR eventMessage BEGINSWITH "digitizer attached" \
        OR eventMessage CONTAINS "SimHIDVirtualServiceManager: dtuhidd state")
        """

    static func cutOffMessage(deviceUDID: String) -> String {
        """
        Touches are not reaching simulator \(deviceUDID): on this boot iOS dropped the touch screen SimTool drives, \
        which it does when the simulator's HID daemon (dtuhidd) starts before anything has touched the screen. \
        Reboot the simulator to get touches back: \
        xcrun simctl shutdown \(deviceUDID) && xcrun simctl boot \(deviceUDID)
        """
    }

    /// Reads `log show --style ndjson` lines, oldest first. Only the last
    /// backboardd counts: one that restarts brings its screens up afresh.
    static func isCutOff(log: Data) -> Bool {
        struct Entry: Decodable {
            var processID: Int?
            var eventMessage: String?
        }
        let entries = log.split(separator: UInt8(ascii: "\n")).compactMap { line -> (process: Int, message: String)? in
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)),
                  let process = entry.processID, let message = entry.eventMessage else { return nil }
            return (process, message)
        }
        guard let current = entries.last?.process else { return false }
        var stoodDown = Set<String>()
        for entry in entries where entry.process == current {
            if entry.message.hasPrefix("Disconnecting service:"), let screen = screenIdentifier(in: entry.message) {
                stoodDown.insert(screen)
            } else if let sender = attachedSender(in: entry.message) {
                stoodDown.remove(sender)
            }
        }
        return !stoodDown.isEmpty
    }

    /// `… identifier: 0xacefade00000007 com.apple.SimulatorHID.ScreenTouchService…`
    /// → `ACEFADE00000007`, as BackBoard names the same service.
    private static func screenIdentifier(in message: String) -> String? {
        guard message.contains("com.apple.SimulatorHID.ScreenTouchService"),
              let marker = message.range(of: "identifier: 0x") else { return nil }
        let hex = message[marker.upperBound...].prefix(while: \.isHexDigit)
        return hex.isEmpty ? nil : hex.uppercased()
    }

    /// `digitizer attached (sender ACEFADE00000007)` → `ACEFADE00000007`.
    private static func attachedSender(in message: String) -> String? {
        let prefix = "digitizer attached (sender "
        guard message.hasPrefix(prefix) else { return nil }
        let hex = message.dropFirst(prefix.count).prefix(while: \.isHexDigit)
        return hex.isEmpty ? nil : hex.uppercased()
    }
}

/// Answers, once per simulator boot, whether that boot's touch screen is cut
/// off, and remembers it on disk: reading the log takes a second or two, and
/// every CLI command starts a new process. After the helper has claimed the
/// screen the answer cannot change until the simulator boots again.
struct TouchScreenCheck: Sendable {
    /// Where verdicts are kept; nil keeps none.
    var directory: URL?
    /// backboardd's log since the given boot, or nil when it cannot be read.
    var readLog: @Sendable (_ deviceUDID: String, _ since: Date) async -> Data?

    static let live = TouchScreenCheck(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimTool", isDirectory: true)
            .appendingPathComponent("TouchScreens", isDirectory: true),
        readLog: { deviceUDID, since in
            let output = try? await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "simctl", "spawn", deviceUDID, "log", "show", "--style", "ndjson",
                    "--start", logTime(since.addingTimeInterval(-1)),
                    "--predicate", SimulatorTouchScreen.logPredicate,
                ],
                timeoutSeconds: 20
            )
            guard let output, output.status == 0 else { return nil }
            return output.stdout
        }
    )

    /// A log that cannot be read counts as a screen that takes touches: the
    /// check must never stop touches that would land.
    func isCutOff(deviceUDID: String, bootedAt: Date) async -> Bool {
        if let known = recorded(deviceUDID: deviceUDID, bootedAt: bootedAt) { return known }
        guard let log = await readLog(deviceUDID, bootedAt) else { return false }
        let cutOff = SimulatorTouchScreen.isCutOff(log: log)
        record(cutOff, deviceUDID: deviceUDID, bootedAt: bootedAt)
        return cutOff
    }

    private struct Verdict: Codable {
        var bootedAt: Double
        var cutOff: Bool
    }

    private func file(for deviceUDID: String) -> URL? {
        directory?.appendingPathComponent("\(deviceUDID.uppercased()).json")
    }

    private func recorded(deviceUDID: String, bootedAt: Date) -> Bool? {
        guard let file = file(for: deviceUDID),
              let data = try? Data(contentsOf: file),
              let verdict = try? JSONDecoder().decode(Verdict.self, from: data),
              verdict.bootedAt == bootedAt.timeIntervalSince1970 else { return nil }
        return verdict.cutOff
    }

    private func record(_ cutOff: Bool, deviceUDID: String, bootedAt: Date) {
        guard let directory, let file = file(for: deviceUDID),
              let data = try? JSONEncoder().encode(Verdict(bootedAt: bootedAt.timeIntervalSince1970, cutOff: cutOff)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// `log show --start` reads local wall-clock time.
    static func logTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
