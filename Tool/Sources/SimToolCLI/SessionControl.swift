import Darwin
import Foundation
import SimToolCore

enum SessionControl {
    /// Stops a server session and cleans up after it.
    ///
    /// SIGTERM first, so the server runs its own graceful shutdown — which
    /// includes powering down the simulators it booted. If it will not die,
    /// force it and power those simulators down here instead, so a wedged or
    /// detached server cannot leak the simulator backend.
    static func stop(_ session: SessionInfo) async {
        Darwin.kill(session.pid, SIGTERM)
        for _ in 0..<60 where isProcessAlive(session.pid) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isProcessAlive(session.pid) {
            Darwin.kill(session.pid, SIGKILL)
            for udid in session.bootedDevices {
                await SimulatorDeviceClient.shutdown(udid)
            }
        }
        SessionStore.shared.remove(session.sessionId)
    }
}
