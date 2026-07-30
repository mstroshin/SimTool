import Foundation

/// One bundled agent skill: a Markdown brief that teaches a coding agent how to
/// drive this CLI. Embedded as a string rather than a SwiftPM resource so the
/// Homebrew-installed binary stays a single self-contained file with no bundle
/// to locate at runtime.
public struct AgentSkill: Sendable, Equatable {
    /// Directory name and frontmatter `name`; they must match or the skill does
    /// not load.
    public let name: String
    public let markdown: String

    public init(name: String, markdown: String) {
        self.name = name
        self.markdown = markdown
    }

    public static let all: [AgentSkill] = [.simtool, .simtoolTest]

    public static let fileName = "SKILL.md"
}

/// Writes the bundled skills into an agent's skills directory.
public enum AgentSkillInstaller {
    /// Which tree to write into.
    public enum Scope: String, CaseIterable, Sendable {
        /// `<project>/…` — this checkout only.
        case local
        /// `~/…` — every project on this machine.
        case global
        /// Install nothing.
        case none
    }

    /// Whose skills directory to write into. The layout is the same for both —
    /// `<root>/.claude/skills/<name>/SKILL.md` and
    /// `<root>/.codex/skills/<name>/SKILL.md` — so one document serves either.
    public enum Agent: String, CaseIterable, Sendable {
        case claude
        case codex

        var directoryName: String { "." + rawValue }
    }

    public enum Outcome: String, Encodable, Sendable {
        /// No file was there; the skill was written.
        case created
        /// A different file was there and `force` replaced it.
        case updated
        /// The file already matches the bundled skill.
        case upToDate
        /// A locally modified file was left alone (`force` would replace it).
        case conflict
    }

    public struct Installation: Encodable, Equatable, Sendable {
        public var skill: String
        public var agent: String
        public var scope: String
        public var outcome: Outcome
        public var path: String
    }

    /// The home directory a `global` install writes into. `HOME` first, because
    /// that is what every other tool on the machine means by the home directory —
    /// a container, a CI job or a test that sets it expects to be obeyed, and
    /// `NSHomeDirectory()` reads the password database instead and ignores it.
    public static func home(from environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let path = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Directory the skill is written into, or `nil` for `.none`. `home` is
    /// injectable so tests never touch the real `$HOME`.
    public static func directory(
        skill: AgentSkill,
        agent: Agent,
        scope: Scope,
        projectDirectory: URL,
        home: URL = home()
    ) -> URL? {
        let root: URL
        switch scope {
        case .local: root = projectDirectory
        case .global: root = home
        case .none: return nil
        }
        return root
            .appendingPathComponent(agent.directoryName, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skill.name, isDirectory: true)
    }

    /// Writes each skill for each agent. Never clobbers a file whose contents
    /// differ from the bundled skill unless `force` is set — an edited skill is
    /// the user's, `simtool init` is re-run often, and silently overwriting it
    /// would lose the launch-argument catalog they filled in. The check is per
    /// file, so an edited `simtool` does not hold back a fresh sibling.
    @discardableResult
    public static func install(
        skills: [AgentSkill] = AgentSkill.all,
        agents: [Agent],
        scope: Scope,
        projectDirectory: URL,
        home: URL = home(),
        force: Bool = false
    ) throws -> [Installation] {
        var installations: [Installation] = []
        for agent in agents {
            for skill in skills {
                guard let directory = directory(
                    skill: skill, agent: agent, scope: scope,
                    projectDirectory: projectDirectory, home: home
                ) else { continue }
                let destination = directory.appendingPathComponent(AgentSkill.fileName)
                // Normalized rather than merely standardized: this path is
                // computed before the file exists, and `standardizedFileURL`
                // spells such a path differently from one that does.
                let path = FilePathDisplay.normalized(destination)
                let existing = try? String(contentsOf: destination, encoding: .utf8)
                func installation(_ outcome: Outcome) -> Installation {
                    Installation(skill: skill.name, agent: agent.rawValue, scope: scope.rawValue, outcome: outcome, path: path)
                }
                if let existing {
                    if existing == skill.markdown {
                        installations.append(installation(.upToDate))
                        continue
                    }
                    guard force else {
                        installations.append(installation(.conflict))
                        continue
                    }
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(skill.markdown.utf8).write(to: destination, options: [.atomic])
                installations.append(installation(existing == nil ? .created : .updated))
            }
        }
        return installations
    }
}
