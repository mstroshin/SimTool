import CoreServices
import Foundation

/// Calls `onChange` when a file under the tests directory is added, edited,
/// renamed or removed, so the viewer's test list follows the YAML files without
/// asking for them. FSEvents watches by path: a directory that does not exist
/// yet is picked up once it is created.
final class TestDefinitionsWatcher: @unchecked Sendable {
    private let root: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "simtool.tests.watch")
    private var stream: FSEventStreamRef?

    init(root: URL, onChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<TestDefinitionsWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [Self.realPath(root)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // An editor's save is several events; one batch reads the files once.
            0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// FSEvents reports, and matches, real paths: through a symlink such as
    /// /tmp or /var it hears nothing. Resolves the part of `url` that exists.
    private static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        // realpath, not resolvingSymlinksInPath: that one strips /private again.
        var resolved = existing
        if let real = realpath(existing.path, nil) {
            resolved = URL(fileURLWithPath: String(cString: real))
            free(real)
        }
        for component in missing {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        // On the stream's queue, so no callback is still running once it returns.
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
