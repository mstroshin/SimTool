import Foundation
import SimToolCore

/// The device's settings as viewers read them. Reading them is half a dozen
/// simctl calls, so one reading runs at a time and every viewer that asks
/// while it runs, or just after, shares it. A change made through the server
/// drops it, and the next reading starts afresh.
final class DeviceSettingsReader: @unchecked Sendable {
    private let read: @Sendable () async -> SimulatorSettings
    private let freshFor: TimeInterval
    private let lock = NSLock()
    private var last: (settings: SimulatorSettings, at: Date, generation: Int)?
    private var reading: (task: Task<SimulatorSettings, Never>, generation: Int)?
    private var generation = 0

    init(freshFor: TimeInterval = 1.5, read: @escaping @Sendable () async -> SimulatorSettings) {
        self.freshFor = freshFor
        self.read = read
    }

    func current() async -> SimulatorSettings {
        let task: Task<SimulatorSettings, Never> = lock.withLock {
            if let last, last.generation == generation, Date().timeIntervalSince(last.at) < freshFor {
                let settings = last.settings
                return Task { settings }
            }
            if let reading, reading.generation == generation { return reading.task }
            let started = generation
            let task = Task { [read] in await read() }
            reading = (task, started)
            Task { [weak self] in
                let settings = await task.value
                self?.lock.withLock {
                    if self?.reading?.generation == started { self?.reading = nil }
                    self?.last = (settings, Date(), started)
                }
            }
            return task
        }
        return await task.value
    }

    /// Something changed the device: what was read before it is stale.
    func invalidate() {
        lock.withLock { generation += 1 }
    }
}
