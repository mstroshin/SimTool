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

    // A child that never exits has to become an error, and quickly. `await` on
    // one is not a suspension point anything can cancel: a wedged
    // `simctl io … screenshot` froze a whole crawl, its minute budget stopped
    // applying, and `POST /api/v1/explore/stop` had nothing to interrupt —
    // killing the child by hand was the only way out.
    func testAChildThatNeverExitsFailsOnTheTimeoutInsteadOfHanging() async throws {
        let started = Date()
        do {
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 30"],
                timeoutSeconds: 0.5
            )
            XCTFail("a process that outlives its timeout must not return normally")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("timed out"),
                "the failure has to say what happened, got \(error.localizedDescription)"
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the wait is the timeout, not the child")
    }

    // The two clients the crawl leans on every step carry a bound of their own,
    // so nothing has to remember to pass one.
    func testTheSimulatorClientsAreBoundedByDefault() {
        XCTAssertGreaterThan(AxeClient.defaultTimeoutSeconds, 0)
        XCTAssertGreaterThan(SimulatorScreenshotClient.defaultTimeoutSeconds, 0)
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
