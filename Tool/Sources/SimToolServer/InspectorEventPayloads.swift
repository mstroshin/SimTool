import Foundation
import SimToolCore
import SimToolNetworkLogger
import SimToolStateLogger

// What each topic of `GET /api/v1/events` carries. A message holds only the
// fields of what changed; a `snapshot` holds every topic in the same shapes,
// complete, and replaces what the viewer had.

/// `snapshot`: the whole inspector state as of the event id it carries.
struct InspectorSnapshotPayload: Encodable {
    var instance: String
    var network: NetworkTopicPayload
    var logs: LogsTopicPayload
    var state: StateTopicPayload
    var tests: TestsTopicPayload
    var launches: AppLaunchesPayload
    var activity: ActivityTopicPayload
    var device: DeviceTopicPayload
}

/// `device`: the device's screens as they read now — on a foldable, which one
/// is lit and how each picture is turned. Sent whole whenever that changes.
struct DeviceTopicPayload: Encodable {
    var displays: [ServerDisplayPayload]
    var activeDisplay: String?
}

/// `network`: calls the app reported (a known id replaces its call), the
/// launch whose calls were deleted, or the mock rules now in force.
struct NetworkTopicPayload: Encodable {
    var events: [NetworkLoggerEvent]?
    var removedLaunch: Int?
    var mocks: [MockRule]?
}

/// `logs`: captured lines in sequence order, the launch whose lines were
/// deleted, or `cleared` when a capture restarted with other settings emptied
/// the buffer.
struct LogsTopicPayload: Encodable {
    var entries: [LogEntry]?
    var droppedCount: Int?
    var removedLaunch: Int?
    var cleared: Bool?
}

/// `state`: model snapshots in cursor order.
struct StateTopicPayload: Encodable {
    var events: [StateLoggerEvent]
}

/// `activity`: what was done to the device — an entry each time it opens,
/// learns where its finger goes or ends — with the log's revision, so a viewer
/// that falls back to polling asks from where the stream left it.
struct ActivityTopicPayload: Encodable {
    var entries: [DeviceActivity]
    var revision: Int
}

/// `tests`: a session that started, stepped or stopped, a deleted session, the
/// run in progress, or the test files as they read now.
struct TestsTopicPayload: Encodable {
    var sessions: [TestSession]?
    var session: TestSession?
    var removedSession: String?
    var definitions: [TestSummary]?
    var run: TestRunStatusPayload?
}
