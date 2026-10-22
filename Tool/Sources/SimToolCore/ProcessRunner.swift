import Darwin
import Foundation

public struct ProcessOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

/// A process `ProcessRunner` stopped for running past its time limit.
public struct ProcessTimeoutError: Error, LocalizedError, Sendable {
    public var seconds: TimeInterval
    public var command: String

    public init(seconds: TimeInterval, command: String) {
        self.seconds = seconds
        self.command = command
    }

    public var errorDescription: String? {
        "Process timed out after \(seconds) seconds: \(command)"
    }
}

/// Where `ProcessRunner.run` writes a process's whole output — stdout and
/// stderr, as they arrive — keeping only the end of each stream in memory.
/// A long build's log runs to hundreds of megabytes: on disk it can be read in
/// full after a failure, in memory it would only cost.
public struct ProcessOutputLog: Sendable {
    public var url: URL
    /// The bytes of each stream the returned `ProcessOutput` keeps: its end.
    public var retainedBytes: Int

    public init(url: URL, retainedBytes: Int = 64 * 1024) {
        self.url = url
        self.retainedBytes = retainedBytes
    }
}

public enum ProcessRunner {
    /// Runs a process to completion. With `log`, its output also goes to that
    /// file, replacing what was there, and the returned output holds only the
    /// end of each stream; `onStdoutLine` still sees every line.
    ///
    /// A child gets a process group of its own, so Ctrl-C at the terminal
    /// reaches SimTool alone. With `stopsWithSimTool` it does not outlive
    /// SimTool: `stopChildren()` — which the CLI's signal trap calls — and a
    /// timeout interrupt it and wait until it is gone. A build left running on
    /// its own would go on writing its DerivedData after SimTool's lock on it
    /// is released.
    public static func run(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeoutSeconds: TimeInterval? = nil,
        log: ProcessOutputLog? = nil,
        stopsWithSimTool: Bool = false,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        // Tools whose output depends on where they run from — `zip` stores paths
        // relative to the working directory — need it set rather than inherited.
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutBuffer = ProcessOutputBuffer(limit: log?.retainedBytes)
        let stderrBuffer = ProcessOutputBuffer(limit: log?.retainedBytes)
        let logWriter = try log.map { try ProcessLogWriter(url: $0.url) }
        let lineSplitter = onStdoutLine.map { LineSplitter(onLine: $0) }
        process.standardOutput = stdout
        process.standardError = stderr
        // EOF signals serialize the final flush with in-flight readability-handler invocations.
        let pipeEOF = DispatchGroup()
        pipeEOF.enter()
        pipeEOF.enter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lineSplitter?.flush()
                pipeEOF.leave()
            } else {
                logWriter?.write(data)
                stdoutBuffer.append(data)
                lineSplitter?.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                pipeEOF.leave()
            } else {
                logWriter?.write(data)
                stderrBuffer.append(data)
            }
        }

        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completion = ProcessCompletion()
            process.terminationHandler = { proc in
                pipeEOF.wait()
                logWriter?.close()
                guard !stopsWithSimTool || !RunningChildren.shared.remove(proc) else {
                    // Stopped because SimTool is going away: it exits with the
                    // signal's status, so nothing reports this as a failure.
                    // The run stays suspended until then — kept, not dropped.
                    RunningChildren.shared.park(continuation)
                    return
                }
                completion.resumeOnce {
                    continuation.resume(returning: ProcessOutput(
                        status: proc.terminationStatus,
                        stdout: stdoutBuffer.data(),
                        stderr: stderrBuffer.data()
                    ))
                }
            }

            do {
                try process.run()
                if stopsWithSimTool { RunningChildren.shared.add(process) }
                if let timeoutSeconds {
                    Task.detached {
                        try? await Task.sleep(for: .milliseconds(Int(timeoutSeconds * 1000)))
                        completion.resumeOnce {
                            // A child that must not outlive SimTool is gone
                            // before the timeout is reported.
                            if stopsWithSimTool {
                                stop([process])
                            } else if process.isRunning {
                                process.terminate()
                            }
                            continuation.resume(throwing: ProcessTimeoutError(
                                seconds: timeoutSeconds,
                                command: "\(executable.path) \(arguments.joined(separator: " "))"
                            ))
                        }
                    }
                }
            } catch {
                // The two pipeEOF.enter()s are deliberately abandoned here: the child
                // never started, no EOF will arrive, and nothing waits on the group.
                logWriter?.close()
                completion.resumeOnce { continuation.resume(throwing: error) }
            }
        }
    }

    /// Stops every running child started with `stopsWithSimTool` and returns
    /// once they are gone: for SimTool's own exit on a signal. Their runs never
    /// return. Blocks the calling thread for up to `grace` plus a moment.
    public static func stopChildren(grace: TimeInterval = 10) {
        stop(RunningChildren.shared.beginStopping(), grace: grace)
    }

    /// Interrupts `processes` as Ctrl-C at their terminal would — SIGINT to
    /// each one's process group, so xcodebuild cancels its build and the
    /// compilers under it stop too — then kills what is left after `grace`.
    static func stop(_ processes: [Process], grace: TimeInterval = 10) {
        let running = processes.filter(\.isRunning)
        guard !running.isEmpty else { return }
        for process in running { deliver(SIGINT, to: process) }
        let deadline = Date().addingTimeInterval(grace)
        while running.contains(where: \.isRunning), Date() < deadline {
            usleep(50_000)
        }
        for process in running where process.isRunning { deliver(SIGKILL, to: process) }
        let killed = Date().addingTimeInterval(2)
        while running.contains(where: \.isRunning), Date() < killed {
            usleep(20_000)
        }
    }

    private static func deliver(_ signal: Int32, to process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if getpgid(pid) == pid {
            killpg(pid, signal)
        } else {
            kill(pid, signal)
        }
    }

    public static func runXcrun(_ arguments: [String]) async throws -> ProcessOutput {
        try await run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments)
    }

    public static func runFor(
        executable: URL,
        arguments: [String],
        durationSeconds: TimeInterval,
        environment: [String: String]? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutBuffer.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrBuffer.append(data) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completion = ProcessCompletion()
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                completion.resumeOnce {
                    continuation.resume(returning: ProcessOutput(
                        status: proc.terminationStatus,
                        stdout: stdoutBuffer.data(),
                        stderr: stderrBuffer.data()
                    ))
                }
            }
            do {
                try process.run()
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(Int(durationSeconds * 1000)))
                    if process.isRunning { process.terminate() }
                    try? await Task.sleep(for: .milliseconds(500))
                    if process.isRunning { process.interrupt() }
                    try? await Task.sleep(for: .milliseconds(500))
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            } catch {
                completion.resumeOnce { continuation.resume(throwing: error) }
            }
        }
    }
}

