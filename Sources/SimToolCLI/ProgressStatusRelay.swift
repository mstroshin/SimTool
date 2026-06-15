import Foundation

/// Forwards live progress statuses into a Noora progressStep `updateMessage`
/// callback, prefixed with the stage message. Drops duplicate statuses and
/// rate-limits distinct ones so fast xcodebuild output does not thrash the
/// terminal renderer.
final class ProgressStatusRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStatus: String?
    private var lastUpdate = Date.distantPast
    private let prefix: String
    private let minimumInterval: TimeInterval
    private let update: @Sendable (String) -> Void

    init(prefix: String, minimumInterval: TimeInterval = 0.1, update: @escaping @Sendable (String) -> Void) {
        self.prefix = prefix
        self.minimumInterval = minimumInterval
        self.update = update
    }

    func send(_ status: String) {
        lock.lock()
        let now = Date()
        guard status != lastStatus, now.timeIntervalSince(lastUpdate) >= minimumInterval else {
            lock.unlock()
            return
        }
        lastStatus = status
        lastUpdate = now
        lock.unlock()
        update("\(prefix) · \(status)")
    }
}
