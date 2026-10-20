import Foundation
import SimToolCore

/// The inspector's data pushed to viewers over one Server-Sent Events stream per
/// page (`GET /api/v1/events`) instead of every tab polling its own route.
///
/// Every change to inspector data goes through `publish`, which applies the
/// change and stamps what it emits with the next sequence number as one step,
/// while `subscribe` takes its snapshot under the same lock. A stream therefore
/// never sees a change twice or misses one: on reconnect it resumes after its
/// `Last-Event-ID` from the events kept here, or — after a gap they no longer
/// cover, or from another server instance — starts over from a snapshot.
public final class InspectorEventHub: @unchecked Sendable {
    public enum Topic: String, CaseIterable, Sendable {
        case network, logs, state, tests, launches
    }

    /// What one `publish` sends: the topics it changed and what changed in each.
    public struct Changes {
        fileprivate var events: [(topic: Topic, data: Data)] = []

        public mutating func emit<Payload: Encodable>(_ topic: Topic, _ payload: Payload) {
            guard let data = try? JSON.data(payload, pretty: false) else { return }
            events.append((topic, data))
        }
    }

    /// Ids read `<instance>:<sequence>`, so an id from a previous server run is
    /// recognisably not this one's.
    public let instanceId: String
    private let backlogLimit: Int
    private let backlogByteLimit: Int
    private let subscriberByteLimit: Int
    private let lock = NSLock()
    private var sequence = 0
    /// The newest events, oldest first, kept to replay to a stream that reconnects.
    private var backlog: [(sequence: Int, message: Data)] = []
    private var backlogBytes = 0
    private var subscribers: [ObjectIdentifier: InspectorEventSubscription] = [:]

    public init(
        instanceId: String = UUID().uuidString,
        backlogLimit: Int = 4_096,
        backlogByteLimit: Int = 16 << 20,
        subscriberByteLimit: Int = 64 << 20
    ) {
        self.instanceId = instanceId
        self.backlogLimit = max(1, backlogLimit)
        self.backlogByteLimit = max(1, backlogByteLimit)
        self.subscriberByteLimit = max(1, subscriberByteLimit)
    }

    public var subscriberCount: Int {
        lock.withLock { subscribers.count }
    }

    /// The id of the newest event, or of the empty start when nothing happened yet.
    public var lastEventID: String {
        lock.withLock { eventID(sequence) }
    }

    /// Applies `change` and sends what it emits, as one step against every
    /// stream and snapshot. `change` runs under the hub's lock: it mutates the
    /// stores, and must not publish or subscribe itself.
    @discardableResult
    public func publish<Result>(_ change: (inout Changes) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        var changes = Changes()
        let result = try change(&changes)
        for event in changes.events {
            send(event.topic, event.data)
        }
        return result
    }

    public func publish<Payload: Encodable>(_ topic: Topic, _ payload: Payload) {
        publish { $0.emit(topic, payload) }
    }

    /// Opens a stream. `lastEventID` is the id a browser sends back when it
    /// reconnects: when it names this instance and every event after it is still
    /// kept, those events are replayed. Otherwise the stream starts with one
    /// `snapshot` event — `snapshot()`, the whole inspector state as of the id
    /// it carries — which the viewer takes in place of everything it holds.
    public func subscribe<Snapshot: Encodable>(lastEventID: String?, snapshot: () -> Snapshot) -> InspectorEventSubscription {
        lock.lock()
        defer { lock.unlock() }
        let subscription = InspectorEventSubscription(byteLimit: subscriberByteLimit)
        if let position = resumablePosition(lastEventID) {
            for event in backlog where event.sequence > position {
                subscription.enqueue(event.message)
            }
        } else if let data = try? JSON.data(snapshot(), pretty: false) {
            subscription.enqueue(Self.message(id: eventID(sequence), event: "snapshot", data: data))
        } else {
            // A stream without its starting point would show a partial picture.
            subscription.close()
            return subscription
        }
        subscribers[ObjectIdentifier(subscription)] = subscription
        return subscription
    }

    public func unsubscribe(_ subscription: InspectorEventSubscription) {
        lock.withLock { _ = subscribers.removeValue(forKey: ObjectIdentifier(subscription)) }
        subscription.close()
    }

    /// Ends every open stream, as the server stops.
    public func closeAll() {
        let open = lock.withLock {
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for subscription in open {
            subscription.close()
        }
    }

    /// One event as it goes on the wire. Compact JSON never holds a raw line
    /// break, so the payload always fits one `data:` line.
    static func message(id: String, event: String, data: Data) -> Data {
        var message = Data("id: \(id)\nevent: \(event)\ndata: ".utf8)
        message.append(data)
        message.append(contentsOf: [0x0A, 0x0A])
        return message
    }

    private func eventID(_ sequence: Int) -> String {
        "\(instanceId):\(sequence)"
    }

    /// The sequence number to replay after, when `lastEventID` is this
    /// instance's and nothing after it has been dropped from the backlog.
    private func resumablePosition(_ lastEventID: String?) -> Int? {
        guard let lastEventID, let colon = lastEventID.lastIndex(of: ":"),
              lastEventID[..<colon] == instanceId,
              let position = Int(lastEventID[lastEventID.index(after: colon)...]),
              position <= sequence else { return nil }
        let oldestKept = backlog.first?.sequence ?? sequence + 1
        return position + 1 >= oldestKept ? position : nil
    }

    /// Caller holds `lock`.
    private func send(_ topic: Topic, _ data: Data) {
        sequence += 1
        let message = Self.message(id: eventID(sequence), event: topic.rawValue, data: data)
        backlog.append((sequence, message))
        backlogBytes += message.count
        trimBacklog()
        for (key, subscriber) in subscribers where !subscriber.enqueue(message) {
            subscribers.removeValue(forKey: key)
        }
    }

    /// Drops the oldest events down to three quarters of the limits at once, so
    /// a full backlog is not shifted on every event. Caller holds `lock`.
    private func trimBacklog() {
        guard backlog.count > backlogLimit || backlogBytes > backlogByteLimit else { return }
        var count = backlog.count
        var bytes = backlogBytes
        var dropped = 0
        while dropped < backlog.count - 1, count > backlogLimit * 3 / 4 || bytes > backlogByteLimit * 3 / 4 {
            bytes -= backlog[dropped].message.count
            count -= 1
            dropped += 1
        }
        backlog.removeFirst(dropped)
        backlogBytes = bytes
    }
}

/// One open event stream: the events the hub sent it that it has not written yet.
public final class InspectorEventSubscription: @unchecked Sendable {
    private let condition = NSCondition()
    private let byteLimit: Int
    private var pending = Data()
    private var closed = false

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    /// False once the stream is closed. A reader that falls this far behind is
    /// cut off rather than buffered without end: its browser reconnects and
    /// resumes, or starts over from a snapshot.
    @discardableResult
    func enqueue(_ message: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return false }
        if !pending.isEmpty, pending.count + message.count > byteLimit {
            closed = true
            pending = Data()
            condition.broadcast()
            return false
        }
        pending.append(message)
        condition.signal()
        return true
    }

    func close() {
        condition.lock()
        closed = true
        pending = Data()
        condition.broadcast()
        condition.unlock()
    }

    /// Waits up to `timeout` for what to write next: every pending event at
    /// once, empty data when nothing came (time for a keep-alive), or nil once
    /// the stream is closed.
    public func next(timeout: TimeInterval) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while pending.isEmpty, !closed, condition.wait(until: deadline) {}
        if closed { return nil }
        defer { pending = Data() }
        return pending
    }
}
