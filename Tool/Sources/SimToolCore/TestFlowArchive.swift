import Foundation

/// What travels with a packaged test: the claim, the verdict a run of it
/// reached, and what the receiver has to supply to reach it again.
///
/// Deliberately not a copy of everything: the values behind `${VAR}` stay in
/// the sender's shell (`requires.env` names them), and the app binary stays
/// out (`requires.app` names it). An archive is a test plus its proof, not a
/// portable machine.
public struct TestFlowManifest: Codable, Equatable, Sendable {
    /// Bumped when the layout changes so that an older `simtool` could not read
    /// it. A reader refuses a higher schema rather than guessing.
    public static let currentSchema = 1

    /// Everything the receiver must already have. Named, never carried.
    public struct Requires: Codable, Equatable, Sendable {
        /// `${VAR}` names the test, its launch profile or its setup refer to and
        /// does *not* define itself. Names only, never values — the receiver
        /// supplies these.
        public var env: [String]
        /// Bundle id that has to be installed on the simulator.
        public var app: String?
        /// The `simtool` version that wrote the archive.
        public var simtool: String?
        /// Variables the packaged `test.yml` defines itself, so the receiver
        /// needs no setup for them — and so a reader knows this archive carries
        /// those values (an account, a seed) rather than only naming them.
        public var carries: [String]

        public init(env: [String] = [], app: String? = nil, simtool: String? = nil, carries: [String] = []) {
            self.env = env
            self.app = app
            self.simtool = simtool
            self.carries = carries
        }

        /// Tolerates archives written before `carries` existed.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            env = try container.decodeIfPresent([String].self, forKey: .env) ?? []
            app = try container.decodeIfPresent(String.self, forKey: .app)
            simtool = try container.decodeIfPresent(String.self, forKey: .simtool)
            carries = try container.decodeIfPresent([String].self, forKey: .carries) ?? []
        }
    }

    /// One packaged run, under `runs/<session>/`.
    public struct Run: Codable, Equatable, Sendable {
        public var session: String
        public var status: TestSessionStatus
        public var verdict: TestVerdict?
        public var startedAt: Date
        /// File names packaged from the session directory.
        public var files: [String]

        public init(
            session: String,
            status: TestSessionStatus,
            verdict: TestVerdict? = nil,
            startedAt: Date,
            files: [String] = []
        ) {
            self.session = session
            self.status = status
            self.verdict = verdict
            self.startedAt = startedAt
            self.files = files
        }
    }

    public var schema: Int
    public var exportedAt: Date
    public var name: String?
    public var description: String?
    public var kind: TestKind?
    /// Free-form origin of the work, copied from the test. Never interpreted.
    public var reference: String?
    public var verdict: TestVerdict?
    public var headline: String?
    public var criteria: [TestCriterionResult]
    public var mocks: [TestMockOutcome]
    public var runs: [Run]
    public var requires: Requires
    /// Where the packaged run came from. Carries the recorded launch with
    /// `${VAR}` unexpanded, which is what lets a receiver run the test even
    /// without the launch profile it names.
    public var provenance: TestRunProvenance?
    /// What the export left out, so a reader never reads an omission as an
    /// absence of evidence.
    public var notes: [String]

    public init(
        schema: Int = TestFlowManifest.currentSchema,
        exportedAt: Date = Date(),
        name: String? = nil,
        description: String? = nil,
        kind: TestKind? = nil,
        reference: String? = nil,
        verdict: TestVerdict? = nil,
        headline: String? = nil,
        criteria: [TestCriterionResult] = [],
        mocks: [TestMockOutcome] = [],
        runs: [Run] = [],
        requires: Requires = Requires(),
        provenance: TestRunProvenance? = nil,
        notes: [String] = []
    ) {
        self.schema = schema
        self.exportedAt = exportedAt
        self.name = name
        self.description = description
        self.kind = kind
        self.reference = reference
        self.verdict = verdict
        self.headline = headline
        self.criteria = criteria
        self.mocks = mocks
        self.runs = runs
        self.requires = requires
        self.provenance = provenance
        self.notes = notes
    }

    /// Tolerates archives written before a field existed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? TestFlowManifest.currentSchema
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        kind = try container.decodeIfPresent(TestKind.self, forKey: .kind)
        reference = try container.decodeIfPresent(String.self, forKey: .reference)
        verdict = try container.decodeIfPresent(TestVerdict.self, forKey: .verdict)
        headline = try container.decodeIfPresent(String.self, forKey: .headline)
        criteria = try container.decodeIfPresent([TestCriterionResult].self, forKey: .criteria) ?? []
        mocks = try container.decodeIfPresent([TestMockOutcome].self, forKey: .mocks) ?? []
        runs = try container.decodeIfPresent([Run].self, forKey: .runs) ?? []
        requires = try container.decodeIfPresent(Requires.self, forKey: .requires) ?? Requires()
        provenance = try container.decodeIfPresent(TestRunProvenance.self, forKey: .provenance)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