/// The children that must not outlive SimTool (`stopsWithSimTool`).
private final class RunningChildren: @unchecked Sendable {
    static let shared = RunningChildren()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var stopping = false
    private var parked: [Any] = []

    func add(_ process: Process) {
        lock.lock()
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    /// Forgets an exited child; true when SimTool is stopping it.
    func remove(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        processes[ObjectIdentifier(process)] = nil
        return stopping
    }

    /// Holds a run that will never return, as SimTool is exiting.
    func park(_ continuation: Any) {
        lock.lock()
        parked.append(continuation)
        lock.unlock()
    }

    func beginStopping() -> [Process] {
        lock.lock()
        defer { lock.unlock() }
        stopping = true
        return Array(processes.values)
    }
}

/// A stream's output: all of it, or with a `limit` only its last `limit`
/// bytes, cut at a character boundary so the end still decodes as UTF-8.
private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let limit: Int?

    init(limit: Int? = nil) {
        self.limit = limit.map { max(0, $0) }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        // Trim in batches, not on every chunk: copying the tail is the cost.
        if let limit, storage.count > limit * 2 + 4_096 {
            storage = Self.tail(of: storage, limit: limit)
        }
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        let data = limit.map { Self.tail(of: storage, limit: $0) } ?? storage
        lock.unlock()
        return data
    }

    private static func tail(of data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        var start = data.endIndex - limit
        // Skip UTF-8 continuation bytes (10xxxxxx) left by the cut.
        while start < data.endIndex, data[start] & 0xC0 == 0x80 { start += 1 }
        return Data(data[start...])
    }
}

/// Appends a process's output to its log file as it arrives; both streams
/// write through one lock, so the file reads in arrival order.
private final class ProcessLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SimToolError("Unable to create log file \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) {
        lock.lock()
        // A full disk costs the log, not the process it records.
        try? handle?.write(contentsOf: data)
        lock.unlock()
    }

    func close() {
        lock.lock()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }
}

private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        partial.append(data)
        var lines: [String] = []
        while let newlineIndex = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = partial[partial.startIndex ..< newlineIndex]
            partial.removeSubrange(partial.startIndex ... newlineIndex)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }

    func flush() {
        lock.lock()
        let remaining = partial
        partial = Data()
        lock.unlock()
        if !remaining.isEmpty, let line = String(data: remaining, encoding: .utf8), !line.isEmpty {
            onLine(line)
        }
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func resumeOnce(_ work: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        work()
    }
}
