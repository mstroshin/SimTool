import Foundation
import SimToolCore

/// Starts a server for a command that needs one and was not given one.
///
/// Deliberately unlike `simtool serve`: it never reclaims a port. A user who
/// types `serve --port 3200` has said which port they want; a test run that
/// needs *some* server has not, and killing whoever is on 3200 to get one would
/// be a surprise the caller never asked for.
enum ServerAutostart {
    /// How many ports upward from the configured one to consider.
    static let portSearchLimit = 10

    static func freePort(
        startingAt start: UInt16,
        limit: Int = portSearchLimit,
        probe: (UInt16) async throws -> [Int32] = { try await PortReclaimer.listeningPIDs(port: $0) }
    ) async throws -> UInt16 {
        var candidates: [UInt16] = []
        for offset in 0..<max(1, limit) {
            guard let port = UInt16(exactly: Int(start) + offset) else { break }
            candidates.append(port)
        }
        for port in candidates where ((try? await probe(port)) ?? [1]).isEmpty {
            return port
        }
        throw SimToolError("""
            No free port in \(start)–\(candidates.last ?? start) to start a server on. \
            Start one yourself (`simtool serve --port <free>`) and pass `--server`.
            """)
    }

    /// The session of a server started here, on a port nobody was listening on.
    /// Retries on the next port when the bind loses a race with something that
    /// grabbed it between the probe and the spawn.
    static func start(parameters: ServeParameters, json: Bool) async throws -> SessionInfo {
        var attempt = parameters
        var lastError: Error?
        for _ in 0..<3 {
            attempt.port = try await freePort(startingAt: attempt.port)
            do {
                let session = try await launchDetachedServer(
                    parameters: attempt,
                    app: nil,
                    verbose: false,
                    reclaimPort: false
                )
                emitNote("No SimTool server running — started one on \(session.url)", json: json)
                return session
            } catch {
                lastError = error
                guard attempt.port < UInt16.max else { break }
                attempt.port += 1
            }
        }
        throw lastError ?? SimToolError("Could not start a SimTool server.")
    }
}
