import Foundation

/// One spelling for a path the tool prints or stores.
///
/// `URL.standardizedFileURL` cannot be trusted for this on its own: it strips a
/// leading `/private` only when the path already exists, so the same file is
/// printed as `/tmp/x` after it is written and `/private/tmp/x` before — which is
/// how one `simtool init` run managed to report both spellings in one list of
/// takeaways.
public enum FilePathDisplay {
    public static func normalized(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix("/private/") else { return path }
        return String(path.dropFirst("/private".count))
    }
}
