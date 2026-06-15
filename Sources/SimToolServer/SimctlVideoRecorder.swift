import Darwin
import Foundation

/// Records the simulator screen with `xcrun simctl io recordVideo`. SIGINT on
/// stop makes simctl finalize the mp4 (write the moov atom); escalation only
/// kicks in if it hangs.
public final class SimctlVideoRecorder: TestVideoRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    public init() {}

    public func start(deviceUDID: String, outputFile: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", deviceUDID, "recordVideo", "--codec", "h264", "--force", outputFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        lock.lock()
        self.process = process
        lock.unlock()
    }

    public func stop() async {
        lock.lock()
        let process = self.process
        self.process = nil
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.interrupt()
        for _ in 0..<50 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
    }
}
