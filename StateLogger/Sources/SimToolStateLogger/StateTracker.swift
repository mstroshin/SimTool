// StateLogger/Sources/SimToolStateLogger/StateTracker.swift
import Foundation
import Observation
import OSLog

/// Entry point apps call to stream a model's state to SimTool.
///
/// Mode selection: an explicit `poll:` interval always polls; otherwise
/// `@Observable` models use observation tracking (per-transition diffs, zero
/// idle cost) and plain classes auto-fall back to polling at
/// `autoPollInterval` (default 1 s). All tracking runs on the main actor.
/// Inert unless a sink is armed (SIMTOOL_STATE_LOGGER=1 + SIMTOOL_SERVER_URL,
/// or `configure` in tests).
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
public enum SimToolState {
    private static var sink: StateLoggerSink?
    private static var sinkResolved = false
    private static var debounce: Duration = .milliseconds(100)
    private static var autoPollInterval: Duration = .seconds(1)
    /// Keyed by the tracked instance's ObjectIdentifier for idempotence.
    /// Entries are pruned when an observer stops (deallocation detected).
    /// An identifier can be reused by a new allocation before pruning, so the
    /// guard in `track` also checks the existing observer still holds a live
    /// model before skipping.
    private static var observers: [ObjectIdentifier: any StateObserving] = [:]
    private static var instanceCounters: [String: Int] = [:]
    private static var warnedAutoPoll = false

    public static func track(
        _ model: some SimToolStateReportable,
        name: String? = nil,
        poll: Duration? = nil
    ) {
        #if DEBUG
        if !sinkResolved {
            sink = StateLoggerEnvironment.resolveSink()
            sinkResolved = true
        }
        guard let sink else { return }
        let identifier = ObjectIdentifier(model)
        if let existing = observers[identifier] {
            if existing.isModelAlive { return }
            // Stale entry: the previous model deallocated and a new allocation
            // reused its address. Emit the final deallocated event for the old
            // model before replacing the observer.  finishDeallocated calls
            // onStop (→ observers.removeValue), so we skip the explicit remove;
            // the insert below then adds the new entry safely.
            existing.finishDeallocated()
        }

        let resolvedName = name ?? String(describing: type(of: model))
        let instance = instanceCounters[resolvedName, default: 0]
        instanceCounters[resolvedName] = instance + 1
        let channel = StateEventChannel(
            modelId: "\(resolvedName)#\(instance)",
            name: resolvedName,
            sink: sink
        )

        let interval: Duration?
        if let poll {
            interval = poll
        } else if model is any Observable {
            interval = nil
        } else {
            interval = autoPollInterval
            if !warnedAutoPoll {
                warnedAutoPoll = true
                Logger(subsystem: "SimToolStateLogger", category: "Tracker")
                    .info("\(resolvedName, privacy: .public) is not Observable — polling; pass poll: to tune the interval")
            }
        }

        SimToolStateTrackedRegistry.modelIds[identifier] = channel.modelId
        let onStop: @MainActor () -> Void = {
            observers.removeValue(forKey: identifier)
            SimToolStateTrackedRegistry.modelIds.removeValue(forKey: identifier)
        }
        let observer: any StateObserving
        if let interval {
            observer = PollingStateObserver(model: model, interval: interval, channel: channel, onStop: onStop)
        } else {
            observer = StateModelObserver(model: model, debounce: debounce, channel: channel, onStop: onStop)
        }
        observers[identifier] = observer
        observer.start()
        #endif
    }

    /// Test hook: overrides the environment-resolved sink and intervals.
    public static func configure(
        sink: StateLoggerSink?,
        debounce: Duration = .milliseconds(100),
        autoPollInterval: Duration = .seconds(1)
    ) {
        self.sink = sink
        self.sinkResolved = true
        self.debounce = debounce
        self.autoPollInterval = autoPollInterval
    }

    /// Test hook: stops all observers and clears configuration.
    public static func reset() {
        observers.values.forEach { $0.stop() }
        observers = [:]
        instanceCounters = [:]
        SimToolStateTrackedRegistry.modelIds = [:]
        sink = nil
        sinkResolved = false
        debounce = .milliseconds(100)
        autoPollInterval = .seconds(1)
        warnedAutoPoll = false
    }
}

extension SimToolStateReportable {
    /// Chainable registration: `CounterModel(codeLength: 6).simToolTracked()`.
    /// Nonisolated so it can be called from any context (e.g. Factory DI
    /// closures); hops to the main actor internally. Registration is
    /// idempotent per instance.
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
    @discardableResult
    public func simToolTracked(_ name: String? = nil, poll: Duration? = nil) -> Self {
        #if DEBUG
        // Models are not Sendable; region analysis rejects capturing `self`
        // in the @MainActor task while also returning it. The escape hatch is
        // sound here: track() only stores a weak reference and reads the
        // model on the main actor.
        nonisolated(unsafe) let model = self
        Task { @MainActor in SimToolState.track(model, name: name, poll: poll) }
        #endif
        return self
    }
}

