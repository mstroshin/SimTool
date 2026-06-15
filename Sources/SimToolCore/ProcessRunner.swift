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

public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
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
                if let timeoutSeconds {
                    Task.detached {
                        try? await Task.sleep(for: .milliseconds(Int(timeoutSeconds * 1000)))
                        completion.resumeOnce {
                            if process.isRunning { process.terminate() }
                            continuation.resume(throwing: SimToolError(
                                "Process timed out after \(timeoutSeconds) seconds: \(executable.path) \(arguments.joined(separator: " "))"
                            ))
                        }
                    }
                }
            } catch {
                // The two pipeEOF.enter()s are deliberately abandoned here: the child
                // never started, no EOF will arrive, and nothing waits on the group.
                completion.resumeOnce { continuation.resume(throwing: error) }
            }
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

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        let data = storage
        lock.unlock()
        return data
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
