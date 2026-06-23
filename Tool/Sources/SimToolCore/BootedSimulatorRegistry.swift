import Foundation

/// Tracks the simulators that *this* SimTool process booted itself, so the
/// shutdown path can power them back down on exit. Simulators that were already
/// booted when SimTool attached are never recorded and therefore never shut
/// down - SimTool only cleans up what it started.
public final class BootedSimulatorRegistry: @unchecked Sendable {
    public static let shared = BootedSimulatorRegistry()

    private let lock = NSLock()
    private var udids: [String] = []

    public init() {}

    /// Records a UDID SimTool booted. Idempotent and order-preserving.
    public func record(_ udid: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !udids.contains(udid) else { return }
        udids.append(udid)
    }

    /// Drops a UDID (e.g. after it has been shut down). Unknown UDIDs are ignored.
    public func forget(_ udid: String) {
        lock.lock()
        defer { lock.unlock() }
        udids.removeAll { $0 == udid }
    }

    /// A snapshot of the UDIDs SimTool booted, in the order they were booted.
    public func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return udids
    }
}