/// Shared per-instance emit plumbing: stable modelId, monotonic seq, pid
/// stamping, last-snapshot memory (used by polling for change detection).
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class StateEventChannel {
    let modelId: String
    let name: String
    private let sink: StateLoggerSink
    private var seq = 0
    private(set) var lastSnapshot: SimToolStateValue?

    init(modelId: String, name: String, sink: StateLoggerSink) {
        self.modelId = modelId
        self.name = name
        self.sink = sink
    }

    func emit(snapshot: SimToolStateValue, deallocated: Bool = false) {
        let event = StateLoggerEvent(
            modelId: modelId,
            name: name,
            seq: seq,
            timestamp: Date().timeIntervalSince1970,
            snapshot: snapshot,
            deallocated: deallocated ? true : nil,
            pid: Int(ProcessInfo.processInfo.processIdentifier)
        )
        seq += 1
        lastSnapshot = snapshot
        let sink = self.sink
        Task { await sink.record([event]) }
    }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
protocol StateObserving: AnyObject {
    /// False once the weakly-held model has deallocated; lets `track` detect
    /// ObjectIdentifier reuse by a new allocation at the same address.
    var isModelAlive: Bool { get }
    func start()
    func stop()
    /// Called when a stale entry is replaced in `track`: the previous model is
    /// provably deallocated, so emit its final `deallocated` event before the
    /// new observer takes the slot.  Must not trigger re-entrant mutation of
    /// `observers` via `onStop` while the caller has not yet inserted the new
    /// entry — the implementation must call `onStop` as part of normal
    /// bookkeeping, but `track` removes the old entry before inserting the new
    /// one so the order is safe.
    func finishDeallocated()
}

/// Observation mode: one re-arming `withObservationTracking` loop per tracked
/// instance. Holds the model weakly; when the model deallocates, the next
/// armed refresh emits a final `deallocated` event and stops.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class StateModelObserver: StateObserving {
    private weak var model: (any SimToolStateReportable)?
    private let debounce: Duration
    private let channel: StateEventChannel
    private let onStop: @MainActor () -> Void
    private var refreshTask: Task<Void, Never>?
    private var stopped = false

    var isModelAlive: Bool { model != nil }

    init(
        model: any SimToolStateReportable,
        debounce: Duration,
        channel: StateEventChannel,
        onStop: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.debounce = debounce
        self.channel = channel
        self.onStop = onStop
    }

    func start() {
        observe()
    }

    func stop() {
        stopped = true
        refreshTask?.cancel()
    }

    func finishDeallocated() {
        guard !stopped else { return }
        stopped = true
        refreshTask?.cancel()
        channel.emit(snapshot: .null, deallocated: true)
        onStop()
    }

    private func observe() {
        guard !stopped else { return }
        guard let model else {
            finishDeallocated()
            return
        }
        let snapshot = withObservationTracking {
            model._simToolSnapshot()
        } onChange: { [weak self] in
            // onChange is willSet and may fire off-main; hop to the main actor
            // and debounce, then re-read so the event carries the *new* values.
            Task { @MainActor in self?.scheduleRefresh() }
        }
        channel.emit(snapshot: snapshot)
    }

    private func scheduleRefresh() {
        guard !stopped else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            self.observe()
        }
    }
}

/// Polling mode: re-snapshot every `interval` and emit only when the snapshot
/// changed. The tick is the coalescing — no debounce. Used for plain (non
/// `@Observable`) classes, or explicitly via `poll:`.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
final class PollingStateObserver: StateObserving {
    private weak var model: (any SimToolStateReportable)?
    private let interval: Duration
    private let channel: StateEventChannel
    private let onStop: @MainActor () -> Void
    private var loop: Task<Void, Never>?
    private var stopped = false

    var isModelAlive: Bool { model != nil }

    init(
        model: any SimToolStateReportable,
        interval: Duration,
        channel: StateEventChannel,
        onStop: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.interval = interval
        self.channel = channel
        self.onStop = onStop
    }

    func start() {
        guard let model else {
            finish(deallocated: true)
            return
        }
        channel.emit(snapshot: model._simToolSnapshot())
        loop = Task { @MainActor [weak self] in
            while true {
                guard let self, !self.stopped else { return }
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled, !self.stopped else { return }
                guard let model = self.model else {
                    self.finish(deallocated: true)
                    return
                }
                let snapshot = model._simToolSnapshot()
                if snapshot != self.channel.lastSnapshot {
                    self.channel.emit(snapshot: snapshot)
                }
            }
        }
    }

    func stop() {
        stopped = true
        loop?.cancel()
    }

    func finishDeallocated() {
        finish(deallocated: true)
    }

    private func finish(deallocated: Bool) {
        guard !stopped else { return }
        stopped = true
        if deallocated {
            channel.emit(snapshot: .null, deallocated: true)
        }
        onStop()
    }
}
