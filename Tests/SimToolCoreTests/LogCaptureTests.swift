import Foundation
import XCTest
@testable import SimToolCore

final class LogCaptureTests: XCTestCase {
    func testParsesNDJSONLineIntoStructuredEntry() throws {
        let line = #"{"timestamp":"2026-01-01 00:00:00.123","eventMessage":"hello world","messageType":"Error","subsystem":"com.example.MyApp","category":"ConsoleLogger","processImagePath":"/path/to/My App.app/My App"}"#
        let draft = try XCTUnwrap(SimulatorLogCapture.parseOSLogLine(line))
        XCTAssertEqual(draft.source, .oslog)
        XCTAssertEqual(draft.message, "hello world")
        XCTAssertEqual(draft.level, "Error")
        XCTAssertEqual(draft.subsystem, "com.example.MyApp")
        XCTAssertEqual(draft.category, "ConsoleLogger")
        XCTAssertEqual(draft.process, "My App")
        XCTAssertEqual(draft.timestamp, "2026-01-01 00:00:00.123")
    }

    func testParsesProcessIDFromNDJSONLine() throws {
        let line = #"{"timestamp":"2026-01-01 00:00:00.123","eventMessage":"hi","processID":4412,"processImagePath":"/path/App.app/App"}"#
        let draft = try XCTUnwrap(SimulatorLogCapture.parseOSLogLine(line))
        XCTAssertEqual(draft.pid, 4412)
    }

    func testLogEntryRoundTripsWithAndWithoutLaunchFields() throws {
        let tagged = LogEntry(sequence: 1, timestamp: "t", source: .oslog, message: "m", pid: 4412, launchId: 2)
        let taggedData = try JSON.data(tagged)
        XCTAssertEqual(try JSON.decoder.decode(LogEntry.self, from: taggedData), tagged)

        // Legacy payload without pid/launchId still decodes (fields are optional additions).
        let legacy = #"{"sequence":1,"timestamp":"t","source":"oslog","message":"m"}"#
        let decoded = try JSON.decoder.decode(LogEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.pid)
        XCTAssertNil(decoded.launchId)
    }

    func testFallsBackToRawMessageForUndecodableLine() throws {
        let draft = try XCTUnwrap(SimulatorLogCapture.parseOSLogLine("not json at all"))
        XCTAssertEqual(draft.source, .oslog)
        XCTAssertEqual(draft.message, "not json at all")
        XCTAssertNil(draft.subsystem)
        XCTAssertNil(draft.level)
    }

    func testSkipsEmptyLine() {
        XCTAssertNil(SimulatorLogCapture.parseOSLogLine("   "))
        XCTAssertNil(SimulatorLogCapture.parseOSLogLine(""))
    }

    func testSkipsLogStreamPredicateBanner() {
        XCTAssertNil(SimulatorLogCapture.parseOSLogLine(#"Filtering the log data using "subsystem BEGINSWITH "com.apple.Preferences""#))
    }

    func testStoreAssignsMonotonicSequenceAndDropsOldestOverCapacity() {
        let store = LogEntryStore(capacity: 3)
        for index in 0..<5 {
            store.append(LogEntryDraft(timestamp: "t\(index)", source: .stdout, message: "line \(index)"))
        }
        let payload = store.query(since: nil, limit: 100)
        XCTAssertEqual(payload.entries.map(\.message), ["line 2", "line 3", "line 4"])
        XCTAssertEqual(payload.entries.map(\.sequence), [2, 3, 4])
        XCTAssertEqual(payload.cursor, 4)
        XCTAssertEqual(payload.droppedCount, 2)
    }

    func testStoreQuerySinceReturnsOnlyNewerEntriesWithoutGaps() {
        let store = LogEntryStore(capacity: 100)
        for index in 0..<5 {
            store.append(LogEntryDraft(timestamp: "t\(index)", source: .oslog, message: "line \(index)"))
        }
        let first = store.query(since: nil, limit: 2)
        XCTAssertEqual(first.entries.map(\.sequence), [3, 4])
        XCTAssertEqual(first.cursor, 4)

        store.append(LogEntryDraft(timestamp: "t5", source: .oslog, message: "line 5"))
        let next = store.query(since: 4, limit: 100)
        XCTAssertEqual(next.entries.map(\.message), ["line 5"])
        XCTAssertEqual(next.cursor, 5)
    }

    func testDeleteEntriesDropsOnlyMatchingLaunch() {
        let store = LogEntryStore(capacity: 100)
        store.append(LogEntryDraft(timestamp: "t0", source: .oslog, message: "a"), launchId: 1)
        store.append(LogEntryDraft(timestamp: "t1", source: .oslog, message: "b"), launchId: 2)
        store.append(LogEntryDraft(timestamp: "t2", source: .oslog, message: "c"), launchId: 1)

        let removed = store.deleteEntries(launchId: 1)

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.query(since: nil, limit: 100).entries.map(\.message), ["b"])
        XCTAssertEqual(store.deleteEntries(launchId: 99), 0)
    }

    func testStoreCursorOlderThanRetainedReturnsOldestAvailable() {
        let store = LogEntryStore(capacity: 100)
        for index in 0..<3 {
            store.append(LogEntryDraft(timestamp: "t\(index)", source: .oslog, message: "line \(index)"))
        }
        let payload = store.query(since: -1, limit: 1)
        XCTAssertEqual(payload.entries.map(\.sequence), [0])
        XCTAssertEqual(payload.cursor, 0)
    }

    func testLineBufferReassemblesAcrossSplitChunks() {
        var buffer = LogLineBuffer()
        XCTAssertEqual(buffer.append(Data("partial".utf8)), [])
        XCTAssertEqual(buffer.append(Data(" line\nsecond".utf8)), ["partial line"])
        XCTAssertEqual(buffer.append(Data(" line\r\n".utf8)), ["second line"])
        XCTAssertNil(buffer.flush())
    }

    func testIsErrorDetectsErrorFamilyMessagesAndLevels() {
        func entry(_ message: String, level: String? = nil, source: LogSource = .stdout) -> LogEntry {
            LogEntry(sequence: 0, timestamp: "t", source: source, message: message, level: level)
        }
        XCTAssertTrue(entry("Fatal error: index out of range").isError)
        XCTAssertTrue(entry("Got an Error from the server").isError)
        XCTAssertTrue(entry("unhandled exception thrown").isError)
        XCTAssertTrue(entry("❌ [Sync] - refresh failed").isError)
        XCTAssertTrue(entry("something", level: "Error").isError)
        XCTAssertTrue(entry("something", level: "Fault").isError)

        XCTAssertFalse(entry("ℹ️ [Analytics] - Log event: ViewShown").isError)
        XCTAssertFalse(entry("configured errorHandler successfully").isError)
        XCTAssertFalse(entry("info message", level: "Info").isError)
    }

    func testLineBufferFlushReturnsTrailingRemainder() {
        var buffer = LogLineBuffer()
        XCTAssertEqual(buffer.append(Data("a\nb".utf8)), ["a"])
        XCTAssertEqual(buffer.flush(), "b")
    }
}
