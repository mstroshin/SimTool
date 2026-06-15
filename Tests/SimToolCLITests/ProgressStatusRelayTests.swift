import Foundation
import XCTest
@testable import SimToolCLI

final class ProgressStatusRelayTests: XCTestCase {
    func testPrefixesAndDeduplicatesStatuses() {
        let collector = UpdateCollector()
        let relay = ProgressStatusRelay(prefix: "Building App", minimumInterval: 0) { collector.append($0) }
        relay.send("Compiling A.swift")
        relay.send("Compiling A.swift")
        relay.send("Compiling B.swift")
        XCTAssertEqual(collector.updates(), [
            "Building App · Compiling A.swift",
            "Building App · Compiling B.swift",
        ])
    }

    func testThrottlesRapidDistinctUpdates() {
        let collector = UpdateCollector()
        let relay = ProgressStatusRelay(prefix: "Building", minimumInterval: 60) { collector.append($0) }
        relay.send("one")
        relay.send("two")
        relay.send("three")
        XCTAssertEqual(collector.updates(), ["Building · one"])
    }
}

private final class UpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ update: String) {
        lock.lock()
        storage.append(update)
        lock.unlock()
    }

    func updates() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
