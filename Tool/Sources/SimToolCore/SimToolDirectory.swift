import Foundation

/// The per-project `.simtool/` directory: the project config, build checksum
/// metadata, and test sessions all live here. Discovered by walking up from
/// the invocation directory; created lazily on first write, together with a
/// self-ignoring `.gitignore` so the whole folder stays out of git.
public enum SimToolDirectory {
    public static let directoryName = ".simtool"
    public static let configFileName = "config.yml"

    /// First existing `.simtool` directory walking up from `startDirectory`.
    ///
    /// Walks using filesystem path strings rather than `URL` path
    /// manipulation: `NSString.deletingLastPathComponent` converges
    /// deterministically at the root ("/" -> "/"), whereas
    /// `URL.deletingLastPathComponent()` does not reach a `.path` fixed point
    /// on newer Foundation `URL` backends, which would loop forever.
    public static func locate(
        startDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        var directory = startDirectory.standardizedFileURL.path
        while true {
            let candidate = (directory as NSString).appendingPathComponent(directoryName)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: candidate, isDirectory: true).standardizedFileURL
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { return nil }
            directory = parent
        }
    }

    /// The located `.simtool` directory, or `<startDirectory>/.simtool` when
    /// none exists anywhere up the tree. Does not touch the filesystem; the
    /// fallback is created later, on first write, via `ensure`.
    public static func resolve(
        startDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL {
        locate(startDirectory: startDirectory)
            ?? startDirectory.standardizedFileURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Creates the directory (with intermediates) and a `.gitignore`
    /// containing `*` so git ignores the whole folder. An existing
    /// `.gitignore` is never overwritten — user edits win.
    public static func ensure(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gitignore = directory.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: gitignore.path) {
            try Data("*\n".utf8).write(to: gitignore, options: [.atomic])
        }
    }

    /// Ensures the nearest `.simtool` ancestor of `path` (including `path`
    /// itself). No-op when `path` is not inside a `.simtool` directory, so
    /// stores rooted at arbitrary paths (test fixtures) stay untouched.
    public static func ensureEnclosing(_ path: URL) throws {
        var directory = path.standardizedFileURL.path
        while true {
            if (directory as NSString).lastPathComponent == directoryName {
                try ensure(URL(fileURLWithPath: directory, isDirectory: true))
                return
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { return }
            directory = parent
        }
    }

    /// `<.simtool>/build` — per-project build checksum metadata.
    public static func buildMetadataDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("build", isDirectory: true)
    }

    /// `<.simtool>/test-sessions` — recorded agent test sessions.
    public static func testSessionsDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("test-sessions", isDirectory: true)
    }

    /// `<.simtool>/flows` — declarative UI test flows for `simtool test run`.
    public static func flowsDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("flows", isDirectory: true)
    }
}
