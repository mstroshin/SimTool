import XCTest
@testable import SimToolStateLogger

final class StateEventStoreTests: XCTestCase {
    private func makeEvent(modelId: String = "AppModel#0", seq: Int) -> StateLoggerEvent {
        StateLoggerEvent(
            modelId: modelId,
            name: "AppModel",
            seq: seq,
            timestamp: 1_700_000_000 + Double(seq),
            snapshot: .object(["count": .number(Double(seq))])
        )
    }

    func testAssignsCursorsAndQueriesIncrementally() {
        let store = StateLoggerEventStore()
        XCTAssertEqual(store.ingest([makeEvent(seq: 0), makeEvent(seq: 1)]).acceptedCount, 2)

        let all = store.query()
        XCTAssertEqual(all.events.map(\.cursor), [0, 1])
        XCTAssertEqual(all.nextCursor, 1)

        store.ingest([makeEvent(seq: 2)])
        let incremental = store.query(since: all.nextCursor)
        XCTAssertEqual(incremental.events.map(\.seq), [2])
        XCTAssertEqual(incremental.nextCursor, 2)

        // Nothing new: nextCursor must echo `since` so the client cursor doesn't reset.
        let empty = store.query(since: incremental.nextCursor)
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertEqual(empty.nextCursor, 2)
    }

    func testPerModelCapacityEvictsOldestOfThatModel() {
        let store = StateLoggerEventStore(perModelCapacity: 2, maxModels: 50)
        store.ingest([makeEvent(seq: 0), makeEvent(seq: 1), makeEvent(seq: 2)])
        XCTAssertEqual(store.query().events.map(\.seq), [1, 2])
    }

    func testModelCapEvictsLeastRecentlyUpdatedModel() {
        let store = StateLoggerEventStore(perModelCapacity: 10, maxModels: 2)
        store.ingest([makeEvent(modelId: "A#0", seq: 0)])
        store.ingest([makeEvent(modelId: "B#0", seq: 0)])
        store.ingest([makeEvent(modelId: "C#0", seq: 0)])
        let ids = Set(store.query().events.map(\.modelId))
        XCTAssertEqual(ids, ["B#0", "C#0"])
    }

    func testLimitKeepsOldestSoClientsPageForwardWithoutGaps() {
        let store = StateLoggerEventStore()
        store.ingest((0..<5).map { makeEvent(seq: $0) })
        let page = store.query(limit: 2)
        XCTAssertEqual(page.events.map(\.cursor), [0, 1])
        XCTAssertEqual(page.nextCursor, 1)
        let next = store.query(since: page.nextCursor, limit: 2)
        XCTAssertEqual(next.events.map(\.cursor), [2, 3])
    }
}
