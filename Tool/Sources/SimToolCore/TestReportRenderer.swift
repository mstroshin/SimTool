import Foundation

/// Renders one recorded run into the Markdown report that sits next to it, at
/// `.simtool/test-sessions/<id>/report.md`.
///
/// The one artifact written for a person rather than a process: someone who has
/// no checkout, no simulator and no intention of reading `session.json` should
/// still be able to open this and see what was claimed, what happened, and what
/// to look at next. It is also what a sender attaches when handing the test on,
/// so it says what the receiver has to supply and what the run's evidence
/// carries.
public enum TestReportRenderer {
    /// - Parameters:
    ///   - session: the run, as it stands after being stopped — which is when
    ///     the video length and the final criteria are known.
    ///   - definition: the test, for the two things a session does not record:
    ///     its `description` and the variables it defines itself. Optional
    ///     because the file may be gone by the time a report is rendered.
    ///   - requiredVariables: `${VAR}` the test refers to without defining, so
    ///     the report names them as the receiver's to supply.
    public static func render(
        session: TestSession,
        definition: TestDefinition? = nil,
        requiredVariables: [String] = []
    ) -> String {
        var out = Markdown()
        let kind = session.kind ?? definition?.kind
        out.heading(1, definition?.name ?? session.title)

        if let verdict = session.verdict {
            out.paragraph("**\(verdict.headline(for: kind))** — `\(verdict.rawValue)`, exit code \(verdict.exitCode)")
        } else {
            out.paragraph("_This run makes no claim: the test declares no `kind:`, so it reports a plain \(session.status.rawValue)._")
        }
        if let description = definition?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            out.paragraph(description)
        }

