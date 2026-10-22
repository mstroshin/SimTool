import Darwin
import Foundation

/// The content hashes of a project's build-input files, by what `stat` says
/// of each, so a fingerprint reads only the files that changed since the
/// last one: reading every source of a large project costs seconds on every
/// `run`, a `stat` of each a fraction of that.
///
/// A file's hash is reused only while its size, modification time, change
/// time and inode are all as they were. The change time cannot be set back
/// by any tool, so content rewritten in place — even with its old size and
/// modification time restored — reads again. A file changed close to when
/// its hash was taken is not trusted either (git's "racily clean" rule):
/// timestamps that coarse cannot tell two writes in the same tick apart.
///
/// Stored as `.simtool/build/input-hashes.tsv`, one line per file; a missing
/// or unreadable file only means everything is read once more.
struct SimulatorAppInputHashCache {
    struct Status: Equatable {
        var size: Int64
        var modified: Int64
        var changed: Int64
        var inode: UInt64

        /// The status of the file at `path`, links followed — as reading it does.
        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            self.init(
                size: Int64(info.st_size),
                modified: Self.nanoseconds(info.st_mtimespec),
                changed: Self.nanoseconds(info.st_ctimespec),
                inode: UInt64(info.st_ino)
            )
        }

        init(size: Int64, modified: Int64, changed: Int64, inode: UInt64) {
            self.size = size
            self.modified = modified
            self.changed = changed
            self.inode = inode
        }

        private static func nanoseconds(_ time: timespec) -> Int64 {
            Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
        }
    }

    /// How close to the hashing a change makes a file's hash untrusted.
    static let racyWindowNanoseconds: Int64 = 2_000_000_000

    private var entries: [String: (status: Status, hash: String)] = [:]
    /// When the hashes were taken: the start of the fingerprint that wrote them.
    var writtenAt: Date?

    init() {}

    /// The hash recorded for `path` when its file is as it was then.
    func hash(of path: String, status: Status) -> String? {
        guard let entry = entries[path], entry.status == status, let writtenAt else { return nil }
        let taken = Int64(writtenAt.timeIntervalSince1970 * 1_000_000_000)
        guard max(status.modified, status.changed) < taken - Self.racyWindowNanoseconds else { return nil }
        return entry.hash
    }

    mutating func record(_ path: String, status: Status, hash: String) {
        entries[path] = (status, hash)
    }

    static func load(from url: URL) -> SimulatorAppInputHashCache {
        var cache = SimulatorAppInputHashCache()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return cache }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard let header = lines.next(), header.hasPrefix("# simtool input hashes "),
              let seconds = TimeInterval(header.dropFirst("# simtool input hashes ".count))
        else { return cache }
        cache.writtenAt = Date(timeIntervalSince1970: seconds)
        while let line = lines.next() {
            // hash, size, modified, changed, inode, path — the path last, as it may hold tabs.
            let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6,
                  let size = Int64(fields[1]), let modified = Int64(fields[2]),
                  let changed = Int64(fields[3]), let inode = UInt64(fields[4])
            else { continue }
            let status = Status(size: size, modified: modified, changed: changed, inode: inode)
            cache.entries[String(fields[5])] = (status, String(fields[0]))
        }
        return cache
    }

    /// Writes the cache; failing to only costs the next fingerprint its reads.
    func write(to url: URL) {
        guard let writtenAt else { return }
        var text = "# simtool input hashes \(writtenAt.timeIntervalSince1970)\n"
        for (path, entry) in entries.sorted(by: { $0.key < $1.key }) where !path.contains("\n") {
            let status = entry.status
            text += "\(entry.hash)\t\(status.size)\t\(status.modified)\t\(status.changed)\t\(status.inode)\t\(path)\n"
        }
        try? SimToolDirectory.ensureEnclosing(url.deletingLastPathComponent())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: [.atomic])
    }
}
