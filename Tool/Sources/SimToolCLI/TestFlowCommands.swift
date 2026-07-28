import ArgumentParser
import Foundation
import Noora
import SimToolClient
import SimToolCore

// MARK: - export

extension TestCommand {
    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Package a test and a recorded run of it into one archive to hand on.",
            discussion: """
            Writes a `*.simflow.zip` holding the test, the verdict a run of it
            reached, a Markdown report for whoever opens it, and the evidence
            behind the verdict:

              manifest.json          the claim, the verdict, what the receiver must supply
              test.yml               the test as it ran, with ${VAR} left unexpanded
              report.md              the same, written for a person
              runs/<session>/        session.json, logs.jsonl, network.jsonl,
                                     mocks.json, screenshots, video.mp4

            What it deliberately does not carry: the values behind `${VAR}`
            (`requires.env` names them, so an account never travels with a test)
            and the app binary (`requires.app` names it — the receiver installs
            their own build, which is the point when verifying a fix).

            Evidence does carry the account's real traffic and log output. That
            is what makes it worth reading inside the team, and why
            `--no-evidence` exists for anywhere else.
            """
        )

        @Argument(help: "Path to the YAML test to package. Optional: a recorded run already carries a copy of its test.")
        var test: String?

        @Option(help: "Session id to package. Defaults to the newest finished run of the test, else the newest run.")
        var session: String?

        @Option(name: .shortAndLong, help: "Archive path. Defaults to <reference-or-name>.simflow.zip in the working directory.")
        var output: String?

        @Flag(help: "Leave the screen recording out — the video is usually all of the size.")
        var noVideo = false

        @Flag(help: "Leave the run's evidence out: logs and network events carry the account's real data.")
        var noEvidence = false

        @Flag(help: "Replace an existing archive at the output path.")
        var force = false

        @Option(help: "Path to .simtool/config.yml, whose .simtool directory holds the recorded sessions. Defaults to the one discovered from the working directory upward.")
        var config: String?

        @OptionGroup var common: CommonJSON

        struct Payload: Codable {
            var archive: String
            var bytes: Int
            var entries: [String]
            var manifest: TestFlowManifest
        }

        func run() async throws {
            let projectConfig = try ProjectConfigLoader.loadIfPresent(explicitPath: config)
            let root = SimToolDirectory.testSessionsDirectory(in: projectConfig?.simtoolDirectory ?? SimToolDirectory.resolve())
            let store = TestSessionStore(root: root)
            let recorded = store.list()
            guard !recorded.isEmpty else {
                throw SimToolError("No test sessions recorded under \(root.path). Run the test first: `simtool test run <file>`.")
            }
            let chosen = try Self.select(sessionId: session, test: test, from: recorded)

            var notes: [String] = []
            let yaml = try Self.testYAML(for: chosen, path: test)
            var definition: TestDefinition?
            do {
                definition = try TestDefinitionParser.parse(yaml)
            } catch {
                // The report and the evidence are still worth sending; only
                // re-running is lost, and the receiver has to be told that.
                let reason = (error as? SimToolError)?.message ?? error.localizedDescription
                notes.append("The packaged test does not parse with this simtool version, so `simtool test run` on this archive will fail: \(reason)")
            }

            let directory = store.directory(for: chosen.id)
            let packaged = Self.filesToPackage(
                session: chosen,
                directory: directory,
                includeEvidence: !noEvidence,
                includeVideo: !noVideo,
                notes: &notes
            )

            var provenance = chosen.provenance
            // test.yml carries it verbatim; two copies in one archive only
            // invite them to disagree.
            provenance?.testYAML = nil
            let manifest = TestFlowManifest(
                name: definition?.name ?? chosen.title,
                description: definition?.description,
                kind: chosen.kind,
                reference: chosen.reference,
                verdict: chosen.verdict,
                headline: chosen.verdict?.headline(for: chosen.kind),
                criteria: chosen.criteria,
                mocks: chosen.mocks,
                runs: [TestFlowManifest.Run(
                    session: chosen.id,
                    status: chosen.status,
                    verdict: chosen.verdict,
                    startedAt: chosen.startedAt,
                    files: packaged
                )],
                requires: TestFlowArchive.requirements(
                    testYAML: yaml,
                    launch: provenance?.launch,
                    app: provenance?.appBundleId ?? definition?.app
                ),
                provenance: provenance,
                notes: notes
            )

            let destination = try Self.destination(
                output: output,
                manifest: manifest,
                sessionId: chosen.id,
                force: force
            )
            let report = TestReportRenderer.render(
                manifest: manifest,
                sessions: [chosen],
                archiveName: destination.lastPathComponent
            )
            let result = try await TestFlowArchive.pack(
                TestFlowArchive.Contents(
                    manifest: manifest,
                    testYAML: yaml,
                    report: report,
                    runs: [TestFlowArchive.Contents.Run(id: chosen.id, directory: directory, files: packaged)]
                ),
                to: destination
            )

            if common.json {
                try printJSON(Payload(
                    archive: result.url.path,
                    bytes: result.byteCount,
                    entries: result.entries,
                    manifest: manifest
                ))
            } else {
                Self.printSummary(result: result, manifest: manifest, session: chosen, packaged: packaged)
            }
        }

        // MARK: choosing what to package

        /// Explicit id wins; otherwise the newest finished run, preferring one
        /// recorded from the named test file. A run still going is never
        /// packaged: its evidence is half-written and it has no verdict.
        static func select(sessionId: String?, test: String?, from sessions: [TestSession]) throws -> TestSession {
            if let sessionId {
                guard let match = sessions.first(where: { $0.id == sessionId }) else {
                    let known = sessions.prefix(5).map(\.id).joined(separator: ", ")
                    throw SimToolError("No recorded session \(sessionId).\(known.isEmpty ? "" : " Newest: \(known).")")
                }
                return match
            }
            var candidates = sessions
            if let test {
                let name = URL(fileURLWithPath: test).lastPathComponent
                candidates = sessions.filter { $0.provenance?.testFile == name }
                guard !candidates.isEmpty else {
                    let known = sessions.prefix(5).compactMap { $0.provenance?.testFile }
                    let hint = known.isEmpty ? "" : " Recorded runs are of: \(Set(known).sorted().joined(separator: ", "))."
                    throw SimToolError("No recorded run of \(name).\(hint) Run it first, or pass --session.")
                }
            }
            guard let finished = candidates.first(where: { $0.status != .running }) else {
                throw SimToolError("The newest matching run (\(candidates[0].id)) is still going. Wait for it to finish, or pass --session.")
            }
            return finished
        }

        static func testYAML(for session: TestSession, path: String?) throws -> String {
            if let recorded = session.provenance?.testYAML, !recorded.isEmpty { return recorded }
            if let path {
                let url = URL(fileURLWithPath: path)
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                    throw SimToolError("Cannot read \(url.path).")
                }
                return contents
            }
            throw SimToolError("Session \(session.id) did not record a copy of its test. Pass the YAML path: `simtool test export <test.yml> --session \(session.id)`.")
        }

        /// The files that actually travel, and a note for every one that does
        /// not: an archive whose report points at evidence it left behind is
        /// worse than one that says what is missing.
        static func filesToPackage(
            session: TestSession,
            directory: URL,
            includeEvidence: Bool,
            includeVideo: Bool,
            notes: inout [String]
        ) -> [String] {
            var files = ["session.json"]
            let evidence = session.evidence.filter {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            let vanished = Set(session.evidence).subtracting(evidence)
            if !vanished.isEmpty {
                notes.append("Missing from the session directory, so not packaged: \(vanished.sorted().joined(separator: ", ")).")
            }
            if includeEvidence {
                files += evidence
            } else if !evidence.isEmpty {
                notes.append("Evidence omitted (`--no-evidence`): \(evidence.sorted().joined(separator: ", ")). The verdict, the criteria and the timeline are all still here.")
            }
            let video = directory.appendingPathComponent("video.mp4")
            if FileManager.default.fileExists(atPath: video.path) {
                if includeVideo {
                    files.append("video.mp4")
                } else {
                    notes.append("Screen recording omitted (`--no-video`).")
                }
            } else if let error = session.videoError {
                notes.append("This run has no screen recording: \(error)")
            }
            return files
        }

        static func destination(
            output: String?,
            manifest: TestFlowManifest,
            sessionId: String,
            force: Bool
        ) throws -> URL {
            let url: URL
            if let output, !output.isEmpty {
                url = URL(fileURLWithPath: output)
            } else {
                url = URL(fileURLWithPath: TestFlowArchive.suggestedFileName(
                    reference: manifest.reference,
                    name: manifest.name,
                    sessionId: sessionId
                ))
            }
            if FileManager.default.fileExists(atPath: url.path), !force {
                throw SimToolError("\(url.path) already exists. Pass --force to replace it.")
            }
            return url
        }

        static func printSummary(
            result: TestFlowArchive.PackResult,
            manifest: TestFlowManifest,
            session: TestSession,
            packaged: [String]
        ) {
            var takeaways: [String] = []
            if let verdict = manifest.verdict {
                takeaways.append("\(verdict.headline(for: manifest.kind)) (`\(verdict.rawValue)`)")
            }
            takeaways.append("Run \(session.id): \(packaged.count) file\(packaged.count == 1 ? "" : "s"), report.md, test.yml")
            if !manifest.requires.env.isEmpty {
                takeaways.append("The receiver must export: \(manifest.requires.env.joined(separator: ", "))")
            }
            if let app = manifest.requires.app {
                takeaways.append("…and have \(app) installed")
            }
            if packaged.contains(where: { ["logs.jsonl", "network.jsonl", "state.jsonl"].contains($0) }) {
                takeaways.append("Contains the account's real traffic and logs — team-internal; re-export with --no-evidence for anywhere else")
            }
            takeaways += manifest.notes
            takeaways.append("Open it with `simtool test show \(result.url.lastPathComponent)`, re-run it with `simtool test run \(result.url.lastPathComponent)`")
            makeNoora().success(.alert(
                TerminalText("\(result.url.lastPathComponent) — \(formatBytes(result.byteCount))"),
                takeaways: takeaways.map { TerminalText("\($0)") }
            ))
        }
    }
}