        facts(&out, session: session, kind: kind)
        claim(&out, session: session, kind: kind)
        mocks(&out, session: session)
        timeline(&out, session: session)
        evidence(&out, session: session)
        rerun(&out, session: session, definition: definition, requiredVariables: requiredVariables)
        forwarding(&out, session: session, definition: definition)
        return out.text
    }

    // MARK: - sections

    private static func facts(_ out: inout Markdown, session: TestSession, kind: TestKind?) {
        var rows: [(String, String)] = []
        if let kind {
            rows.append(("Verifying", kind == .bug ? "a bug — the claim is what *should* happen" : "a feature — the claim is its acceptance"))
        }
        if let reference = session.reference, !reference.isEmpty { rows.append(("Reference", reference)) }
        let provenance = session.provenance
        if let app = provenance?.appBundleId {
            let build = InstalledAppBundle(path: URL(fileURLWithPath: "/"), version: provenance?.appVersion, build: provenance?.appBuild)
            rows.append(("App", [app, build.shortDescription].compactMap { $0 }.joined(separator: " ")))
        }
        if let commit = provenance?.commit, !commit.isEmpty {
            rows.append(("Commit", "`\(commit)`"))
        }
        let device = [provenance?.deviceName ?? session.deviceName, provenance?.runtime.map(prettyRuntime)]
            .compactMap { $0 }
            .joined(separator: " · ")
        if !device.isEmpty { rows.append(("Device", device)) }
        let tool = provenance?.simtoolVersion.map { " · simtool \($0)" } ?? ""
        rows.append(("Recorded", timestamp(session.startedAt) + tool))
        out.table(headers: ["", ""], rows: rows.map { [$0.0, $0.1] })
    }

    private static func claim(_ out: inout Markdown, session: TestSession, kind: TestKind?) {
        out.heading(2, "The claim")
        guard !session.criteria.isEmpty else {
            out.paragraph("This test declares no criteria, so it reports a plain pass or fail.")
            return
        }
        for criterion in session.criteria {
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
        switch kind {
        case .bug:
            out.paragraph("_Every step without a criterion only stages the scenario; a `bug` test stops at the first criterion that does not hold, because the reproduction is complete there._")
        case .feature:
            out.paragraph("_Every step without a criterion only stages the scenario; a `feature` test checks all of its criteria in one run, so this list is the full acceptance state._")
        case nil:
            break
        }
    }

    private static func mocks(_ out: inout Markdown, session: TestSession) {
        guard !session.mocks.isEmpty else { return }
        out.heading(2, "Mocked backend")
        out.table(
            headers: ["Method", "Answered", "Strict"],
            rows: session.mocks.map { mock in
                ["`\(mock.method)`", mock.hits == 1 ? "1 call" : "\(mock.hits) calls", mock.strict ? "yes" : "no"]
            }
        )
        if session.mocks.contains(where: { $0.strict }) {
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
            // Not `logs.jsonl`: that holds the app's own log lines, and these
            // notes — the accessibility dump at the failing step among them — are
            // not in it. Sending the reader there is sending them to a file that
            // does not contain what they were promised.
            let dump = session.evidence.first { $0.hasSuffix("-ax.txt") }
            let elsewhere = dump.map { "the screen at that step is in `\($0)`, and every note in `session.json`" }
                ?? "every note is in `session.json`"
            out.paragraph("_\(truncated) further note line\(truncated == 1 ? "" : "s") omitted here; \(elsewhere)._")
        } else {
            out.blank()
        }
    }

    private static func evidence(_ out: inout Markdown, session: TestSession) {
        var names = ["session.json"] + session.evidence
        if session.videoDurationSeconds != nil { names.append("video.mp4") }
        out.heading(2, "Evidence")
        out.paragraph("All of it in this report's own directory, `.simtool/test-sessions/\(session.id)/`:")
        out.table(
            headers: ["File", "What it holds"],
            rows: Set(names).sorted().map { ["`\($0)`", describe(file: $0, session: session)] }
        )
    }

    private static func rerun(
        _ out: inout Markdown,
        session: TestSession,
        definition: TestDefinition?,
        requiredVariables: [String]
    ) {
        out.heading(2, "Re-running this")
        var needs: [String] = []
        // The requirement is the release, not the build that happened to record
        // this: `0.9.0-dev or newer` sends the reader hunting a version no release
        // carries. Which build it was still matters, so it gets its own sentence
        // below.
        var localBuild: String?
        if let simtool = session.provenance?.simtoolVersion {
            let release = simtool.split(separator: "-").first.map(String.init) ?? simtool
            needs.append("`simtool` \(release) or newer")
            if release != simtool { localBuild = simtool }
        }
        if let app = session.provenance?.appBundleId {
            needs.append("`\(app)` installed on a booted simulator")
        }
        if !requiredVariables.isEmpty {
            needs.append("these variables exported: " + requiredVariables.map { "`\($0)`" }.joined(separator: ", "))
        }
        out.paragraph(needs.isEmpty ? "Needs `simtool` and a booted simulator." : "You need " + sentence(needs) + ".")
        // Its own sentence: folded into the list above as an aside, it ran into
        // whatever item came next and the paragraph stopped parsing as English.
        if session.provenance?.appBundleId != nil {
            out.paragraph("Use your own build of the app — a verdict says something about the code that produced it and nothing about anyone else's.")
        }
        if let localBuild {
            out.paragraph("(This run was recorded with a \(localBuild) build of simtool — one built from a source tree, not the release.)")
        }

        let defined = (definition?.variables ?? [:]).keys.sorted()
        if !defined.isEmpty {
            let names = defined.map { "`\($0)`" }.joined(separator: ", ")
            out.paragraph("The test defines \(names) itself, so \(defined.count == 1 ? "that value travels" : "those values travel") with the file and you need no setup for \(defined.count == 1 ? "it" : "them"). To run as something else, pass `--var NAME=value` — it overrides the test without editing it.")
        }

        var lines = requiredVariables.map { "export \($0)=…" }
        lines.append("simtool test run \(session.provenance?.testFile ?? "test.yml")")
        out.code(lines.joined(separator: "\n"), language: "sh")
        out.paragraph("The exit code is the verdict: `0` satisfied, `1` unsatisfied, `2` inconclusive (the run never reached the claim — fix the test, not the product), `3` infra (the run cannot be trusted). `simtool test run` starts a server itself when none is running.")
        if let commit = session.provenance?.commit, !commit.isEmpty {
            out.paragraph("This run exercised commit `\(commit)`. Re-running against different code is the point when verifying a fix — but a `satisfied` verdict only means something if you know which build produced it, so check the build you have installed against the one above.")
        }
    }

    private static func forwarding(_ out: inout Markdown, session: TestSession, definition: TestDefinition?) {
        var reasons: [String] = []
        let sensitive = Set(session.evidence).intersection(["logs.jsonl", "network.jsonl", "state.jsonl"]).sorted()
        if !sensitive.isEmpty {
            let one = sensitive.count == 1
            reasons.append("\(sensitive.map { "`\($0)`" }.joined(separator: " and ")) \(one ? "holds" : "hold") the real traffic and log output of the account the run used — identifiers, tokens, whatever the app printed. That is what makes \(one ? "it" : "them") worth reading, and what makes \(one ? "it" : "them") team-internal. The test file alone carries none of it.")
        }
        let defined = (definition?.variables ?? [:]).keys.sorted()
        if !defined.isEmpty {
            reasons.append("The test defines \(defined.map { "`\($0)`" }.joined(separator: ", ")) inline — the point being that it runs as-is, the cost being that the value goes wherever this file goes. Move \(defined.count == 1 ? "it" : "them") to the environment and refer to \(defined.count == 1 ? "it" : "them") as `${NAME}` if that is not wanted.")
        }
        guard !reasons.isEmpty else { return }
        out.heading(2, "Before you forward this")
        for reason in reasons { out.paragraph(reason) }
    }

    // MARK: - helpers

    private static let logLinesPerEntry = 12

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
