import CryptoKit
import Darwin
import Foundation

/// Keeps two builds from writing one DerivedData at once: two xcodebuild
/// runs there — a `test run` and a `run` in two terminals, say — fail with
/// "database is locked". Each build takes an exclusive `flock` on every
/// directory it writes: its DerivedData, and its project's directory, since
/// Xcode's build location settings can put products next to the workspace
/// whatever `-derivedDataPath` says. A second build waits for the first,
/// saying whom it waits for, instead of failing.
///
/// The locks are files in one directory every SimTool process shares
/// (`SimulatorAppBuildCache.lockRoot`), named by a hash of the locked path.
/// The kernel drops a `flock` when its process exits, so a build that dies
/// never leaves a stale lock behind.
public final class SimulatorAppBuildLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32]

    private init(descriptors: [Int32]) {
        self.descriptors = descriptors
    }

    deinit { release() }

    /// Takes the locks for `paths`, in a fixed order so two builds wanting the
    /// same two never wait on each other. When another build holds one,
    /// `onWait` hears whose it is, then this waits until it is free. `owner`
    /// says who holds the lock, for the next build that has to wait.
    public static func acquire(
        paths: [String],
        in directory: URL,
        owner: String = currentOwner(),
        onWait: (String) -> Void = { _ in }
    ) async throws -> SimulatorAppBuildLock {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let held = SimulatorAppBuildLock(descriptors: [])
        for path in Set(paths).sorted() {
            let url = lockFile(for: path, in: directory)
            let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                throw SimToolError("Unable to open the build lock \(url.path): \(String(cString: strerror(errno)))")
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else {
                    close(descriptor)
                    throw SimToolError("Unable to lock \(url.path): \(String(cString: strerror(errno)))")
                }
                onWait("Waiting for another build of \(path) to finish (\(holder(of: descriptor)))…")
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    // flock blocks its thread: keep it off the cooperative pool.
                    Thread.detachNewThread {
                        while flock(descriptor, LOCK_EX) != 0, errno == EINTR {}
                        continuation.resume()
                    }
                }
            }
            held.append(descriptor)
            record(owner: owner, path: path, in: descriptor)
        }
        return held
    }

    /// Whether some build holds the lock for `path` right now.
    public static func isHeld(path: String, in directory: URL) -> Bool {
        let descriptor = open(lockFile(for: path, in: directory).path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// The lock for `path` if no one holds it, without waiting; nil if
    /// someone does (or it cannot be taken).
    public static func tryAcquire(path: String, in directory: URL, owner: String = currentOwner()) -> SimulatorAppBuildLock? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(lockFile(for: path, in: directory).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        record(owner: owner, path: path, in: descriptor)
        return SimulatorAppBuildLock(descriptors: [descriptor])
    }

    /// Releases every lock taken; releasing twice is harmless.
    public func release() {
        lock.lock()
        let taken = descriptors
        descriptors = []
        lock.unlock()
        for descriptor in taken {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// `simtool app build`: the command that holds a lock, as the next build
    /// waiting for it reads.
    public static func currentOwner() -> String {
        let arguments = ProcessInfo.processInfo.arguments
        let name = arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "simtool"
        let command = arguments.dropFirst().prefix { !$0.hasPrefix("-") }.prefix(2)
        return ([name] + command).joined(separator: " ")
    }

    static func lockFile(for path: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest.prefix(32)).lock")
    }

    /// Writes who holds the lock into its file, for whoever waits on it.
    private static func record(owner: String, path: String, in descriptor: Int32) {
        let line = "\(getpid())\t\(ISO8601DateFormatter().string(from: Date()))\t\(owner)\t\(path)\n"
        ftruncate(descriptor, 0)
        _ = line.withCString { pwrite(descriptor, $0, strlen($0), 0) }
    }

    private func append(_ descriptor: Int32) {
        lock.lock()
        descriptors.append(descriptor)
        lock.unlock()
    }

    /// Who holds the lock open on `descriptor`, from what it wrote there.
    private static func holder(of descriptor: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return "held by another process" }
        let fields = String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return "held by another process" }
        var since = ""
        if let date = ISO8601DateFormatter().date(from: String(fields[1])) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            since = ", since \(formatter.string(from: date))"
        }
        return "\(fields[2]), pid \(fields[0])\(since)"
    }
}
