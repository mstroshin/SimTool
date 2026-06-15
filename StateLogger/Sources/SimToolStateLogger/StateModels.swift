import Foundation

/// One state snapshot of one tracked model instance.
public struct StateLoggerEvent: Codable, Equatable, Sendable {
    /// Stable per-instance id: "<name>#<instance counter>".
    public var modelId: String
    public var name: String
    /// Per-instance monotonic sequence number.
    public var seq: Int
    /// Epoch seconds.
    public var timestamp: Double
    public var snapshot: SimToolStateValue
    /// Set on the final event when the tracked model deallocates.
    public var deallocated: Bool?
    public var pid: Int?
    /// Stamped by the server from the batch pid (see AppLaunchRegistry).
    public var launchId: Int?
    /// Server-assigned global ordering cursor; nil until ingested.
    public var cursor: Int?

    public init(
        modelId: String,
        name: String,
        seq: Int,
        timestamp: Double,
        snapshot: SimToolStateValue,
        deallocated: Bool? = nil,
        pid: Int? = nil,
        launchId: Int? = nil,
        cursor: Int? = nil
    ) {
        self.modelId = modelId
        self.name = name
        self.seq = seq
        self.timestamp = timestamp
        self.snapshot = snapshot
        self.deallocated = deallocated
        self.pid = pid
        self.launchId = launchId
        self.cursor = cursor
    }
}

public struct StateLoggerBatchPayload: Codable, Equatable, Sendable {
    public var events: [StateLoggerEvent]
    public var pid: Int?

    public init(events: [StateLoggerEvent], pid: Int? = nil) {
        self.events = events
        self.pid = pid
    }
}

public struct StateLoggerEventsPayload: Codable, Equatable, Sendable {
    public var events: [StateLoggerEvent]
    /// Cursor of the last returned event; pass back as `since` to poll incrementally.
    public var nextCursor: Int

    public init(events: [StateLoggerEvent], nextCursor: Int) {
        self.events = events
        self.nextCursor = nextCursor
    }
}

public struct StateLoggerIngestionResponse: Codable, Equatable, Sendable {
    public var acceptedCount: Int

    public init(acceptedCount: Int) {
        self.acceptedCount = acceptedCount
    }
}
