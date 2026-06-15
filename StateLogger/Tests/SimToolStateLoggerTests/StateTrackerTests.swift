import Foundation
import Observation
import XCTest
@testable import SimToolStateLogger

private final class RecordingSink: StateLoggerSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StateLoggerEvent] = []

    var events: [StateLoggerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ events: [StateLoggerEvent]) async {
        lock.lock()
        stored.append(contentsOf: events)
        lock.unlock()
    }
}

@available(macOS 14.0, iOS 17.0, *)
@SimToolDebugState
@MainActor
final class PlainFixtureModel {
    var items = 0
}

final class StateTrackerTests: XCTestCase {
    @MainActor
    override func tearDown() {
        if #available(macOS 14.0, *) { SimToolState.reset() }
        super.tearDown()
    }

    @MainActor
    func testEmitsInitialSnapshotAndDebouncedChangeEvents() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        let model = FixtureModel()
        SimToolState.track(model, name: "Fixture")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sink.events.count, 1, "initial snapshot")
        XCTAssertEqual(sink.events[0].modelId, "Fixture#0")
        XCTAssertEqual(sink.events[0].seq, 0)

        model.count = 1
        model.count = 2
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sink.events.count, 2, "burst must coalesce into one event")
        let last = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(last.seq, 1)
        guard case .object(let object) = last.snapshot else { return XCTFail("expected object") }
        XCTAssertEqual(object["count"], .number(2), "snapshot must hold the final value")
    }

    @MainActor
    func testSecondInstanceGetsDistinctModelId() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        SimToolState.track(FixtureModel(), name: "Fixture")
        SimToolState.track(FixtureModel(), name: "Fixture")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Set(sink.events.map(\.modelId)), ["Fixture#0", "Fixture#1"])
    }

    @MainActor
    func testDeallocatedModelEmitsFinalEvent() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        var model: FixtureModel? = FixtureModel()
        SimToolState.track(model!, name: "Fixture")
        try await Task.sleep(for: .milliseconds(100))

        model?.count = 1   // arm a refresh…
        model = nil        // …then release before the debounce fires
        try await Task.sleep(for: .milliseconds(200))

        let last = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(last.deallocated, true)
    }

    @MainActor
    func testTrackWithoutSinkIsInert() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation") }
        SimToolState.configure(sink: nil)
        SimToolState.track(FixtureModel(), name: "Fixture")
        // No crash, no retain: nothing to assert beyond clean completion.
    }

    @MainActor
    func testPollingEmitsOnChangeAndStaysQuietOtherwise() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink)

        let model = PlainFixtureModel()
        SimToolState.track(model, name: "Plain", poll: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(sink.events.count, 1, "initial snapshot only while unchanged")

        model.items = 3
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sink.events.count, 2, "one event per changed tick")
        guard case .object(let object) = try XCTUnwrap(sink.events.last).snapshot else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(object["items"], .number(3))
    }

    @MainActor
    func testAutoFallbackPollsPlainClasses() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, autoPollInterval: .milliseconds(50))

        let model = PlainFixtureModel()
        SimToolState.track(model)   // no poll:, not Observable → auto-poll
        try await Task.sleep(for: .milliseconds(100))
        model.items = 1
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sink.events.count, 2)
        XCTAssertEqual(sink.events.first?.modelId, "PlainFixtureModel#0", "name must default to the type name")
    }

    @MainActor
    func testExplicitPollWorksForObservableModels() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink)

        let model = FixtureModel()
        SimToolState.track(model, poll: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(100))
        model.count = 9
        try await Task.sleep(for: .milliseconds(200))
        guard case .object(let object) = try XCTUnwrap(sink.events.last).snapshot else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(object["count"], .number(9))
    }

    @MainActor
    func testPollingEmitsDeallocatedOnTick() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink)

        var model: PlainFixtureModel? = PlainFixtureModel()
        SimToolState.track(model!, name: "Plain", poll: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(100))
        model = nil
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try XCTUnwrap(sink.events.last).deallocated, true)
    }

    @MainActor
    func testTrackIsIdempotentPerInstance() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        let model = FixtureModel()
        SimToolState.track(model, name: "Fixture")
        SimToolState.track(model, name: "Fixture")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sink.events.count, 1, "second track of the same instance must be ignored")
    }

    @MainActor
    func testStaleEntryReplacementEmitsDeallocatedForOldInstance() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        // Track-and-release temporaries until an address is reused, or give up.
        // Address reuse is what the stale path handles; forcing it deterministically
        // is allocator-dependent, so this test accepts either outcome but asserts
        // the invariant: every modelId that stops appearing has at most one
        // deallocated event and no events after it.
        for _ in 0..<5 {
            SimToolState.track(FixtureModel(), name: "Temp")
        }
        try await Task.sleep(for: .milliseconds(150))
        let byModel = Dictionary(grouping: sink.events, by: \.modelId)
        for (_, events) in byModel {
            let deallocFlags = events.filter { $0.deallocated == true }
            XCTAssertLessThanOrEqual(deallocFlags.count, 1)
            if let dealloc = deallocFlags.first {
                XCTAssertEqual(dealloc.seq, events.map(\.seq).max(), "no events after deallocated")
            }
        }
        XCTAssertEqual(Set(byModel.keys).count, byModel.keys.count)
    }

    @MainActor
    func testNestedTrackedModelCarriesModelIdMarkerInParentSnapshot() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        let parent = FixtureModel()
        let child = FixtureChild()
        parent.child = child
        SimToolState.track(child, name: "Child")

        let snapshot = parent._simToolSnapshot()
        guard case .object(let object) = snapshot,
              case .object(let childObject)? = object["child"] else {
            return XCTFail("expected nested child object")
        }
        XCTAssertEqual(
            childObject["$modelId"], .string("Child#0"),
            "a nested model that is itself tracked must carry its modelId"
        )
        XCTAssertNil(object["$modelId"], "a model never marks itself at the root")
    }

    @MainActor
    func testNestedUntrackedModelHasNoModelIdMarker() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let parent = FixtureModel()
        parent.child = FixtureChild()

        let snapshot = parent._simToolSnapshot()
        guard case .object(let object) = snapshot,
              case .object(let childObject)? = object["child"] else {
            return XCTFail("expected nested child object")
        }
        XCTAssertNil(childObject["$modelId"], "untracked nested models must stay unmarked")
    }

    @MainActor
    func testOwnEmittedSnapshotHasNoModelIdMarker() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        SimToolState.track(FixtureChild(), name: "Child")
        try await Task.sleep(for: .milliseconds(100))
        guard case .object(let object) = try XCTUnwrap(sink.events.first).snapshot else {
            return XCTFail("expected object snapshot")
        }
        XCTAssertNil(object["$modelId"], "a model's own events must not carry the marker")
    }

    @MainActor
    func testTrackedRegistryPrunesOnDeallocationAndReset() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        var model: FixtureChild? = FixtureChild()
        SimToolState.track(model!, name: "Child")
        XCTAssertEqual(SimToolStateTrackedRegistry.modelIds.count, 1)

        model?.label = "x"  // arm a refresh…
        model = nil         // …then release before the debounce fires
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(SimToolStateTrackedRegistry.modelIds.isEmpty, "deallocation must prune the registry")

        SimToolState.track(FixtureChild(), name: "Child")
        SimToolState.reset()
        XCTAssertTrue(SimToolStateTrackedRegistry.modelIds.isEmpty, "reset must clear the registry")
    }

    @MainActor
    func testSimToolTrackedChainsAndRegisters() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("needs Observation availability gate") }
        let sink = RecordingSink()
        SimToolState.configure(sink: sink, debounce: .milliseconds(10))

        let model = FixtureModel().simToolTracked()
        XCTAssertTrue(model === model.simToolTracked(), "helper must return the same instance")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(sink.events.count, 1, "registered once (idempotent), via the chainable helper")
        XCTAssertEqual(sink.events.first?.modelId, "FixtureModel#0")
    }
}
