import Foundation

/// Builds a human-readable failure detail from a failed `xcodebuild` invocation.
///
/// `xcodebuild` writes the trailing `** BUILD FAILED **` summary to stderr, but
/// the actual cause — compiler diagnostics, run-script output such as a
/// `command not found`, linker errors — goes to stdout, interleaved with the
/// build log. Surfacing stderr alone (or stdout alone) hides the cause, so this
/// scans both streams for error-bearing lines and combines them with the
/// summary.
public enum XcodebuildFailure {
    public static func detail(stdout: String, stderr: String) -> String {
        detail(causes: errorLines(in: stdout) + errorLines(in: stderr), stderr: stderr, fallback: stdout)
    }

    /// Convenience overload for a `ProcessOutput` from a failed xcodebuild.
    public static func detail(from output: ProcessOutput) -> String {
        detail(stdout: output.stdoutString, stderr: output.stderrString)
    }

    /// The detail of a build whose stdout was scanned as it streamed rather
    /// than kept: its error lines (`isErrorLine`), and the end of it for when
    /// none were recognized.
    public static func detail(stdoutErrorLines: [String], stdoutTail: String, stderr: String) -> String {
        detail(causes: stdoutErrorLines + errorLines(in: stderr), stderr: stderr, fallback: stdoutTail)
    }

    /// Whether a line of xcodebuild output, trimmed, explains a failure.
    public static func isErrorLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let lowered = line.lowercased()
        // A compiler/tool diagnostic is "error:" at the start of the line
        // (`error: Build input file …`) or after a space (`clang: error:`,
        // `Foo.swift:10:5: error:`). Requiring the space avoids matching
        // `error:` inside Swift parameter labels like `isLoading:error:`.
        if lowered.hasPrefix("error:") || lowered.contains(" error:") { return true }
        return markers.contains { lowered.contains($0) }
    }

    private static func detail(causes: [String], stderr: String, fallback: String) -> String {
        let summary = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryLines = Set(
            summary.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        )

        // Cause lines come from both streams (compiler diagnostics usually land
        // on stdout, but be robust), minus anything already shown in the summary.
        var seen = Set<String>()
        var cause: [String] = []
        for line in causes {
            let key = line.trimmingCharacters(in: .whitespaces)
            guard !summaryLines.contains(key), seen.insert(key).inserted else { continue }
            cause.append(line)
        }

        guard !cause.isEmpty else {
            // Nothing recognizable: preserve the previous behavior.
            return summary.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : summary
        }

        let capped = cap(cause)
        var blocks = [capped.joined(separator: "\n")]
        if !summary.isEmpty { blocks.append(summary) }
        return blocks.joined(separator: "\n\n")
    }

    private static func errorLines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isErrorLine)
    }

    /// Substrings (compared case-insensitively) that mark a line as the cause of
    /// a build failure rather than routine progress.
    private static let markers: [String] = [
        "command not found",
        "fatal error",
        "no such file or directory",
        "linker command failed",
        "failed with a nonzero exit code",
        "failed with exit code",
    ]

    /// Keeps the message bounded: the cause is usually near the end of the log,
    /// so retain the last lines and cap the total character count.
    private static func cap(_ lines: [String], maxLines: Int = 30, maxCharacters: Int = 3_000) -> [String] {
        var kept = lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
        var truncated = lines.count > maxLines
        while kept.joined(separator: "\n").count > maxCharacters, kept.count > 1 {
            kept.removeFirst()
            truncated = true
        }
        return truncated ? ["…(truncated)…"] + kept : kept
    }
}
