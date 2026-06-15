import Darwin
import Foundation

public struct PortReclaimResult: Codable, Equatable, Sendable {
    public var port: UInt16
    public var pids: [Int32]
    public var terminatedPids: [Int32]
    public var killedPids: [Int32]

    public init(port: UInt16, pids: [Int32], terminatedPids: [Int32], killedPids: [Int32]) {
        self.port = port
        self.pids = pids
        self.terminatedPids = terminatedPids
        self.killedPids = killedPids
    }
}

public enum PortReclaimer {
    public static func isAddressInUse(_ error: Error) -> Bool {
        let text = "\(error) \(error.localizedDescription)".lowercased()
        return text.contains("address already in use")
            || text.contains("bindfailed")
            || text.contains("eaddrinuse")
    }

    public static func parsePIDs(_ output: String, excluding currentPID: Int32 = Darwin.getpid()) -> [Int32] {
        var seen = Set<Int32>()
        return output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" })
            .compactMap { Int32($0) }
            .filter { pid in
                guard pid > 0, pid != currentPID, !seen.contains(pid) else { return false }
                seen.insert(pid)
                return true
            }
    }

    public static func listeningPIDs(port: UInt16) async throws -> [Int32] {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"],
            timeoutSeconds: 3
        )
        if output.status == 1 { return [] }
        guard output.status == 0 else {
            throw SimToolError(output.stderrString.isEmpty ? "lsof failed while checking port \(port)" : output.stderrString)
        }
        return parsePIDs(output.stdoutString)
    }

    public static func reclaim(port: UInt16, waitSeconds: TimeInterval = 3) async throws -> PortReclaimResult {
        let pids = try await listeningPIDs(port: port)
        guard !pids.isEmpty else {
            return PortReclaimResult(port: port, pids: [], terminatedPids: [], killedPids: [])
        }

        var terminated: [Int32] = []
        for pid in pids where Darwin.kill(pid, SIGTERM) == 0 {
            terminated.append(pid)
        }

        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            if try await listeningPIDs(port: port).isEmpty {
                return PortReclaimResult(port: port, pids: pids, terminatedPids: terminated, killedPids: [])
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let remaining = try await listeningPIDs(port: port)
        var killed: [Int32] = []
        for pid in remaining where Darwin.kill(pid, SIGKILL) == 0 {
            killed.append(pid)
        }

        let killDeadline = Date().addingTimeInterval(2)
        while Date() < killDeadline {
            if try await listeningPIDs(port: port).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        return PortReclaimResult(port: port, pids: pids, terminatedPids: terminated, killedPids: killed)
    }
}
