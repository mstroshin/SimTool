import Foundation
import XCTest
@testable import SimToolCore

final class AgentSkillTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AgentSkillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func project() throws -> URL {
        let url = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func home() throws -> URL {
        let url = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLocalScopeWritesIntoTheProject() throws {
        let project = try project()
        let installed = try AgentSkillInstaller.install(
            skills: [.simtool], agents: [.claude], scope: .local,
            projectDirectory: project, home: try home()
        )

        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed[0].outcome, .created)
        XCTAssertEqual(installed[0].skill, "simtool")
        XCTAssertEqual(installed[0].agent, "claude")
        XCTAssertEqual(installed[0].scope, "local")
        let expected = project.appendingPathComponent(".claude/skills/simtool/SKILL.md")
        XCTAssertEqual(installed[0].path, expected.standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: expected, encoding: .utf8), AgentSkill.simtool.markdown)
    }

    // `global` must land in $HOME, not in whatever directory `init` happened to
    // run from — that is the whole difference between the two scopes.
    func testGlobalScopeWritesIntoHomeNotTheProject() throws {
        let project = try project()
        let home = try home()
        let installed = try AgentSkillInstaller.install(
            skills: [.simtool], agents: [.claude], scope: .global,
            projectDirectory: project, home: home
        )

        XCTAssertEqual(installed[0].path, home.appendingPathComponent(".claude/skills/simtool/SKILL.md").standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".claude").path))
    }

    // Same document, two layouts: the point of the agent axis is that nothing
    // about the skill itself differs.
    func testCodexGetsTheSameDocumentInItsOwnLayout() throws {
        let project = try project()
        let installed = try AgentSkillInstaller.install(
            skills: [.simtool], agents: [.codex], scope: .local,
            projectDirectory: project, home: try home()
        )

        let expected = project.appendingPathComponent(".codex/skills/simtool/SKILL.md")
        XCTAssertEqual(installed[0].agent, "codex")
        XCTAssertEqual(installed[0].path, expected.standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: expected, encoding: .utf8), AgentSkill.simtool.markdown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".claude").path))
    }

    func testBothAgentsGetEverySkill() throws {
        let project = try project()
        let installed = try AgentSkillInstaller.install(
            agents: [.claude, .codex], scope: .local,
            projectDirectory: project, home: try home()
        )

        XCTAssertEqual(installed.count, AgentSkill.all.count * 2)
        for skill in AgentSkill.all {
            for agent in ["claude", "codex"] {
                XCTAssertTrue(
                    installed.contains { $0.skill == skill.name && $0.agent == agent },
                    "\(skill.name) missing for \(agent)"
                )
            }
        }

        // The metadata above can't tell two agents apart from one collapsed
        // write: read both files back to prove each agent got its own copy.
        for agent in ["claude", "codex"] {
            let destination = project.appendingPathComponent(".\(agent)/skills/simtool/SKILL.md")
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), AgentSkill.simtool.markdown, "\(agent) got the wrong document")
        }
        XCTAssertEqual(Set(installed.map(\.path)).count, installed.count, "every installation must be its own file")
    }

    func testNoneScopeAndNoAgentsWriteNothing() throws {
        let project = try project()

        XCTAssertEqual(try AgentSkillInstaller.install(agents: [.claude], scope: .none, projectDirectory: project, home: try home()), [])
        XCTAssertEqual(try AgentSkillInstaller.install(agents: [], scope: .local, projectDirectory: project, home: try home()), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".claude").path))
    }

    func testReinstallingAnUnchangedSkillReportsUpToDate() throws {
        let project = try project()
        let home = try home()
        _ = try AgentSkillInstaller.install(agents: [.claude], scope: .local, projectDirectory: project, home: home)

        let second = try AgentSkillInstaller.install(agents: [.claude], scope: .local, projectDirectory: project, home: home)

        XCTAssertTrue(second.allSatisfy { $0.outcome == .upToDate }, "\(second)")
    }

    // `init` is re-run routinely; a skill the user filled in with their app's
    // launch-argument catalog must survive that. Per file, so an edited
    // `simtool` does not block a fresh sibling.
    func testEditedSkillIsKeptUntilForced() throws {
        let project = try project()
        let home = try home()
        _ = try AgentSkillInstaller.install(skills: [.simtool], agents: [.claude], scope: .local, projectDirectory: project, home: home)
        let destination = project.appendingPathComponent(".claude/skills/simtool/SKILL.md")
        try Data("edited by the user\n".utf8).write(to: destination)

        let kept = try AgentSkillInstaller.install(skills: [.simtool], agents: [.claude], scope: .local, projectDirectory: project, home: home)
        XCTAssertEqual(kept[0].outcome, .conflict)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "edited by the user\n")

        let forced = try AgentSkillInstaller.install(skills: [.simtool], agents: [.claude], scope: .local, projectDirectory: project, home: home, force: true)
        XCTAssertEqual(forced[0].outcome, .updated)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), AgentSkill.simtool.markdown)
    }

    func testEverySkillIsAValidSkillDocument() {
        for skill in AgentSkill.all {
            XCTAssertTrue(
                skill.markdown.hasPrefix("---\nname: \(skill.name)\n"),
                "\(skill.name): frontmatter must open the file, and its `name` must match the directory"
            )
            XCTAssertTrue(skill.markdown.contains("\ndescription: "), "\(skill.name): no description")
            XCTAssertTrue(skill.markdown.hasSuffix("\n"), "\(skill.name): installed files end with a newline")
        }
    }

    // The skills are app-agnostic on purpose: they ship to every simtool user,
    // so a stray identifier from the project one was authored against would leak.
    func testNoSkillCarriesProjectSpecificIdentifiers() {
        for skill in AgentSkill.all {
            for needle in ["diftech", "platamator", "/Users/", "xcworkspace --scheme App "] {
                XCTAssertFalse(
                    skill.markdown.lowercased().contains(needle.lowercased()),
                    "\(skill.name) must not mention \(needle)"
                )
            }
        }
    }

    // `skills/<name>/SKILL.md` is the copy you edit by hand; the literal is what
    // ships. Drift means users get a stale skill — regenerate with
    // `Scripts/sync-agent-skills.swift`.
    func testEverySkillMatchesItsRepositoryCopy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SimToolCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // Tool/
            .deletingLastPathComponent()  // repository root
        for skill in AgentSkill.all {
            let authored = repositoryRoot.appendingPathComponent("skills/\(skill.name)/SKILL.md")
            guard let contents = try? String(contentsOf: authored, encoding: .utf8) else {
                throw XCTSkip("no authoring copy at \(authored.path) (building outside a checkout)")
            }
            XCTAssertEqual(contents, skill.markdown, "run Scripts/sync-agent-skills.swift for \(skill.name)")
        }
    }
}