// MARK: - show

extension TestCommand {
    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Read a packaged test archive: what it claims, what the run concluded, what it carries.",
            discussion: """
            Works with no server and no project — the receiving end of a handoff
            usually has neither. `--report` prints the packaged Markdown report,
            and `--import` copies the packaged runs into this project's
            `.simtool/test-sessions` so the web viewer can replay the video and
            the timeline.
            """
        )

        @Argument(help: "Path to a *.simflow.zip archive.")
        var archive: String

        @Flag(help: "Print the packaged report.md instead of the summary.")
        var report = false

        @Flag(name: .customLong("import"), help: "Copy the packaged runs into this project's test sessions, for the web viewer.")
        var importRuns = false

        @Option(help: "Path to .simtool/config.yml, whose .simtool directory receives imported runs.")
        var config: String?

        @OptionGroup var common: CommonJSON

        struct Payload: Codable {
            var archive: String
            var entries: [String]
            var manifest: TestFlowManifest
            var imported: [String]?
        }

        func run() async throws {
            let url = URL(fileURLWithPath: archive)
            let manifest = try await TestFlowArchive.manifest(in: url)

            if report {
                guard let data = try await TestFlowArchive.read(TestFlowArchive.reportName, in: url),
                      let text = String(data: data, encoding: .utf8)
                else {
                    throw SimToolError("\(url.lastPathComponent) carries no \(TestFlowArchive.reportName).")
                }
                print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
                return
            }

            let entries = try await TestFlowArchive.entries(in: url)
            var imported: [String]?
            if importRuns {
                imported = try await Self.importRuns(from: url, manifest: manifest, config: config)
            }

            if common.json {
                try printJSON(Payload(archive: url.path, entries: entries, manifest: manifest, imported: imported))
                return
            }
            Self.printSummary(url: url, manifest: manifest, entries: entries, imported: imported)
        }

        /// Copies `runs/<id>/` out of the archive and into this project's test
        /// sessions, where the viewer looks. Re-importing the same archive
        /// overwrites, so it stays idempotent.
        static func importRuns(from archive: URL, manifest: TestFlowManifest, config: String?) async throws -> [String] {
            let projectConfig = try ProjectConfigLoader.loadIfPresent(explicitPath: config)
            let root = SimToolDirectory.testSessionsDirectory(in: projectConfig?.simtoolDirectory ?? SimToolDirectory.resolve())
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("simtool-import-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let extracted = try await TestFlowArchive.unpack(
                archive,
                into: staging,
                only: TestFlowArchive.runsDirectoryName + "/"
            )
            guard !extracted.isEmpty else { return [] }
            try SimToolDirectory.ensureEnclosing(root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let runsRoot = staging.appendingPathComponent(TestFlowArchive.runsDirectoryName, isDirectory: true)
            var imported: [String] = []
            for id in manifest.runs.map(\.session) {
                let source = runsRoot.appendingPathComponent(id, isDirectory: true)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let target = root.appendingPathComponent(id, isDirectory: true)
                // A session id is the directory name, so an existing one is the
                // same run — a re-import. Say that it was replaced rather than
                // quietly overwriting.
                let existed = FileManager.default.fileExists(atPath: target.path)
                if existed { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: source, to: target)
                imported.append(existed ? "\(id) (replaced)" : id)
            }
            return imported
        }

        /// Plain lines rather than a success/failure box: reading an archive is
        /// not an outcome, and `unsatisfied` here is usually exactly the work
        /// someone wanted to receive.
        static func printSummary(url: URL, manifest: TestFlowManifest, entries: [String], imported: [String]?) {
            print(manifest.name ?? url.lastPathComponent)
            if let verdict = manifest.verdict {
                print("\(manifest.headline ?? verdict.headline(for: manifest.kind)) — \(verdict.rawValue) (exit \(verdict.exitCode))")
            } else {
                print("Never run — this archive carries the test only.")
            }
            print("")

            var rows: [(String, [String])] = []
            if let kind = manifest.kind { rows.append(("Verifying", ["a \(kind.rawValue)"])) }
            if let reference = manifest.reference, !reference.isEmpty { rows.append(("Reference", [reference])) }
            if let provenance = manifest.provenance {
                let build = InstalledAppBundle(path: URL(fileURLWithPath: "/"), version: provenance.appVersion, build: provenance.appBuild)
                var recorded = [
                    [provenance.appBundleId, build.shortDescription].compactMap { $0 }.joined(separator: " "),
                    provenance.commit.map { "commit \($0.prefix(10))" } ?? "",
                    [provenance.deviceName, provenance.runtime.map(TestReportRenderer.prettyRuntime)].compactMap { $0 }.joined(separator: " · "),
                ]
                recorded.removeAll { $0.isEmpty }
                if !recorded.isEmpty { rows.append(("Recorded", [recorded.joined(separator: " · ")])) }
            }
            if !manifest.criteria.isEmpty {
                rows.append(("Claim", manifest.criteria.map { criterion in
                    let mark = switch criterion.status {
                    case .met: "✓"
                    case .unmet: "✗"
                    case .unchecked: "–"
                    }
                    return "\(mark) \(criterion.label)" + (criterion.detail.map { ": \($0)" } ?? "")
                }))
            }
            if !manifest.mocks.isEmpty {
                rows.append(("Mocks", manifest.mocks.map { mock in
                    "\(mock.method) — \(mock.hits) call\(mock.hits == 1 ? "" : "s")\(mock.strict ? ", strict" : "")"
                }))
            }
            var needs: [String] = []
            if !manifest.requires.env.isEmpty { needs.append("export " + manifest.requires.env.joined(separator: ", ")) }
            if let app = manifest.requires.app { needs.append("\(app) installed") }
            if !needs.isEmpty { rows.append(("Needs", [needs.joined(separator: " · ")])) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            rows.append(("Carries", ["\(entries.count) files" + (size.map { ", \(formatBytes($0))" } ?? "")]))
            if !manifest.notes.isEmpty { rows.append(("Not here", manifest.notes)) }
            if let imported {
                rows.append(("Imported", [imported.isEmpty
                    ? "nothing — the archive carries no runs"
                    : imported.joined(separator: ", ") + " — open the viewer's Tests ▸ History"]))
            }

            let width = rows.map(\.0.count).max() ?? 0
            for (label, values) in rows {
                for (index, value) in values.enumerated() {
                    let shown = index == 0 ? label.padding(toLength: width, withPad: " ", startingAt: 0) : String(repeating: " ", count: width)
                    print("  \(shown)  \(value)")
                }
            }
            print("")
            print("  simtool test show \(url.lastPathComponent) --report   the report written for a person")
            print("  simtool test show \(url.lastPathComponent) --import   put the run in this project's viewer")
            print("  simtool test run \(url.lastPathComponent)             run it here")
        }
    }
}

