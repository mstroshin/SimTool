import Foundation

/// Server-side buffer of ingested state events. Bounded two ways: a per-model ring
/// (oldest snapshots of a chatty model drop first) and a model cap (the least recently
/// updated model is evicted wholesale). Cursor semantics mirror the log capture buffer:
/// clients pass back `nextCursor` as `since` to read incrementally without gaps.
public final class StateLoggerEventStore: @unchecked Sendable {
    public let perModelCapacity: Int
    public let maxModels: Int

    private let lock = NSLock()
    private var eventsByModel: [String: [StateLoggerEvent]] = [:]
    /// Least recently updated first.
    private var modelRecency: [String] = []
    private var nextCursor = 0

    public init(perModelCapacity: Int = 200, maxModels: Int = 50) {
        self.perModelCapacity = max(1, perModelCapacity)
        self.maxModels = max(1, maxModels)
    }

    @discardableResult
    public func ingest(_ events: [StateLoggerEvent]) -> StateLoggerIngestionResponse {
        lock.lock()
        defer { lock.unlock() }
        for var event in events {
            event.cursor = nextCursor
            nextCursor += 1
            eventsByModel[event.modelId, default: []].append(event)
            if eventsByModel[event.modelId]!.count > perModelCapacity {
                eventsByModel[event.modelId]!.removeFirst()
            }
            modelRecency.removeAll { $0 == event.modelId }
            modelRecency.append(event.modelId)
            if eventsByModel.count > maxModels, let evicted = modelRecency.first {
                eventsByModel.removeValue(forKey: evicted)
                modelRecency.removeFirst()
            }
        }
        return StateLoggerIngestionResponse(acceptedCount: events.count)
    }

    public func query(since: Int? = nil, limit: Int = 500) -> StateLoggerEventsPayload {
        lock.lock()
        defer { lock.unlock() }
        var all = eventsByModel.values.flatMap { $0 }
        if let since {
            all.removeAll { ($0.cursor ?? -1) <= since }
        }
        all.sort { ($0.cursor ?? -1) < ($1.cursor ?? -1) }
        if all.count > limit {
            all.removeLast(all.count - limit)
        }
        return StateLoggerEventsPayload(
            events: all,
            nextCursor: all.last?.cursor ?? since ?? -1
        )
    }
}
