import Foundation
@testable import SimToolServer
import XCTest

final class InspectorEventHubTests: XCTestCase {
    private struct Count: Codable, Equatable {
        var count: Int
    }

    func testAFreshStreamStartsWithASnapshotAndThenGetsEachChange() throws {
        let hub = InspectorEventHub(instanceId: "A")
        hub.publish(.network, Count(count: 1))
        hub.publish(.logs, Count(count: 2))

        let subscription = hub.subscribe(lastEventID: nil) { Count(count: 2) }
        XCTAssertEqual(try events(subscription.next(timeout: 1)), [Event(id: "A:2", name: "snapshot", data: #"{"count":2}"#)])

        hub.publish(.state, Count(count: 3))
        XCTAssertEqual(try events(subscription.next(timeout: 1)), [Event(id: "A:3", name: "state", data: #"{"count":3}"#)])
        XCTAssertEqual(hub.lastEventID, "A:3")
    }

    func testAReconnectReplaysOnlyWhatItMissed() throws {
        let hub = InspectorEventHub(instanceId: "A")
        for count in 1...3 { hub.publish(.network, Count(count: count)) }

        let subscription = hub.subscribe(lastEventID: "A:1") { Count(count: -1) }
        XCTAssertEqual(try events(subscription.next(timeout: 1)).map(\.id), ["A:2", "A:3"], "no snapshot, nothing twice")
    }

    func testAnUpToDateReconnectWaitsForTheNextChange() throws {
        let hub = InspectorEventHub(instanceId: "A")
        hub.publish(.network, Count(count: 1))

        let subscription = hub.subscribe(lastEventID: "A:1") { Count(count: -1) }
        XCTAssertEqual(subscription.next(timeout: 0.05), Data(), "nothing yet: time for a keep-alive")
        hub.publish(.network, Count(count: 2))
        XCTAssertEqual(try events(subscription.next(timeout: 1)).map(\.id), ["A:2"])
    }

    // A restarted server numbers from zero again: an id of the old run means nothing here.
    func testAnIdFromAnotherServerRunStartsOverFromASnapshot() throws {
        let hub = InspectorEventHub(instanceId: "B")
        hub.publish(.network, Count(count: 1))

        for stale in ["A:1", "A:0", "B:7", "B", "garbage", ""] {
            let subscription = hub.subscribe(lastEventID: stale) { Count(count: 1) }
            XCTAssertEqual(try events(subscription.next(timeout: 1)).map(\.name), ["snapshot"], stale)
        }
    }

    func testAGapTheBacklogNoLongerCoversStartsOverFromASnapshot() throws {
        let hub = InspectorEventHub(instanceId: "A", backlogLimit: 4)
        for count in 1...10 { hub.publish(.logs, Count(count: count)) }

        let behind = hub.subscribe(lastEventID: "A:2") { Count(count: 10) }
        XCTAssertEqual(try events(behind.next(timeout: 1)), [Event(id: "A:10", name: "snapshot", data: #"{"count":10}"#)])

        let recent = hub.subscribe(lastEventID: "A:9") { Count(count: 10) }
        XCTAssertEqual(try events(recent.next(timeout: 1)).map(\.id), ["A:10"])
    }

    // What a snapshot holds and what follows it never overlap and never leave a hole.
    func testEveryChangeIsInTheSnapshotOrAfterItExactlyOnce() throws {
        let hub = InspectorEventHub(instanceId: "A")
        let store = Counter()
        let writer = Thread {
            for _ in 0..<2_000 {
                hub.publish { changes in
                    changes.emit(.network, Count(count: store.increment()))
                }
            }
        }
        writer.start()
        var checked = 0
        repeat {
            let subscription = hub.subscribe(lastEventID: nil) { Count(count: store.value) }
            var received = try events(subscription.next(timeout: 1))
            let snapshot = received.removeFirst()
            let base = try JSONDecoder().decode(Count.self, from: Data(snapshot.data.utf8)).count
            XCTAssertEqual(snapshot.id, "A:\(base)", "the snapshot is as of its own id")
            while let more = subscription.next(timeout: 0.01), !more.isEmpty { received += try events(more) }
            let counts = try received.map { try JSONDecoder().decode(Count.self, from: Data($0.data.utf8)).count }
            XCTAssertEqual(counts, (0..<counts.count).map { base + 1 + $0 })
            hub.unsubscribe(subscription)
            checked += 1
        } while store.value < 2_000
        XCTAssertGreaterThan(checked, 0)
    }

    func testAReaderTooFarBehindIsCutOffToReconnect() throws {
        let hub = InspectorEventHub(instanceId: "A", subscriberByteLimit: 256)
        let subscription = hub.subscribe(lastEventID: nil) { Count(count: 0) }
        for count in 1...20 { hub.publish(.logs, Count(count: count)) }

        XCTAssertNil(subscription.next(timeout: 0.05))
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testStoppingTheServerEndsEveryStream() {
        let hub = InspectorEventHub(instanceId: "A")
        let first = hub.subscribe(lastEventID: nil) { Count(count: 0) }
        let second = hub.subscribe(lastEventID: nil) { Count(count: 0) }
        XCTAssertEqual(hub.subscriberCount, 2)

        hub.closeAll()
        XCTAssertEqual(hub.subscriberCount, 0)
        XCTAssertNil(first.next(timeout: 1))
        XCTAssertNil(second.next(timeout: 1))
    }

    // MARK: - Helpers

    struct Event: Equatable {
        var id: String?
        var name: String
        var data: String
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() -> Int { lock.withLock { count += 1; return count } }
    }

    private func events(_ chunk: Data?) throws -> [Event] {
        let text = String(decoding: try XCTUnwrap(chunk, "the stream closed"), as: UTF8.self)
        return ServerSentEvents.parse(text)
    }
}

/// Splits Server-Sent Events text into its events, as a browser would.
enum ServerSentEvents {
    static func parse(_ text: String) -> [InspectorEventHubTests.Event] {
        text.components(separatedBy: "\n\n").compactMap { block in
            var id: String?
            var name = "message"
            var data: [String] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix(":") {
                let field = line.prefix { $0 != ":" }
                var value = line.dropFirst(field.count + 1)
                if value.hasPrefix(" ") { value = value.dropFirst() }
                switch field {
                case "id": id = String(value)
                case "event": name = String(value)
                case "data": data.append(String(value))
                default: break
                }
            }
            return data.isEmpty ? nil : InspectorEventHubTests.Event(id: id, name: name, data: data.joined(separator: "\n"))
        }
    }
}