// MARK: - running what arrived

/// A test resolved from whatever the caller pointed at: a YAML file, or an
/// archive someone handed over.
struct PreparedTest {
    var definition: TestDefinition
    /// The file the run reads and records in provenance. For an archive this is
    /// an extraction under a temporary directory, named as the sender named it.
    var file: URL
    var manifest: TestFlowManifest?
    /// Launch profiles the archive supplies because the receiver's config does
    /// not have them.
    var extraProfiles: [LaunchProfile]
    /// Lines worth telling the operator before the run starts.
    var notes: [String]
}

enum TestSourceLoader {
    static func load(path: String, config: ProjectConfig?) async throws -> PreparedTest {
        let url = URL(fileURLWithPath: path)
        guard TestFlowArchive.isArchive(url) else {
            return PreparedTest(
                definition: try TestDefinitionParser.load(contentsOf: url),
                file: url,
                manifest: nil,
                extraProfiles: [],
                notes: []
            )
        }
        return try await loadArchive(url, config: config)
    }

    private static func loadArchive(_ url: URL, config: ProjectConfig?) async throws -> PreparedTest {
        let manifest = try await TestFlowArchive.manifest(in: url)
        guard let data = try await TestFlowArchive.read(TestFlowArchive.testName, in: url),
              let yaml = String(data: data, encoding: .utf8)
        else {
            throw SimToolError("\(url.lastPathComponent) carries no \(TestFlowArchive.testName), so there is nothing to run. `simtool test show \(url.lastPathComponent)` reads what it does carry.")
        }

        var notes: [String] = []
        // Before anything touches the simulator: a missing variable fails the
        // launch minutes later with a much worse message.
        let missing = manifest.requires.env.filter { (ProcessInfo.processInfo.environment[$0] ?? "").isEmpty }
        if !missing.isEmpty {
            let one = missing.count == 1
            throw SimToolError("""
                \(url.lastPathComponent) needs \(one ? "a variable" : "variables") this shell does not have: \(missing.joined(separator: ", ")). \
                The archive names \(one ? "it" : "them") but never carries \(one ? "its value" : "their values") — \
                \(one ? "it is" : "they are") the account it ran as. Export \(one ? "it" : "them") and run again.
                """)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep the sender's file name: it lands in this run's provenance, and
        // "test.yml" would lose which test this was.
        let name = manifest.provenance?.testFile ?? TestFlowArchive.testName
        let file = directory.appendingPathComponent(name.isEmpty ? TestFlowArchive.testName : name)
        try Data(yaml.utf8).write(to: file)

        let definition: TestDefinition
        do {
            definition = try TestDefinitionParser.parse(yaml)
        } catch {
            let reason = (error as? SimToolError)?.message ?? error.localizedDescription
            throw SimToolError("The test packaged in \(url.lastPathComponent) does not parse: \(reason)" + (manifest.requires.simtool.map { " It was written by simtool \($0); this is \(SimToolVersion.current)." } ?? ""))
        }

        var extraProfiles: [LaunchProfile] = []
        if let profileName = definition.launch.profile,
           !profileName.isEmpty,
           !(config?.profiles.contains { $0.name == profileName } ?? false) {
            if let recorded = manifest.provenance?.launch {
                extraProfiles.append(rebuiltProfile(named: profileName, from: recorded, test: definition))
                notes.append("Launch profile `\(profileName)` is not in this project's config; using the launch the archive recorded.")
            } else {
                notes.append("Launch profile `\(profileName)` is not in this project's config and the archive recorded no launch to fall back on.")
            }
        }
        return PreparedTest(
            definition: definition,
            file: file,
            manifest: manifest,
            extraProfiles: extraProfiles,
            notes: notes
        )
    }

    /// Rebuilds the missing profile out of the recorded launch. The recorded
    /// arguments are `reset` arguments, then the profile's, then the test's
    /// inline ones — so the profile's own share is what is left after stripping
    /// the two ends this test contributes.
    private static func rebuiltProfile(named name: String, from recorded: ResolvedLaunch, test: TestDefinition) -> LaunchProfile {
        var arguments = recorded.arguments
        let prefix = test.reset.launchArguments
        if !prefix.isEmpty, Array(arguments.prefix(prefix.count)) == prefix {
            arguments.removeFirst(prefix.count)
        }
        let suffix = test.launch.arguments
        if !suffix.isEmpty, Array(arguments.suffix(suffix.count)) == suffix {
            arguments.removeLast(suffix.count)
        }
        // Environment and deeplink need no such surgery: the test's inline
        // values override the profile's per key when the launch is resolved.
        return LaunchProfile(
            name: name,
            arguments: arguments,
            environment: recorded.environment,
            deeplink: recorded.deeplink
        )
    }
}

/// Compares the build a packaged run recorded against the one installed now.
/// A repro re-run against different code and pronounced fixed is the failure
/// this exists to prevent.
enum BuildDrift {
    static func lines(manifest: TestFlowManifest, installed: InstalledAppBundle?, app: String?) -> [String] {
        let recorded = InstalledAppBundle(
            path: URL(fileURLWithPath: "/"),
            version: manifest.provenance?.appVersion,
            build: manifest.provenance?.appBuild
        )
        guard let app else { return [] }
        guard let installed else {
            return ["\(app) is not installed on this simulator, or its bundle cannot be read. Install the build you want to verify before running."]
        }
        guard let recordedText = recorded.shortDescription else { return [] }
        guard let installedText = installed.shortDescription else { return [] }
        if recorded.build == installed.build, recorded.version == installed.version {
            return ["Same build as the packaged run: \(installedText)."]
        }
        return ["The packaged run exercised \(recordedText); this simulator has \(installedText). That is expected when verifying a fix, and misleading when reproducing."]
    }
}

/// One line the operator should see but a script should not have to parse.
func emitNote(_ text: String, json: Bool) {
    if json {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    } else {
        makeNoora().info("\(text)")
    }
}

func formatBytes(_ count: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: Int64(count))
}
