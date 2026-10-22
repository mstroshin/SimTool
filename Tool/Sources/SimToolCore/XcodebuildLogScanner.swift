import Foundation

/// Reads an xcodebuild log line by line as it streams and keeps what SimTool
/// needs once the build ends, so the log itself need not stay in memory — a
/// large project's runs to hundreds of megabytes:
///
/// - the lines that explain a failure (`XcodebuildFailure.isErrorLine`);
/// - the top-level `.app` bundles the build wrote, which locate the product
///   without asking `xcodebuild -showBuildSettings` — a second run that
///   loads the whole workspace again, for tens of seconds on a large one.
public final class XcodebuildLogScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: String
    private let maxErrorLines: Int
    private var errorLines: [String] = []
    private var apps: [String] = []

    public init(configuration: String, maxErrorLines: Int = 500) {
        self.configuration = configuration
        self.maxErrorLines = maxErrorLines
    }

    public func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isError = XcodebuildFailure.isErrorLine(trimmed)
        let found = Self.appBundles(inTaskLine: line, configuration: configuration)
        guard isError || !found.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if isError {
            errorLines.append(trimmed)
            if errorLines.count > maxErrorLines { errorLines.removeFirst(errorLines.count - maxErrorLines) }
        }
        for app in found where !apps.contains(app) { apps.append(app) }
    }

    /// The failure-explaining lines seen, the last `maxErrorLines` of them.
    public var failureLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return errorLines
    }

    /// The top-level `.app` bundles the build's task lines name, in order of
    /// first mention.
    public var builtApps: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return apps.map { URL(fileURLWithPath: $0) }
    }

    /// The top-level `.app` bundles a task line names in a
    /// `<configuration>-iphonesimulator` products directory — the line that
    /// opens each task (`CodeSign <path>/App.app (in target …)`), not the
    /// indented commands under it. Whatever products root the build used —
    /// `-derivedDataPath`, or Xcode's own build location settings — the line
    /// shows it. A nested bundle (`App.app/PlugIns/Ext.appex`) names its app.
    public static func appBundles(inTaskLine line: String, configuration: String) -> [String] {
        guard let first = line.first, !first.isWhitespace else { return [] }
        let marker = "/\(configuration)-iphonesimulator/"
        var found: [String] = []
        var searchStart = line.startIndex
        while let range = line.range(of: marker, range: searchStart..<line.endIndex) {
            searchStart = range.upperBound
            // The bundle: the path component after the products directory.
            var end = range.upperBound
            while end < line.endIndex, !isPathEnd(in: line, at: end) { end = line.index(after: end) }
            let component = unescape(line[range.upperBound..<end])
            guard component.hasSuffix(".app"), component.count > 4 else { continue }
            // The path's start: back to the space or quote that opens it.
            var start = range.lowerBound
            while start > line.startIndex {
                let previous = line.index(before: start)
                if line[previous] == "\"" || line[previous] == "'" { break }
                if line[previous] == " ", previous == line.startIndex || line[line.index(before: previous)] != "\\" { break }
                start = previous
            }
            let path = unescape(line[start..<range.lowerBound]) + marker + component
            guard path.hasPrefix("/"), !found.contains(path) else { continue }
            found.append(path)
        }
        return found
    }

    /// A path component ends at a slash, a quote, or a space xcodebuild did
    /// not escape.
    private static func isPathEnd(in line: String, at index: String.Index) -> Bool {
        switch line[index] {
        case "/", "\"", "'":
            return true
        case " ":
            return index == line.startIndex || line[line.index(before: index)] != "\\"
        default:
            return false
        }
    }

    private static func unescape(_ text: Substring) -> String {
        text.replacingOccurrences(of: "\\ ", with: " ")
    }
}
