import XCTest
@testable import SimToolCore

final class BootedSimulatorRegistryTests: XCTestCase {
    func testRecordDeduplicatesAndPreservesOrder() {
        let registry = BootedSimulatorRegistry()
        registry.record("A")
        registry.record("B")
        registry.record("A")
        XCTAssertEqual(registry.all(), ["A", "B"])
    }

    func testForgetRemovesOnlyTheGivenDevice() {
        let registry = BootedSimulatorRegistry()
        registry.record("A")
        registry.record("B")
        registry.forget("A")
        XCTAssertEqual(registry.all(), ["B"])
        // Forgetting an unknown udid is a no-op.
        registry.forget("Z")
        XCTAssertEqual(registry.all(), ["B"])
    }

    func testAllReturnsAnIndependentSnapshot() {
        let registry = BootedSimulatorRegistry()
        registry.record("A")
        var snapshot = registry.all()
        snapshot.append("mutated")
        XCTAssertEqual(registry.all(), ["A"])
    }
}
