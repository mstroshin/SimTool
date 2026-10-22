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

    // A long build's output goes to its log in full; memory keeps the end.
    func testRunWithALogWritesEverythingThereAndKeepsOnlyTheEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("nested/build.log")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the previous build's log".utf8).write(to: logURL)
        let collector = LineCollector()
        // 3000 numbered lines (~40 KB) on stdout, a note on stderr, then a
        // multi-byte character at the very end.
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=1; while [ $i -le 3000 ]; do echo \"line $i of the build output\"; i=$((i+1)); done; echo 'to stderr' >&2; printf 'Привет'"],
            log: ProcessOutputLog(url: logURL, retainedBytes: 1_001),
            onStdoutLine: { collector.append($0) }
        )
        XCTAssertEqual(output.status, 0)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("previous build"), "each run replaces the log")
        XCTAssertTrue(log.hasPrefix("line 1 of the build output\n"))
        XCTAssertTrue(log.contains("line 3000 of the build output\n"))
        // The two streams interleave as their chunks arrive, in no fixed order.
        XCTAssertTrue(log.contains("to stderr\n"))
        XCTAssertTrue(log.replacingOccurrences(of: "to stderr\n", with: "").hasSuffix("line 3000 of the build output\nПривет"))
        // Memory holds the end, cut where it still decodes.
        XCTAssertLessThanOrEqual(output.stdout.count, 1_001)
        XCTAssertGreaterThan(output.stdout.count, 900)
        XCTAssertTrue(output.stdoutString.hasSuffix("line 3000 of the build output\nПривет"), output.stdoutString)
        XCTAssertFalse(output.stdoutString.contains("line 1 of"))
        XCTAssertEqual(output.stderrString, "to stderr\n")
        // Every line still reaches the callback.
        XCTAssertEqual(collector.lines().count, 3_001)
    }

    func testATimedOutRunSaysSoByType() async throws {
        do {
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeoutSeconds: 0.2
            )
            XCTFail("sleep 5 outlived a 0.2 s limit")
        } catch let timeout as ProcessTimeoutError {
            XCTAssertEqual(timeout.seconds, 0.2)
            XCTAssertEqual(timeout.command, "/bin/sleep 5")
            XCTAssertEqual(timeout.localizedDescription, "Process timed out after 0.2 seconds: /bin/sleep 5")
        }
    }

    // A build must not outlive its run: past the limit, the child and what it
    // started (the compilers under xcodebuild) are interrupted as Ctrl-C at
    // their terminal would, and gone before the timeout is reported.
    func testATimedOutChildThatMustNotOutliveSimToolIsGoneWithItsGroup() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"), "perl not available")
        let collector = LineCollector()
        do {
            // A parent and the child it forked, like xcodebuild and a compiler.
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", "my $p = fork(); if ($p == 0) { sleep 30; exit 0 } $| = 1; print \"$p\\n\"; waitpid($p, 0)"],
                timeoutSeconds: 1,
                stopsWithSimTool: true,
                onStdoutLine: { collector.append($0) }
            )
            XCTFail("the child outlived its limit")
        } catch is ProcessTimeoutError {}
        let grandchild = try XCTUnwrap(collector.lines().first.flatMap { Int32($0) })
        XCTAssertEqual(kill(grandchild, 0), -1, "the child's own child is gone too")
        XCTAssertEqual(errno, ESRCH)
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
