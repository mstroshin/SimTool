import Foundation
import SimToolCore

/// The served device's screens and, on a foldable, which one is lit — what the
/// stream, screenshots, recordings, touches and `/config` all follow. Filled
/// once the device type is read, updated as the device folds.
final class DeviceDisplays: @unchecked Sendable {
    private let lock = NSLock()
    private var layout: SimulatorDisplayLayout?
    private var state: SimulatorDisplayState?
    private var foldState: SimulatorFoldState?

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

    /// The fold, its panel the one CoreDevice says is lit: SpringBoard names
    /// its primary panel only when that changes.
    var fold: SimulatorFoldState? {
        lock.withLock {
            guard var fold = foldState else { return nil }
            if let active = state?.active, let role = layout?.display(named: active)?.role { fold.panel = role }
            return fold
        }
    }

    /// Whether the fold changed.
    @discardableResult
    func set(fold: SimulatorFoldState) -> Bool {
        lock.withLock {
            guard foldState != fold else { return false }
            foldState = fold
            return true
        }
    }

    /// The lit screen of a foldable: simctl names it to screenshot or record
    /// one, and refuses to pick between two. Nil on a one-screen device.
    var activeDisplay: SimulatorDisplay? {
        let (layout, state) = current
        guard let layout, layout.isFoldable else { return nil }
        return state.flatMap { layout.display(named: $0.active) } ?? layout.displays.first
    }

    /// The screen a screenshot or a recording shows: the lit one of a
    /// foldable, the only one of a phone. Nil until the device type is read.
    var shownDisplay: SimulatorDisplay? {
        activeDisplay ?? current.layout?.displays.first
    }

    var payloads: [ServerDisplayPayload] {
        let (layout, state) = current
        return layout.map { ServerDisplayPayload.all(layout: $0, state: state) } ?? []
    }

    var topic: DeviceTopicPayload {
        DeviceTopicPayload(displays: payloads, activeDisplay: activeDisplay?.id, fold: fold)
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

/// Follows an iPhone Duo's fold as SpringBoard logs it — the hinge as it
/// moves, the posture, the panel it makes primary — seeded from the last half
/// hour of its log, then from a `log stream` kept running (restarted if it
/// ends).
final class FoldMonitor: @unchecked Sendable {
    private let deviceUDID: String
    private let onChange: @Sendable (_ fold: SimulatorFoldState, _ panelSwitched: Bool) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var state: SimulatorFoldState?
    private var pending = Data()
    private var stopped = false

    init(deviceUDID: String, onChange: @escaping @Sendable (_ fold: SimulatorFoldState, _ panelSwitched: Bool) -> Void) {
        self.deviceUDID = deviceUDID
        self.onChange = onChange
    }

    func start() {
        Task {
            if let seed = await SimulatorFoldState.read(deviceUDID: deviceUDID) {
                let fresh = lock.withLock {
                    guard state == nil else { return false }
                    state = seed
                    return true
                }
                if fresh { onChange(seed, true) }
            }
        }
        stream()
    }

    func stop() {
        let running = lock.withLock {
            stopped = true
            defer { process = nil }
            return process
        }
        running?.terminate()
    }

    private func stream() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", deviceUDID, "log", "stream", "--level", "info", "--style", "compact", "--predicate", SimulatorFoldState.logPredicate]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.receive(data)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.stream() }
        }
        lock.withLock { self.process = process }
        do { try process.run() } catch { DebugLog.write("fold", "cannot stream SpringBoard's log: \(error.localizedDescription)") }
    }

    private func receive(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 10) {
                lines.append(String(decoding: pending[..<newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
            return lines
        }
        for line in lines {
            let change: (SimulatorFoldState, Bool)? = lock.withLock {
                guard let next = (state ?? SimulatorFoldState()).reading(line), next != state else { return nil }
                defer { state = next }
                return (next, next.panel != state?.panel || line.contains("COMPLETED:"))
            }
            if let (fold, switched) = change { onChange(fold, switched) }
        }
    }
}

/// Hears a phone turn: CoreSimulatorBridge logs every orientation update
/// FrontBoard gives it, whoever turned the device. Each one asks for the
/// picture's rotation again — as the turn starts and once it has settled — from
/// a `log stream` kept running (restarted if it ends), which costs nothing
/// while the device sits still.
final class OrientationMonitor: @unchecked Sendable {
    static let logPredicate = #"process == "CoreSimulatorBridge" AND eventMessage CONTAINS "Received orientation update""#

    private let deviceUDID: String
    private let onTurn: @Sendable () async -> Void
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    init(deviceUDID: String, onTurn: @escaping @Sendable () async -> Void) {
        self.deviceUDID = deviceUDID
        self.onTurn = onTurn
    }

    func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", deviceUDID, "log", "stream", "--style", "compact", "--predicate", Self.logPredicate]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            // The stream's first line quotes the predicate; one read too many costs nothing.
            guard let self, String(decoding: data, as: UTF8.self).contains("Received orientation update") else { return }
            let onTurn = self.onTurn
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                await onTurn()
                try? await Task.sleep(for: .milliseconds(800))
                await onTurn()
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
        }
        lock.withLock { self.process = process }
        do { try process.run() } catch { DebugLog.write("displays", "cannot stream the guest's orientation updates: \(error.localizedDescription)") }
    }

    func stop() {
        let running = lock.withLock {
            stopped = true
            defer { process = nil }
            return process
        }
        running?.terminate()
    }
}
