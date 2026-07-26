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
        let installation = try AgentSkill.install(scope: .local, projectDirectory: project, home: try home())

        XCTAssertEqual(installation.outcome, .created)
        XCTAssertEqual(installation.scope, "local")
        let expected = project.appendingPathComponent(".claude/skills/simtool/SKILL.md")
        XCTAssertEqual(installation.path, expected.standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: expected, encoding: .utf8), AgentSkill.markdown)
    }

    // `global` must land in $HOME, not in whatever directory `init` happened to
    // run from — that is the whole difference between the two scopes.
    func testGlobalScopeWritesIntoHomeNotTheProject() throws {
        let project = try project()
        let home = try home()
        let installation = try AgentSkill.install(scope: .global, projectDirectory: project, home: home)

        XCTAssertEqual(installation.outcome, .created)
        XCTAssertEqual(installation.path, home.appendingPathComponent(".claude/skills/simtool/SKILL.md").standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".claude").path))
    }

    func testNoneScopeWritesNothing() throws {
        let project = try project()
        let installation = try AgentSkill.install(scope: .none, projectDirectory: project, home: try home())

        XCTAssertEqual(installation.outcome, .skipped)
        XCTAssertNil(installation.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".claude").path))
    }

    func testReinstallingAnUnchangedSkillReportsUpToDate() throws {
        let project = try project()
        let home = try home()
        try AgentSkill.install(scope: .local, projectDirectory: project, home: home)
        let second = try AgentSkill.install(scope: .local, projectDirectory: project, home: home)

        XCTAssertEqual(second.outcome, .upToDate)
    }

    // `init` is re-run routinely; a skill the user filled in with their app's
    // launch-argument catalog must survive that.
    func testEditedSkillIsKeptUntilForced() throws {
        let project = try project()
        let home = try home()
        try AgentSkill.install(scope: .local, projectDirectory: project, home: home)
        let destination = project.appendingPathComponent(".claude/skills/simtool/SKILL.md")
        try Data("edited by the user\n".utf8).write(to: destination)

        let kept = try AgentSkill.install(scope: .local, projectDirectory: project, home: home)
        XCTAssertEqual(kept.outcome, .conflict)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "edited by the user\n")

        let forced = try AgentSkill.install(scope: .local, projectDirectory: project, home: home, force: true)
        XCTAssertEqual(forced.outcome, .updated)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), AgentSkill.markdown)
    }

    func testMarkdownIsAValidSkillDocument() {
        XCTAssertTrue(AgentSkill.markdown.hasPrefix("---\nname: simtool\n"), "frontmatter must open the file or the skill is not loadable")
        XCTAssertTrue(AgentSkill.markdown.hasSuffix("\n"), "installed files end with a newline")
        XCTAssertTrue(AgentSkill.markdown.contains("\ndescription: "))
    }

    // The skill is app-agnostic on purpose: it ships to every simtool user, so a
    // stray identifier from the project it was authored against would leak.
    func testMarkdownCarriesNoProjectSpecificIdentifiers() {
        for needle in ["diftech", "platamator", "/Users/", "xcworkspace --scheme App "] {
            XCTAssertFalse(
                AgentSkill.markdown.lowercased().contains(needle.lowercased()),
                "the bundled skill must not mention \(needle)"
            )
        }
    }

    // `skills/simtool/SKILL.md` is the copy you edit by hand; the literal above is
    // what actually ships. Drift between them means users get a stale skill.
    func testBundledMarkdownMatchesTheRepositoryCopy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SimToolCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // Tool/
            .deletingLastPathComponent()  // repository root
        let authored = repositoryRoot.appendingPathComponent("skills/simtool/SKILL.md")
        guard let contents = try? String(contentsOf: authored, encoding: .utf8) else {
            throw XCTSkip("no authoring copy at \(authored.path) (building outside a checkout)")
        }
        XCTAssertEqual(contents, AgentSkill.markdown, "regenerate AgentSkill.markdown from skills/simtool/SKILL.md")
    }
}
