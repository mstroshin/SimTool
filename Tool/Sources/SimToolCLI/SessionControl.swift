import Darwin
import Foundation
import SimToolCore

enum SessionControl {
    /// Stops a server session and cleans up after it.
    ///
    /// SIGTERM first, so the server runs its own graceful shutdown — which
    /// lets go of the simulator it holds. If it will not die, or was already
    /// gone, let go of that simulator here instead, so a wedged, detached or
    /// crashed server cannot leak the simulator backend.
    static func stop(_ session: SessionInfo) async {
        guard !(await SessionStore.shared.terminate(session)) else { return }
        if await SimulatorLeaseSweep().release(udid: session.device.udid, leaving: session.pid) == nil, !session.bootedDevices.isEmpty {
            // An older SimTool's server names what it booted instead — while
            // that boot is still the one running.
            let snapshot = await SimulatorProcessSnapshot.take()
            for udid in session.bootedDevices where isBootOf(udid, knownTo: [session], in: snapshot) {
                await SimulatorDeviceClient.shutdown(udid)
            }
        }
        LeaseReaper.ensureRunning()
    }
}