/// Reads and writes `*.simflow.zip`: one file that carries a verifying test,
/// the verdict a run of it reached, and the evidence behind that verdict.
///
/// A plain zip on purpose. Whoever receives it may not have `simtool` at hand,
/// and a format they can double-click beats one only this tool can open.
public enum TestFlowArchive {
    public static let manifestName = "manifest.json"
    /// Always this name inside the archive; the original file name survives in
    /// `provenance.testFile`, and `test run` restores it.
    public static let testName = "test.yml"
    public static let reportName = "report.md"
    public static let runsDirectoryName = "runs"
    /// Double extension: the first half says what it is, the second half says
    /// any unzip tool can open it.
    public static let pathExtension = "simflow.zip"

    private static let zipTool = URL(fileURLWithPath: "/usr/bin/zip")
    private static let unzipTool = URL(fileURLWithPath: "/usr/bin/unzip")

    /// Whether `url` looks like an archive rather than a YAML test. Extension
    /// only: the file may not exist yet (`test export -o`), and a wrong guess
    /// surfaces immediately as "no manifest.json" rather than silently.
    public static func isArchive(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".zip")
    }

    /// What to pack. The caller decides which files travel — evidence carries
    /// real account data and video makes an archive large, so both are choices
    /// rather than defaults buried in here.
    public struct Contents: Sendable {
        public struct Run: Sendable {
            public var id: String
            public var directory: URL
            /// File names to copy out of `directory`. Missing ones are skipped.
            public var files: [String]

            public init(id: String, directory: URL, files: [String]) {
                self.id = id
                self.directory = directory
                self.files = files
            }
        }

        public var manifest: TestFlowManifest
        public var testYAML: String
        public var report: String
        public var runs: [Run]

        public init(manifest: TestFlowManifest, testYAML: String, report: String, runs: [Run] = []) {
            self.manifest = manifest
            self.testYAML = testYAML
            self.report = report
            self.runs = runs
        }
    }

    public struct PackResult: Sendable, Equatable {
        public var url: URL
        public var byteCount: Int
        /// Entry names inside the archive, as an unzip tool lists them.
        public var entries: [String]

        public init(url: URL, byteCount: Int, entries: [String]) {
            self.url = url
            self.byteCount = byteCount
            self.entries = entries
        }
    }

    /// Writes `contents` to `destination`, replacing it. Replacing rather than
    /// updating is deliberate: `zip` appends to an existing archive, which
    /// would quietly merge a previous export into this one.
    public static func pack(_ contents: Contents, to destination: URL) async throws -> PackResult {
        guard FileManager.default.isExecutableFile(atPath: zipTool.path) else {
            throw SimToolError("`/usr/bin/zip` is missing, so archives cannot be written on this machine.")
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try JSON.data(contents.manifest).write(to: staging.appendingPathComponent(manifestName))
        try Data(contents.testYAML.utf8).write(to: staging.appendingPathComponent(testName))
        try Data(contents.report.utf8).write(to: staging.appendingPathComponent(reportName))
        var topLevel = [manifestName, testName, reportName]

        let packagedRuns = contents.runs.filter { !$0.files.isEmpty }
        if !packagedRuns.isEmpty {
            let runsRoot = staging.appendingPathComponent(runsDirectoryName, isDirectory: true)
            for run in packagedRuns {
                let target = runsRoot.appendingPathComponent(run.id, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for file in run.files {
                    let source = run.directory.appendingPathComponent(file)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    try FileManager.default.copyItem(at: source, to: target.appendingPathComponent(file))
                }
            }
            topLevel.append(runsDirectoryName)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // -X drops the extra macOS attributes; the archive should differ between
        // two exports only where its contents differ.
        let output = try await ProcessRunner.run(
            executable: zipTool,
            arguments: ["-r", "-X", "-q", destination.path] + topLevel,
            currentDirectory: staging,
            timeoutSeconds: 600
        )
        guard output.status == 0 else {
            throw SimToolError("Packing \(destination.lastPathComponent) failed (zip exited \(output.status)): \(trimmed(output.stderrString))")
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        return PackResult(url: destination, byteCount: size ?? 0, entries: try await entries(in: destination))
    }

    /// File names inside `archive`, in the order the archive stores them. The
    /// directory entries zip also records are left out: every caller here means
    /// "what does it carry".
    public static func entries(in archive: URL) async throws -> [String] {
        try await rawEntries(in: archive).filter { !$0.hasSuffix("/") }
    }

    private static func rawEntries(in archive: URL) async throws -> [String] {
        let output = try await runUnzip(["-Z1", archive.path], archive: archive)
        return output.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// One entry's bytes, without extracting the rest. Nil when the archive has
    /// no such entry.
    public static func read(_ name: String, in archive: URL) async throws -> Data? {
        guard FileManager.default.isExecutableFile(atPath: unzipTool.path) else {
            throw SimToolError("`/usr/bin/unzip` is missing, so archives cannot be read on this machine.")
        }
        let output = try await ProcessRunner.run(
            executable: unzipTool,
            arguments: ["-p", archive.path, name],
            timeoutSeconds: 120
        )
        // 11 is unzip's "no matching files", which is a missing entry rather
        // than a broken archive.
        if output.status == 11 { return nil }
        // 9 is "not a zip file", worth saying plainly: the usual cause is a
        // path that points at the YAML test rather than at an archive.
        if output.status == 9 {
            throw SimToolError("\(archive.lastPathComponent) is not a zip archive.")
        }
        guard output.status == 0 else {
            throw SimToolError("Cannot read \(name) from \(archive.lastPathComponent) (unzip exited \(output.status)): \(trimmed(output.stderrString))")
        }
        return output.stdout.isEmpty ? nil : output.stdout
    }

    /// The archive's manifest, with the checks that decide whether this build
    /// can be trusted to read the rest of it.
    public static func manifest(in archive: URL) async throws -> TestFlowManifest {
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw SimToolError("No such archive: \(archive.path)")
        }
        guard let data = try await read(manifestName, in: archive) else {
            throw SimToolError("\(archive.lastPathComponent) is not a SimTool flow archive: it has no \(manifestName). Package one with `simtool test export`.")
        }
        let manifest: TestFlowManifest
        do {
            manifest = try JSON.decoder.decode(TestFlowManifest.self, from: data)
        } catch {
            throw SimToolError("\(archive.lastPathComponent) has an unreadable \(manifestName): \(error.localizedDescription)")
        }
        guard manifest.schema <= TestFlowManifest.currentSchema else {
            throw SimToolError("\(archive.lastPathComponent) was written by a newer simtool (archive schema \(manifest.schema), this build reads \(TestFlowManifest.currentSchema)). Update simtool.")
        }
        return manifest
    }

    /// Extracts `archive` into `directory`, overwriting what is already there.
    /// Entries that would escape `directory` abort the extraction: the file
    /// arrived from somewhere else, so its entry names are not trusted.
    @discardableResult
    public static func unpack(_ archive: URL, into directory: URL, only entryPrefix: String? = nil) async throws -> [String] {
        // Validated against every entry, directories included: the file arrived
        // from somewhere else, so its entry names are not trusted.
        let raw = try await rawEntries(in: archive)
        if let escaping = raw.first(where: { isEscaping($0) }) {
            throw SimToolError("Refusing to extract \(archive.lastPathComponent): the entry \"\(escaping)\" points outside the destination.")
        }
        let all = raw.filter { !$0.hasSuffix("/") }
        let selected = entryPrefix.map { prefix in all.filter { $0 == prefix || $0.hasPrefix(prefix) } } ?? all
        guard !selected.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var arguments = ["-q", "-o", archive.path]
        if let entryPrefix { arguments.append(entryPrefix + "*") }
        arguments += ["-d", directory.path]
        let output = try await runUnzip(arguments, archive: archive)
        guard output.status == 0 else {
            throw SimToolError("Extracting \(archive.lastPathComponent) failed (unzip exited \(output.status)): \(trimmed(output.stderrString))")
        }
        return selected
    }

    /// The `${VAR}` names and the app an archive's receiver has to supply.
    ///
    /// Reads the launch too, because a profile's arguments live in the sender's
    /// `config.yml` and never appear in the test file itself. Names the test
    /// defines in its own `variables:` are not requirements — the test carries
    /// those values, which is the point of writing them there.
    public static func requirements(
        testYAML: String,
        launch: ResolvedLaunch?,
        app: String?,
        defined: [String: String] = [:],
        simtoolVersion: String? = SimToolVersion.current
    ) -> TestFlowManifest.Requires {
        var names = LaunchVariables.names(in: testYAML)
        func add(_ text: String) {
            for name in LaunchVariables.names(in: text) where !names.contains(name) { names.append(name) }
        }
        if let launch {
            launch.arguments.forEach(add)
            launch.environment.values.sorted().forEach(add)
            if let deeplink = launch.deeplink { add(deeplink) }
        }
        return TestFlowManifest.Requires(
            env: names.filter { defined[$0] == nil }.sorted(),
            app: app,
            simtool: simtoolVersion,
            carries: defined.keys.sorted()
        )
    }

    /// A file name for an archive of this test: the reference if it has one,
    /// else its name, else the session id. Everything a file name should not
    /// contain becomes a dash.
    public static func suggestedFileName(reference: String?, name: String?, sessionId: String) -> String {
        let candidates = [reference, name, sessionId].compactMap { $0 }
        let base = candidates.first { !sanitize($0).isEmpty } ?? sessionId
        return sanitize(base) + "." + pathExtension
    }

    private static func sanitize(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(text.map { allowed.contains($0) ? $0 : "-" })
        // Collapse the runs a sentence-shaped test name produces.
        var collapsed = ""
        for character in mapped where !(character == "-" && collapsed.last == "-") {
            collapsed.append(character)
        }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
    }

    private static func isEscaping(_ entry: String) -> Bool {
        if entry.hasPrefix("/") { return true }
        return entry.split(separator: "/").contains("..")
    }

    private static func runUnzip(_ arguments: [String], archive: URL) async throws -> ProcessOutput {
        guard FileManager.default.isExecutableFile(atPath: unzipTool.path) else {
            throw SimToolError("`/usr/bin/unzip` is missing, so archives cannot be read on this machine.")
        }
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw SimToolError("No such archive: \(archive.path)")
        }
        return try await ProcessRunner.run(executable: unzipTool, arguments: arguments, timeoutSeconds: 600)
    }

    private static func trimmed(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "no output" : value
    }
}
