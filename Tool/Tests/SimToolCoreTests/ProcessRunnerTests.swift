import Foundation
import XCTest
@testable import SimToolCore

final class ProcessRunnerTests: XCTestCase {
    func testRunDeliversStdoutLinesIncludingUnterminatedTail() async throws {
        let collector = LineCollector()
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'one\\ntwo\\nthree'"],
            onStdoutLine: { collector.append($0) }
        )
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdoutString, "one\ntwo\nthree")
        XCTAssertEqual(collector.lines(), ["one", "two", "three"])
    }

    func testRunSkipsEmptyLines() async throws {
        let collector = LineCollector()
        _ = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'a\\n\\nb\\n'"],
            onStdoutLine: { collector.append($0) }
        )
        XCTAssertEqual(collector.lines(), ["a", "b"])
    }

    func testRunWithoutLineCallbackStillBuffersOutput() async throws {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'plain\\n'"]
        )
        XCTAssertEqual(output.stdoutString, "plain\n")
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
