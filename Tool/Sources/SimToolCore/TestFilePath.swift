import Foundation

/// How a test file is named to whoever reads a report or re-runs the test.
public enum TestFilePath {
    /// The path a receiver can paste: relative to the project when the file is
    /// inside it, its file name otherwise.
    ///
    /// Relative rather than absolute because an absolute path names the sender's
    /// machine; relative rather than bare because a bare file name does not
    /// resolve from the project root, which is where whoever re-runs the test
    /// stands. Both sides are symlink-resolved first: `/tmp` and `/private/tmp`
    /// are the same directory on macOS and reach this function from different
    /// places — a shell's working directory and a standardized URL.
    public static func display(file: URL, projectRoot: URL?) -> String {
        guard let projectRoot else { return file.lastPathComponent }
        let root = normalized(projectRoot)
        let path = normalized(file)
        guard path.hasPrefix(root + "/") else { return file.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private static func normalized(_ url: URL) -> String {
        FilePathDisplay.normalized(url)
    }
}
