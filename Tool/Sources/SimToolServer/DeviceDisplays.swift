import Foundation
import SimToolCore

/// The served device's screens and, on a foldable, which one is lit — what the
/// stream, screenshots, recordings, touches and `/config` all follow. Filled
/// once the device type is read, updated as the device folds.
final class DeviceDisplays: @unchecked Sendable {
    private let lock = NSLock()
    private var layout: SimulatorDisplayLayout?
    private var state: SimulatorDisplayState?

    var current: (layout: SimulatorDisplayLayout?, state: SimulatorDisplayState?) {
        lock.withLock { (layout, state) }
    }

    func set(layout: SimulatorDisplayLayout) {
        lock.withLock { self.layout = layout }
    }

    /// Whether anything a viewer sees changed.
    @discardableResult
    func set(state: SimulatorDisplayState) -> Bool {
        lock.withLock {
            guard self.state != state else { return false }
            self.state = state
            return true
        }
    }

    var isFoldable: Bool { current.layout?.isFoldable == true }

    /// The lit screen of a foldable: simctl names it to screenshot or record
    /// one, and refuses to pick between two. Nil on a one-screen device.
    var activeDisplay: SimulatorDisplay? {
        let (layout, state) = current
        guard let layout, layout.isFoldable else { return nil }
        return state.flatMap { layout.display(named: $0.active) } ?? layout.displays.first
    }

    var payloads: [ServerDisplayPayload] {
        let (layout, state) = current
        return layout.map { ServerDisplayPayload.all(layout: $0, state: state) } ?? []
    }

    var topic: DeviceTopicPayload {
        DeviceTopicPayload(displays: payloads, activeDisplay: activeDisplay?.id)
    }

    /// The screen `name` asks for (`primary-1`, `inner`, `3`, `active`), or
    /// the lit one when it asks for none. Nil on a one-screen device, which
    /// takes no `--display`.
    func display(named name: String?) throws -> SimulatorDisplay? {
        let (layout, _) = current
        guard let layout, layout.isFoldable else {
            if let name, !name.isEmpty, name.lowercased() != "active", layout?.display(named: name) == nil {
                throw SimToolError("This device has one screen; display \(name) does not exist")
            }
            return nil
        }
        guard let name, !name.isEmpty, name.lowercased() != "active" else { return activeDisplay }
        guard let display = layout.display(named: name) else {
            let names = layout.displays.map { [$0.id, $0.role].compactMap { $0 }.joined(separator: " / ") }.joined(separator: ", ")
            throw SimToolError("Unknown display \(name): this device has \(names)")
        }
        return display
    }
}

/// Follows which screen of a foldable is lit, and how each picture is turned,
/// by asking CoreDevice every second — and at once when something says the
/// device just folded. Reports a state only when it differs from the last.
final class DisplayStateMonitor: @unchecked Sendable {
    typealias Read = @Sendable (_ deviceUDID: String, _ layout: SimulatorDisplayLayout) async throws -> SimulatorDisplayState

    private let deviceUDID: String
    private let layout: SimulatorDisplayLayout
    private let read: Read
    private let interval: Duration
    private let onChange: @Sendable (SimulatorDisplayState) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var last: SimulatorDisplayState?
    private var reportedFailure = false

    init(
        deviceUDID: String,
        layout: SimulatorDisplayLayout,
        interval: Duration = .seconds(1),
        read: @escaping Read = { try await SimulatorDisplayState.read(deviceUDID: $0, layout: $1) },
        onChange: @escaping @Sendable (SimulatorDisplayState) -> Void
    ) {
        self.deviceUDID = deviceUDID
        self.layout = layout
        self.interval = interval
        self.read = read
        self.onChange = onChange
    }

    func start() {
        let interval = interval
        lock.withLock {
            task?.cancel()
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }

    /// Reads the state now. A failed read keeps the last state: devicectl
    /// that hiccups once must not flip the stream to another screen.
    func refresh() async {
        do {
            let state = try await read(deviceUDID, layout)
            let changed = lock.withLock {
                reportedFailure = false
                guard last != state else { return false }
                last = state
                return true
            }
            if changed { onChange(state) }
        } catch {
            let first = lock.withLock {
                defer { reportedFailure = true }
                return !reportedFailure
            }
            if first { DebugLog.write("displays", "cannot read the lit screen of \(deviceUDID): \(error.localizedDescription)") }
        }
    }
}
