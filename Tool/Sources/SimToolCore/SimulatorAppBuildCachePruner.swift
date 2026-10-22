import Foundation

/// One DerivedData directory of SimTool's managed build cache
/// (`~/Library/Caches/SimTool/app-builds/DerivedData/<key>`), as a prune sees it.
public struct SimulatorAppBuildCacheEntry: Codable, Equatable, Sendable {
    public var path: String
    /// The workspace or project it was built from, as xcodebuild recorded it
    /// in the entry's `info.plist`; nil when it recorded none.
    public var workspacePath: String?
    /// When a build last used it: the later of xcodebuild's
    /// `LastAccessedDate` and the directory's modification date, which a
    /// cache hit on it refreshes.
    public var lastUsed: Date?
    /// Why it goes: `workspace gone`, `unused for 45 days`, `all`. Nil for an
    /// entry the prune keeps.
    public var reason: String?
    /// Its size on disk, measured for the entries that go.
    public var bytes: Int64?
    /// A build is using it right now, so it stays whatever the reason.
    public var inUse: Bool
    public var deleted: Bool

    public init(
        path: String,
        workspacePath: String? = nil,
        lastUsed: Date? = nil,
        reason: String? = nil,
        bytes: Int64? = nil,
        inUse: Bool = false,
        deleted: Bool = false
    ) {
        self.path = path
        self.workspacePath = workspacePath
        self.lastUsed = lastUsed
        self.reason = reason
        self.bytes = bytes
        self.inUse = inUse
        self.deleted = deleted
    }
}

public struct SimulatorAppBuildCachePrunePayload: Codable, Equatable, Sendable {
    public var root: String
    /// Every entry of the cache; those with a `reason` go, unless `inUse`.
    public var entries: [SimulatorAppBuildCacheEntry]
    /// The size of what goes (or went, with `deleted`).
    public var bytes: Int64
    /// Whether this was a real prune, not a dry run.
    public var deleted: Bool

    public init(root: String, entries: [SimulatorAppBuildCacheEntry], bytes: Int64, deleted: Bool) {
        self.root = root
        self.entries = entries
        self.bytes = bytes
        self.deleted = deleted
    }

    /// The entries that go: a reason, and no build using them.
    public var removable: [SimulatorAppBuildCacheEntry] {
        entries.filter { $0.reason != nil && !$0.inUse }
    }
}

/// Clears out SimTool's managed DerivedData — one directory per build
/// identity, gigabytes each, never removed by a build itself. An entry goes
/// when the workspace or project it was built from no longer exists (a
/// removed worktree, a deleted checkout), when no build has used it for
/// `olderThanDays`, or with `all`. A dry run unless `delete`: it lists what
/// would go and how much space that frees.
///
/// Only the managed cache is touched: a DerivedData path set in a project's
/// config belongs to that project.
public enum SimulatorAppBuildCachePruner {
    public static func prune(
        cache: SimulatorAppBuildCache,
        olderThanDays: Int? = nil,
        all: Bool = false,
        delete: Bool = false,
        now: Date = Date()
    ) -> SimulatorAppBuildCachePrunePayload {
        // Spelled as builds spell it: their locks are keyed by this path.
        let root = cache.derivedDataRoot
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        var entries: [SimulatorAppBuildCacheEntry] = []
        for name in names {
            let url = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            var entry = describe(url)
            entry.reason = reason(for: entry, olderThanDays: olderThanDays, all: all, now: now)
            if entry.reason != nil {
                // The build that holds it locks it by this very path.
                entry.inUse = SimulatorAppBuildLock.isHeld(path: url.path, in: cache.lockRoot)
                entry.bytes = allocatedSize(of: url)
            }
            entries.append(entry)
        }
        if delete {
            for index in entries.indices where entries[index].reason != nil && !entries[index].inUse {
                // Held while it goes, so no build starts in it meanwhile.
                guard let lock = SimulatorAppBuildLock.tryAcquire(path: entries[index].path, in: cache.lockRoot) else {
                    entries[index].inUse = true
                    continue
                }
                entries[index].deleted = (try? FileManager.default.removeItem(atPath: entries[index].path)) != nil
                lock.release()
            }
        }
        let going = entries.filter { delete ? $0.deleted : ($0.reason != nil && !$0.inUse) }
        return SimulatorAppBuildCachePrunePayload(
            root: root.path,
            entries: entries,
            bytes: going.reduce(0) { $0 + ($1.bytes ?? 0) },
            deleted: delete
        )
    }

    /// What xcodebuild recorded about the entry in its `info.plist`.
    static func describe(_ url: URL) -> SimulatorAppBuildCacheEntry {
        let info = (try? Data(contentsOf: url.appendingPathComponent("info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] }
        let workspacePath = (info?["WorkspacePath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return SimulatorAppBuildCacheEntry(
            path: url.path,
            workspacePath: workspacePath,
            lastUsed: [info?["LastAccessedDate"] as? Date, modified].compactMap { $0 }.max()
        )
    }

    static func reason(for entry: SimulatorAppBuildCacheEntry, olderThanDays: Int?, all: Bool, now: Date) -> String? {
        if all { return "all" }
        if let workspace = entry.workspacePath, !FileManager.default.fileExists(atPath: workspace) {
            return "workspace gone"
        }
        if let olderThanDays, let lastUsed = entry.lastUsed {
            let days = Int(now.timeIntervalSince(lastUsed) / 86_400)
            if days >= olderThanDays { return "unused for \(days) days" }
        }
        return nil
    }

    /// Bytes the directory takes on disk, its links not followed.
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
