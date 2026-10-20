import Foundation
import SimToolCore

/// What was done to the device, oldest first, for the viewer's activity feed.
///
/// An entry changes while it runs — a tap starts, learns where it lands,
/// finishes — and every change gives it the log's next revision. A reader that
/// asks for what changed `since` the revision it last saw gets each entry as it
/// is now, once per change, without the log keeping a cursor per reader.
/// An observer hears of every change too, outside the log's lock.
final class DeviceActivityLog: @unchecked Sendable {
    typealias Observer = @Sendable (_ entry: DeviceActivity, _ revision: Int) -> Void

    let capacity: Int

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var entries: [DeviceActivity] = []
    private var nextId = 1
    private var revision = 0
    private var observer: Observer?

    init(capacity: Int = 500, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    /// Hears of each change after it is made: the entry as it is now and the
    /// log's revision.
    func observe(_ observer: @escaping Observer) {
        lock.withLock { self.observer = observer }
    }

    /// Starts an activity that runs until `finish`.
    @discardableResult
    func begin(
        actor: DeviceActivityActor,
        via: String?,
        kind: String,
        title: String,
        detail: String? = nil,
        gesture: DeviceActivityGesture? = nil,
        at: Date? = nil
    ) -> DeviceActivity {
        notifying(insert(actor: actor, via: via, kind: kind, title: title, detail: detail, gesture: gesture, at: at))
    }

    /// An activity that is over as soon as it is said: a mock armed, a step
    /// logged. One change, so an observer hears of it once.
    @discardableResult
    func record(
        actor: DeviceActivityActor,
        via: String?,
        kind: String,
        title: String,
        detail: String? = nil,
        failed error: String? = nil,
        at: Date? = nil
    ) -> DeviceActivity {
        let opened = insert(actor: actor, via: via, kind: kind, title: title, detail: detail, gesture: nil, at: at)
        let endedAt = now()
        return notifying(change(id: opened.entry.id) { entry in
            entry.endedAt = endedAt
            entry.status = error == nil ? .done : .failed
            entry.error = error
        } ?? opened)
    }

    /// Changes a running or finished entry; nil once it has aged out.
    @discardableResult
    func update(id: Int, _ change: (inout DeviceActivity) -> Void) -> DeviceActivity? {
        self.change(id: id, change).map(notifying)
    }

    private func insert(
        actor: DeviceActivityActor,
        via: String?,
        kind: String,
        title: String,
        detail: String?,
        gesture: DeviceActivityGesture?,
        at: Date?
    ) -> (entry: DeviceActivity, revision: Int, observer: Observer?) {
        lock.withLock {
            revision += 1
            let entry = DeviceActivity(
                id: nextId,
                revision: revision,
                actor: actor,
                via: via,
                kind: kind,
                title: title,
                detail: detail,
                at: at ?? now(),
                status: .running,
                gesture: gesture
            )
            nextId += 1
            entries.append(entry)
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
            return (entry, revision, observer)
        }
    }

    private func change(id: Int, _ change: (inout DeviceActivity) -> Void) -> (entry: DeviceActivity, revision: Int, observer: Observer?)? {
        lock.withLock {
            guard let index = entries.lastIndex(where: { $0.id == id }) else { return nil }
            change(&entries[index])
            revision += 1
            entries[index].revision = revision
            return (entries[index], revision, observer)
        }
    }

    /// Tells the observer, outside the lock, and hands the entry back.
    private func notifying(_ changed: (entry: DeviceActivity, revision: Int, observer: Observer?)) -> DeviceActivity {
        changed.observer?(changed.entry, changed.revision)
        return changed.entry
    }

    /// Ends an activity: done, or failed with `error`.
    @discardableResult
    func finish(id: Int, error: String? = nil) -> DeviceActivity? {
        let endedAt = now()
        return update(id: id) { entry in
            entry.endedAt = endedAt
            entry.status = error == nil ? .done : .failed
            entry.error = error
        }
    }

    /// A client's report (`POST /api/v1/activity`): a new entry, or with its
    /// `id` the end of one it reported before. A report without words is
    /// refused rather than shown as a blank row.
    func apply(_ report: DeviceActivityReport) throws -> DeviceActivity {
        if let id = report.id {
            let status = report.status ?? (report.error == nil ? .done : .failed)
            let endedAt = now()
            let updated = update(id: id) { entry in
                if let title = Self.words(report.title) { entry.title = title }
                if let detail = Self.words(report.detail) { entry.detail = detail }
                if let gesture = report.gesture { entry.gesture = gesture }
                entry.status = status
                entry.error = status == .failed ? (Self.words(report.error) ?? "failed") : nil
                if status != .running { entry.endedAt = endedAt }
            }
            guard let updated else { throw SimToolError("No activity \(id) on this server") }
            return updated
        }
        guard let title = Self.words(report.title) else { throw SimToolError("An activity report needs a title") }
        let entry = begin(
            actor: report.actor ?? .agent,
            via: Self.words(report.via),
            kind: Self.words(report.kind) ?? "action",
            title: title,
            detail: Self.words(report.detail),
            gesture: report.gesture
        )
        guard let status = report.status, status != .running else { return entry }
        return finish(id: entry.id, error: status == .failed ? (Self.words(report.error) ?? "failed") : nil) ?? entry
    }

    /// Entries changed after revision `since` (all of them without it), at most
    /// the newest `limit`, oldest first — and the revision to ask from next. A
    /// `since` ahead of the log comes from a server that has since restarted:
    /// the reader gets everything again instead of nothing until it catches up.
    func query(since: Int?, limit: Int = 200) -> (entries: [DeviceActivity], revision: Int) {
        lock.withLock {
            let since = since.flatMap { $0 <= revision ? $0 : nil }
            var changed = since.map { since in entries.filter { $0.revision > since } } ?? entries
            if changed.count > limit { changed.removeFirst(changed.count - limit) }
            return (changed, revision)
        }
    }

    /// The newest entry, if any, matching `predicate`.
    func last(where predicate: (DeviceActivity) -> Bool) -> DeviceActivity? {
        lock.withLock { entries.last(where: predicate) }
    }

    private static func words(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(500))
    }
}
