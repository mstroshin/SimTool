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

    /// Whether a failed spawn is worth another port. Only a port somebody has
    /// taken since the probe is: the child boots the simulator before it binds,
    /// so that window is wide enough to lose. Every other failure — no booted
    /// simulator, bad parameters — fails the same way on the next port.
    ///
    /// Note the inverted logic versus `freePort`: there, a probe that cannot answer
    /// counts as occupied (be pessimistic before taking a port); here, a probe that
    /// cannot answer counts as *not* a collision, so the real error surfaces instead
    /// of being buried under two more spawns.
    static func lostThePort(
        _ port: UInt16,
        probe: (UInt16) async throws -> [Int32] = { try await PortReclaimer.listeningPIDs(port: $0) }
    ) async -> Bool {
        !((try? await probe(port)) ?? []).isEmpty
    }

    /// The session of a server started here, on a port nobody was listening on.
    /// Retries on the next port only when the port was taken in a race between the
    /// probe and the spawn. The child boots the simulator before it binds, making
    /// that window real and worth recovering from. Other failures — no booted
    /// simulator, bad parameters — fail the same way on the next port, so they are
    /// not retried.
    static func start(parameters: ServeParameters, config: String?, json: Bool) async throws -> SessionInfo {
        var attempt = parameters
        var lastError: Error?
        for _ in 0..<3 {
            attempt.port = try await freePort(startingAt: attempt.port)
            do {
                let session = try await launchDetachedServer(
                    parameters: attempt,
                    app: nil,
                    verbose: false,
                    reclaimPort: false,
                    config: config
                )
                emitNote("No SimTool server running — started one on \(session.url)", json: json)
                return session
            } catch {
                lastError = error
                guard await lostThePort(attempt.port), attempt.port < UInt16.max else { throw error }
                attempt.port += 1
            }
        }
        throw lastError ?? SimToolError("Could not start a SimTool server.")
    }
}
