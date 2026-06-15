import Foundation

/// Diagnostic logging for SimTool internals, written to stderr.
/// Off by default; the CLI enables it when `--verbose` is passed.
public enum DebugLog {
    public static var isEnabled = false

    public static func write(_ tag: String, _ message: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[\(tag)] \(message)\n".utf8))
    }
}
