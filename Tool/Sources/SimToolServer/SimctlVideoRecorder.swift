import Darwin
import Foundation

/// Records the simulator screen with `xcrun simctl io recordVideo`. SIGINT on
/// stop makes simctl finalize the mp4 (write the moov atom); escalation only
/// kicks in if it hangs.
public final class SimctlVideoRecorder: TestVideoRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private let display: @Sendable () -> String?
    private var process: Process?
    private var stopping = false
    private var errorOutput = Data()
    private var exitFailure: String?

    /// `display` names the screen to record when the device has several —
    /// simctl refuses to choose — read as the recording starts.
    public init(display: @escaping @Sendable () -> String? = { nil }) {
        self.display = display
    }

    public func start(deviceUDID: String, outputFile: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = Self.arguments(deviceUDID: deviceUDID, display: display(), outputFile: outputFile)
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            self.lock.withLock { if self.errorOutput.count < 4096 { self.errorOutput.append(data) } }
        }
        // simctl that gives up by itself — a screen it cannot record — leaves
        // no file; what it said is the session's reason for having no video.
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.withLock {
                guard !self.stopping, process.terminationStatus != 0 else { return }
                let said = String(data: self.errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.exitFailure = "simctl recordVideo exited (\(process.terminationStatus))" + (said.isEmpty ? "" : ": " + said)
            }
        }
        try process.run()
        lock.withLock { self.process = process }
    }

    static func arguments(deviceUDID: String, display: String?, outputFile: URL) -> [String] {
        ["simctl", "io", deviceUDID, "recordVideo", "--codec", "h264"] + (display.map { ["--display=\($0)"] } ?? []) + ["--force", outputFile.path]
    }

    public var failure: String? {
        lock.withLock { exitFailure }
    }

    public func stop() async {
        let process = lock.withLock {
            stopping = true
            defer { self.process = nil }
            return self.process
        }
        guard let process, process.isRunning else { return }
        process.interrupt()
        for _ in 0..<50 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
    }
}
