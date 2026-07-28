import Foundation

/// Renders a run into the Markdown report that travels with it.
///
/// The one artifact written for a person rather than a process: someone who has
/// no checkout, no simulator and no intention of reading `session.json` should
/// still be able to open this and see what was claimed, what happened, and what
/// to look at next.
public enum TestReportRenderer {
    /// - Parameters:
    ///   - manifest: the claim and the verdict.
    ///   - sessions: packaged runs, in the order they should be read.
    ///   - archiveName: the archive's file name, for the re-run instructions.
    ///   - includedFiles: per session id, the file names that actually travel —
    ///     a report must not point at evidence the export left behind.
    public static func render(
        manifest: TestFlowManifest,
        sessions: [TestSession],
        archiveName: String? = nil,
        includedFiles: [String: [String]] = [:]
    ) -> String {
        var out = Markdown()
        let kind = manifest.kind
        out.heading(1, manifest.name ?? "Verifying test")

        if let verdict = manifest.verdict {
            out.paragraph("**\(manifest.headline ?? verdict.headline(for: kind))** — `\(verdict.rawValue)`, exit code \(verdict.exitCode)")
        } else {
            out.paragraph("_This archive carries a test that has not been run._")
        }
        if let description = manifest.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            out.paragraph(description)
        }

        facts(&out, manifest: manifest, sessions: sessions)
        claim(&out, manifest: manifest)
        mocks(&out, manifest: manifest)
        for session in sessions {
            timeline(&out, session: session)
        }
        evidence(&out, manifest: manifest, sessions: sessions, includedFiles: includedFiles)
        rerun(&out, manifest: manifest, archiveName: archiveName)
        forwarding(&out, manifest: manifest, includedFiles: includedFiles)
        return out.text
    }

    // MARK: - sections

    private static func facts(_ out: inout Markdown, manifest: TestFlowManifest, sessions: [TestSession]) {
        var rows: [(String, String)] = []
        if let kind = manifest.kind {
            rows.append(("Verifying", kind == .bug ? "a bug — the claim is what *should* happen" : "a feature — the claim is its acceptance"))
        }
        if let reference = manifest.reference, !reference.isEmpty { rows.append(("Reference", reference)) }
        let provenance = manifest.provenance
        if let app = provenance?.appBundleId {
            let build = InstalledAppBundle(path: URL(fileURLWithPath: "/"), version: provenance?.appVersion, build: provenance?.appBuild)
            rows.append(("App", [app, build.shortDescription].compactMap { $0 }.joined(separator: " ")))
        }
        if let commit = provenance?.commit, !commit.isEmpty {
            rows.append(("Commit", "`\(commit)`"))
        }
        let device = [provenance?.deviceName, provenance?.runtime.map(prettyRuntime)].compactMap { $0 }.joined(separator: " · ")
        if !device.isEmpty { rows.append(("Device", device)) }
        if let session = sessions.first {
            let recorded = timestamp(session.startedAt)
            let tool = provenance?.simtoolVersion.map { " · simtool \($0)" } ?? ""
            rows.append(("Recorded", recorded + tool))
        }
        rows.append(("Packaged", timestamp(manifest.exportedAt) + (manifest.requires.simtool.map { " · simtool \($0)" } ?? "")))
        guard !rows.isEmpty else { return }
        out.table(headers: ["", ""], rows: rows.map { [$0.0, $0.1] })
    }

    private static func claim(_ out: inout Markdown, manifest: TestFlowManifest) {
        guard !manifest.criteria.isEmpty else {
            out.heading(2, "The claim")
            out.paragraph("This test declares no criteria, so it reports a plain pass or fail.")
            return
        }
        out.heading(2, "The claim")
        for criterion in manifest.criteria {
            let mark = switch criterion.status {
            case .met: "✓"
            case .unmet: "✗"
            case .unchecked: "–"
            }
            var line = "\(mark) **\(criterion.label)**"
            if let step = criterion.step { line += " — step \(step)" }
            if let detail = criterion.detail, !detail.isEmpty {
                line += (criterion.step == nil ? " — " : ": ") + detail
            }
            if criterion.status == .unchecked { line += " — the run never got this far" }
            out.bullet(line)
        }
        out.blank()
        switch manifest.kind {
        case .bug:
            out.paragraph("_Every step without a criterion only stages the scenario; a `bug` test stops at the first criterion that does not hold, because the reproduction is complete there._")
        case .feature:
            out.paragraph("_Every step without a criterion only stages the scenario; a `feature` test checks all of its criteria in one run, so this list is the full acceptance state._")
        case nil:
            break
        }
    }

    private static func mocks(_ out: inout Markdown, manifest: TestFlowManifest) {
        guard !manifest.mocks.isEmpty else { return }
        out.heading(2, "Mocked backend")
        out.table(
            headers: ["Method", "Answered", "Strict"],
            rows: manifest.mocks.map { mock in
                ["`\(mock.method)`", mock.hits == 1 ? "1 call" : "\(mock.hits) calls", mock.strict ? "yes" : "no"]
            }
        )
        if manifest.mocks.contains(where: { $0.strict }) {
            out.paragraph("_A strict rule that answers nothing makes the run `infra` rather than a result: the test would have been measuring the real backend._")
        }
    }

    private static func timeline(_ out: inout Markdown, session: TestSession) {
        out.heading(2, "Timeline — \(session.id)")
        var facts: [String] = []
        if let verdict = session.verdict { facts.append("`\(verdict.rawValue)`") }
        else { facts.append("`\(session.status.rawValue)`") }
        if let duration = duration(of: session) { facts.append("video \(mmss(duration))") }
        if let error = session.videoError { facts.append("no video: \(error)") }
        out.paragraph(facts.joined(separator: " · "))

        let scale = videoScale(of: session)
        var truncated = 0
        for entry in session.entries {
            switch entry.kind {
            case .step:
                guard let text = entry.text, !text.isEmpty else { continue }
                var line = "`\(mmss(offset(of: entry, in: session, scale: scale)))` \(escapePipes(text))"
                // A step's own description already names the criterion it
                // checks; only say it again when it does not.
                if let criterion = entry.criterion, !text.contains(criterion) {
                    line += " — criterion: **\(criterion)**"
                }
                out.bullet(line)
            case .log:
                let logs = entry.logs ?? []
                for log in logs.prefix(logLinesPerEntry) {
                    out.bullet(escapePipes(log), indent: 1)
                }
                truncated += max(0, logs.count - logLinesPerEntry)
            }
        }
        if truncated > 0 {
            out.blank()
            out.paragraph("_\(truncated) further note line\(truncated == 1 ? "" : "s") omitted here; the full capture is in the run's `logs.jsonl`._")
        } else {
            out.blank()
        }
    }

    private static func evidence(
        _ out: inout Markdown,
        manifest: TestFlowManifest,
        sessions: [TestSession],
        includedFiles: [String: [String]]
    ) {
        let runs = manifest.runs.filter { !files(for: $0, includedFiles: includedFiles).isEmpty }
        guard !runs.isEmpty else { return }
        out.heading(2, "Evidence")
        for run in runs {
            let names = files(for: run, includedFiles: includedFiles)
            out.paragraph("`\(TestFlowArchive.runsDirectoryName)/\(run.session)/`")
            let session = sessions.first { $0.id == run.session }
            out.table(
                headers: ["File", "What it holds"],
                rows: names.sorted().map { ["`\($0)`", describe(file: $0, session: session)] }
            )
        }
    }

    private static func rerun(_ out: inout Markdown, manifest: TestFlowManifest, archiveName: String?) {
        out.heading(2, "Re-running this")
        var needs: [String] = []
        if let simtool = manifest.requires.simtool { needs.append("`simtool` \(simtool) or newer") }
        if let app = manifest.requires.app { needs.append("`\(app)` installed on a booted simulator") }
        if !manifest.requires.env.isEmpty {
            needs.append("these variables exported: " + manifest.requires.env.map { "`\($0)`" }.joined(separator: ", "))
        }
        if needs.isEmpty {
            out.paragraph("Needs `simtool` and a booted simulator.")
        } else {
            out.paragraph("You need " + sentence(needs) + ".")
        }
        var lines: [String] = []
        for name in manifest.requires.env {
            lines.append("export \(name)=…")
        }
        lines.append("simtool serve --detach")
        lines.append("simtool test run \(archiveName ?? "flow.simflow.zip")")
        out.code(lines.joined(separator: "\n"), language: "sh")
        out.paragraph("The exit code is the verdict: `0` satisfied, `1` unsatisfied, `2` inconclusive (the run never reached the claim — fix the test, not the product), `3` infra (the run cannot be trusted).")
        if let profile = manifest.provenance?.launch?.profile {
            out.paragraph("The launch profile `\(profile)` does not have to exist in your `.simtool/config.yml`: the archive carries the launch this run used, and `test run` falls back to it when the profile is missing.")
        }
        if let commit = manifest.provenance?.commit, !commit.isEmpty {
            out.paragraph("This run exercised commit `\(commit)`. Re-running against different code is the point when verifying a fix — but a `satisfied` verdict only means something if you know which build produced it, so `test run` prints the installed build alongside the one recorded here.")
        }
    }

    private static func forwarding(_ out: inout Markdown, manifest: TestFlowManifest, includedFiles: [String: [String]]) {
        let packaged = Set(manifest.runs.flatMap { files(for: $0, includedFiles: includedFiles) })
        let sensitive = packaged.intersection(["logs.jsonl", "network.jsonl", "state.jsonl"])
        guard !sensitive.isEmpty else {
            if !manifest.notes.isEmpty {
                out.heading(2, "What is not here")
                for note in manifest.notes { out.bullet(note) }
                out.blank()
            }
            return
        }
        out.heading(2, "Before you forward this")
        out.paragraph("\(sensitive.sorted().map { "`\($0)`" }.joined(separator: " and ")) hold the real traffic and log output of the account the run used — identifiers, tokens, whatever the app printed. That is what makes them worth reading, and what makes this archive team-internal. Re-export with `--no-evidence` for anywhere else.")
        if !manifest.notes.isEmpty {
            out.heading(2, "What is not here")
            for note in manifest.notes { out.bullet(note) }
            out.blank()
        }
    }

    // MARK: - helpers

    private static let logLinesPerEntry = 12

    private static func files(for run: TestFlowManifest.Run, includedFiles: [String: [String]]) -> [String] {
        includedFiles[run.session] ?? run.files
    }

    private static func describe(file: String, session: TestSession?) -> String {
        switch file {
        case "session.json":
            return "the run itself: timeline, criteria, verdict and provenance"
        case "logs.jsonl":
            return "every log line the app emitted during the run, one JSON object per line"
        case "network.jsonl":
            return "every HTTP and gRPC call the app reported, with `mocked` and `mockRuleId` marking the ones a rule answered"
        case "state.jsonl":
            return "state changes the app reported through `@SimToolDebugState`"
        case "mocks.json":
            return "each declared rule and how many calls it answered"
        case "video.mp4":
            let length = session.flatMap(duration(of:)).map { " (\(mmss($0)))" } ?? ""
            return "screen recording of the run\(length); the timeline above is in video time"
        default:
            if file.hasSuffix("-ax.txt") {
                return "what was on screen at that step, read from the accessibility tree"
            }
            if file.hasPrefix("failure-step-") {
                return "screenshot at the step that failed"
            }
            if file.hasPrefix("step-") {
                return "screenshot after that step (`--evidence full`)"
            }
            return "collected by the run"
        }
    }

    /// Mirrors the viewer: wall-clock spans scaled onto the real video length,
    /// because simctl's footage runs shorter than the wall clock and an
    /// unscaled offset drifts past the end.
    private static func videoScale(of session: TestSession) -> Double? {
        guard let video = session.videoDurationSeconds, video > 0, let ended = session.endedAt else { return nil }
        let span = ended.timeIntervalSince(session.recordingStartedAt ?? session.startedAt)
        guard span > 0 else { return nil }
        return video / span
    }

    private static func offset(of entry: TestSessionEntry, in session: TestSession, scale: Double?) -> Double {
        let raw = max(0, entry.at.timeIntervalSince(session.recordingStartedAt ?? session.startedAt))
        guard let scale, let video = session.videoDurationSeconds else { return raw }
        return min(video, raw * scale)
    }

    private static func duration(of session: TestSession) -> Double? {
        if let video = session.videoDurationSeconds, video > 0 { return video }
        guard let ended = session.endedAt else { return nil }
        let span = ended.timeIntervalSince(session.recordingStartedAt ?? session.startedAt)
        return span > 0 ? span : nil
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4` is what simctl reports and
    /// nothing a reader wants to see. Left alone when it is already readable.
    public static func prettyRuntime(_ runtime: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard runtime.hasPrefix(prefix) else { return runtime }
        let short = String(runtime.dropFirst(prefix.count))
        guard let separator = short.firstIndex(of: "-") else { return short }
        let platform = String(short[short.startIndex..<separator])
        let version = short[short.index(after: separator)...].replacingOccurrences(of: "-", with: ".")
        return version.isEmpty ? platform : "\(platform) \(version)"
    }

    private static func mmss(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date) + " UTC"
    }

    private static func sentence(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// A step description can contain `|` (a typed string, a label), which would
    /// otherwise break out of a table cell or a bullet's emphasis.
    private static func escapePipes(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}

/// A small Markdown builder. Enough for one document shape, and it keeps the
/// renderer readable — string concatenation across twenty sections is where
/// stray blank lines and broken tables come from.
private struct Markdown {
    private(set) var text = ""

    mutating func heading(_ level: Int, _ title: String) {
        ensureBlankLine()
        text += String(repeating: "#", count: level) + " " + title + "\n\n"
    }

    mutating func paragraph(_ body: String) {
        ensureBlankLine()
        text += body + "\n\n"
    }

    mutating func bullet(_ body: String, indent: Int = 0) {
        text += String(repeating: "  ", count: indent) + "- " + body + "\n"
    }

    mutating func table(headers: [String], rows: [[String]]) {
        ensureBlankLine()
        text += "| " + headers.joined(separator: " | ") + " |\n"
        text += "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |\n"
        for row in rows {
            text += "| " + row.joined(separator: " | ") + " |\n"
        }
        text += "\n"
    }

    mutating func code(_ body: String, language: String = "") {
        ensureBlankLine()
        text += "```\(language)\n" + body + "\n```\n\n"
    }

    mutating func blank() {
        ensureBlankLine()
    }

    private mutating func ensureBlankLine() {
        guard !text.isEmpty else { return }
        if text.hasSuffix("\n\n") { return }
        text += text.hasSuffix("\n") ? "\n" : "\n\n"
    }
}
