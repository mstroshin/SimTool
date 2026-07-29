# Sharing a test as a file, and teaching agents to write one — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `*.simflow.zip` handoff with a plain YAML file plus a `report.md` written next to every run, let `simtool test run` start its own server, and split the bundled agent skill into `simtool` and `simtool-test` installable into Claude Code's or Codex's layout.

**Architecture:** `TestFlowArchive` and the `test export`/`test show` subcommands are deleted. `TestReportRenderer` survives, reshaped to render one `TestSession` instead of an archive manifest, and a new `TestReportWriter` puts its output in the session directory at the end of every recorded run. `TestCommand.Run` gains two things it needed for a file that travels alone: a pre-flight check for `${VAR}` the test refers to but nothing defines, and an autostarted server (a free port, never a reclaimed one) that is torn down only if the run started it. `AgentSkill` splits into an installer and one document per skill, with an agent axis (`.claude` / `.codex`) alongside the existing scope axis.

**Tech Stack:** Swift 5.9 SwiftPM package under `Tool/`, `swift-argument-parser`, `Noora` for terminal output, `Yams` for YAML, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-29-test-sharing-and-skills-design.md`

## Global Constraints

- The package root for every build and test command is `Tool/`: `swift build --package-path Tool`, `swift test --package-path Tool`. Filter with `--filter <TestCaseName>`.
- Everything shipped in a skill document is **app-agnostic**. No bundle id, workspace, scheme, account, environment name or issue-tracker assumption from any real project. `AgentSkillTests.testMarkdownCarriesNoProjectSpecificIdentifiers` enforces a subset; the rule is broader than the test.
- SimTool assumes **no issue tracker**. `reference:` is stored and displayed, never parsed.
- No new key in the test YAML. A test's environment, account and country are the app's own launch arguments.
- Skill documents live twice: `skills/<name>/SKILL.md` is the copy you edit, `Tool/Sources/SimToolCore/Skills/<Name>Skill.swift` is what ships. They are kept identical by `Scripts/sync-agent-skills.swift` and asserted identical by a test.
- Comments explain *why*, in the voice of the surrounding code: no comment that restates the line below it.
- Every task ends green: `swift build --package-path Tool` and `swift test --package-path Tool` both pass before the commit.

---

### Task 1: The report renders a session, and the archive goes

**Files:**
- Modify: `Tool/Sources/SimToolCore/TestReportRenderer.swift` (whole file reshaped)
- Modify: `Tool/Tests/SimToolCoreTests/TestReportRendererTests.swift` (whole file reshaped)
- Delete: `Tool/Sources/SimToolCore/TestFlowArchive.swift`
- Delete: `Tool/Sources/SimToolCLI/TestFlowCommands.swift`
- Delete: `Tool/Tests/SimToolCoreTests/TestFlowArchiveTests.swift`
- Delete: `Tool/Tests/SimToolCLITests/TestFlowCommandTests.swift`
- Create: `Tool/Sources/SimToolCLI/CLINotes.swift`
- Modify: `Tool/Sources/SimToolCLI/SimTool.swift:1011` (subcommands), `:1104-1109` (discussion), `:1112` (argument help), `:1136-1155` (run body), `:1206-1216` (buildDrift removal)
- Modify: `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift:240-276`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `TestReportRenderer.render(session: TestSession, definition: TestDefinition? = nil, requiredVariables: [String] = []) -> String`
  - `TestReportRenderer.prettyRuntime(_ runtime: String) -> String` (unchanged, still public)
  - `emitNote(_ text: String, json: Bool)` now lives in `CLINotes.swift`

- [ ] **Step 1: Rewrite the renderer's tests against the new signature**

Replace the whole contents of `Tool/Tests/SimToolCoreTests/TestReportRendererTests.swift`:

```swift
import Foundation
import XCTest
@testable import SimToolCore

final class TestReportRendererTests: XCTestCase {
    func testLeadsWithTheVerdictAndItsExitCode() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.hasPrefix("# Tab order\n"), report.prefix(80).description)
        XCTAssertTrue(report.contains("**Bug reproduced** — `unsatisfied`, exit code 1"), report)
        XCTAssertTrue(report.contains("The Chat tab must open Chat, not Invite."), report)
    }

    // A session is enough to render: the test file may be gone, renamed, or on
    // another machine by the time anyone reads the report.
    func testRendersWithoutTheTestDefinition() {
        let report = TestReportRenderer.render(session: session())

        XCTAssertTrue(report.hasPrefix("# Tab order\n"), report.prefix(80).description)
        XCTAssertFalse(report.contains("The Chat tab must open Chat"), report)
    }

    func testASessionWithoutAVerdictSaysItMakesNoClaim() {
        var subject = session()
        subject.kind = nil
        subject.verdict = nil
        subject.criteria = []
        subject.status = .passed

        let report = TestReportRenderer.render(session: subject, definition: nil)

        XCTAssertTrue(report.contains("declares no `kind:`"), report)
        XCTAssertTrue(report.contains("passed"), report)
    }

    func testMarksEachCriterionAndSaysWhereItFailed() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains("✗ **the Chat tab opens Chat** — step 6: no element matching id \"ChatScreen\""), report)
        XCTAssertTrue(report.contains("a `bug` test stops at the first criterion that does not hold"), report)
    }

    func testAFeatureReportSaysItCheckedEverything() {
        var subject = session()
        subject.kind = .feature
        subject.criteria = [
            TestCriterionResult(label: "AC-1", status: .met, step: 3),
            TestCriterionResult(label: "AC-2", status: .unmet, step: 5, detail: "still enabled"),
        ]

        let report = TestReportRenderer.render(session: subject, definition: definition())

        XCTAssertTrue(report.contains("✓ **AC-1** — step 3"), report)
        XCTAssertTrue(report.contains("✗ **AC-2** — step 5: still enabled"), report)
        XCTAssertTrue(report.contains("checks all of its criteria in one run"), report)
    }

    func testAnUncheckedCriterionSaysTheRunNeverGotThere() {
        var subject = session()
        subject.verdict = .inconclusive
        subject.criteria = [TestCriterionResult(label: "the Chat tab opens Chat", status: .unchecked)]

        let report = TestReportRenderer.render(session: subject, definition: definition())

        XCTAssertTrue(report.contains("– **the Chat tab opens Chat** — the run never got this far"), report)
    }

    func testMockTableCountsWhatEachRuleAnswered() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains("| `*/GetTabBar` | 1 call | yes |"), report)
        XCTAssertTrue(report.contains("A strict rule that answers nothing makes the run `infra`"), report)
    }

    /// Wall-clock spans run longer than simctl's footage, so an unscaled offset
    /// sends the reader past the end of the video.
    func testTimelineOffsetsAreScaledOntoTheRealVideoLength() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains("`0:05` ✓ 1/6 waitFor id=MainScreenV2View"), report)
        XCTAssertTrue(report.contains("`0:08` ✗ 6/6 assertVisible id=ChatScreen"), report)
    }

    func testFactsNameTheBuildDeviceAndCommit() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains("| App | com.example.app 3.20.0 (4398) |"), report)
        XCTAssertTrue(report.contains("| Commit | `982b9170cc` |"), report)
        XCTAssertTrue(report.contains("| Device | iPhone 16 Pro · iOS 18.2 |"), report)
        XCTAssertTrue(report.contains("| Reference | PROJ-42 |"), report)
    }

    // The files are in the same directory as the report, so nothing may point at
    // an archive path that no longer exists.
    func testEvidenceListsTheSessionDirectoryItSitsIn() {
        let report = TestReportRenderer.render(session: session(), definition: definition())

        XCTAssertTrue(report.contains(".simtool/test-sessions/2026-07-28-1955-vy1cu3/"), report)
        XCTAssertTrue(report.contains("| `session.json` |"), report)
        XCTAssertTrue(report.contains("| `network.jsonl` |"), report)
        XCTAssertTrue(report.contains("| `video.mp4` |"), report)
        XCTAssertFalse(report.contains("runs/"), report)
    }

    func testRerunSectionNamesWhatTheReceiverSupplies() {
        let report = TestReportRenderer.render(
            session: session(),
            definition: definition(),
            requiredVariables: ["ACCOUNT"]
        )

        XCTAssertTrue(report.contains("`simtool` 0.9.0 or newer"), report)
        XCTAssertTrue(report.contains("`com.example.app` installed on a booted simulator"), report)
        XCTAssertTrue(report.contains("these variables exported: `ACCOUNT`"), report)
        XCTAssertTrue(report.contains("export ACCOUNT=…"), report)
        XCTAssertTrue(report.contains("simtool test run tab_order.yml"), report)
        XCTAssertTrue(report.contains("starts a server itself when none is running"), report)
    }

    func testRerunSectionSaysWhatTheTestDefinesItself() {
        var subject = definition()
        subject.variables = ["ACCOUNT": "+34600000000"]

        let report = TestReportRenderer.render(session: session(), definition: subject)

        XCTAssertTrue(report.contains("The test defines `ACCOUNT` itself"), report)
        XCTAssertTrue(report.contains("`--var NAME=value`"), report)
    }

    func testForwardingWarnsAboutRealAccountDataAndInlineValues() {
        var subject = definition()
        subject.variables = ["ACCOUNT": "+34600000000"]

        let report = TestReportRenderer.render(session: session(), definition: subject)

        XCTAssertTrue(report.contains("Before you forward this"), report)
        XCTAssertTrue(report.contains("`logs.jsonl`"), report)
        XCTAssertTrue(report.contains("team-internal"), report)
        XCTAssertTrue(report.contains("goes wherever this file goes"), report)
    }

    // MARK: - fixtures

    private func definition() -> TestDefinition {
        TestDefinition(
            name: "Tab order",
            description: "The Chat tab must open Chat, not Invite.",
            kind: .bug,
            reference: "PROJ-42",
            app: "com.example.app",
            launch: TestLaunch(profile: "staging-account1"),
            steps: [TestStep(action: .waitFor(TestTarget(kind: .id, query: "ChatScreen"), timeout: nil), criterion: "the Chat tab opens Chat")]
        )
    }

    private func session() -> TestSession {
        TestSession(
            id: "2026-07-28-1955-vy1cu3",
            title: "Tab order",
            deviceUdid: "UDID",
            deviceName: "iPhone 16 Pro",
            startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            endedAt: Date(timeIntervalSince1970: 1_785_000_020),
            recordingStartedAt: Date(timeIntervalSince1970: 1_785_000_000),
            status: .failed,
            videoDurationSeconds: 10,
            entries: [
                TestSessionEntry(
                    kind: .step,
                    at: Date(timeIntervalSince1970: 1_785_000_010),
                    text: "✓ 1/6 waitFor id=MainScreenV2View"
                ),
                TestSessionEntry(
                    kind: .step,
                    at: Date(timeIntervalSince1970: 1_785_000_016),
                    text: "✗ 6/6 assertVisible id=ChatScreen — no element appeared",
                    criterion: "the Chat tab opens Chat"
                ),
            ],
            kind: .bug,
            reference: "PROJ-42",
            criteria: [TestCriterionResult(
                label: "the Chat tab opens Chat",
                status: .unmet,
                step: 6,
                detail: "no element matching id \"ChatScreen\" appeared within 25.0s"
            )],
            verdict: .unsatisfied,
            mocks: [TestMockOutcome(id: "mock-2", method: "*/GetTabBar", hits: 1, strict: true)],
            evidence: ["logs.jsonl", "network.jsonl", "failure-step-6.png"],
            provenance: TestRunProvenance(
                testFile: "tab_order.yml",
                appBundleId: "com.example.app",
                appVersion: "3.20.0",
                appBuild: "4398",
                commit: "982b9170cc",
                deviceName: "iPhone 16 Pro",
                runtime: "iOS 18.2",
                simtoolVersion: "0.9.0",
                launch: ResolvedLaunch(profile: "staging-account1", arguments: ["-Environment", "stable"])
            )
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Tool --filter TestReportRendererTests`
Expected: compile failure — `render(session:definition:requiredVariables:)` does not exist.

- [ ] **Step 3: Reshape the renderer**

In `Tool/Sources/SimToolCore/TestReportRenderer.swift`, replace the doc comment, `render` and the six section functions. Everything from `// MARK: - helpers` down (`logLinesPerEntry`, `describe`, `videoScale`, `offset`, `duration`, `prettyRuntime`, `mmss`, `timestamp`, `sentence`, `escapePipes`) and the private `Markdown` struct stay as they are, minus `files(for:includedFiles:)`, which goes with the manifest.

```swift
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
        if let simtool = session.provenance?.simtoolVersion { needs.append("`simtool` \(simtool) or newer") }
        if let app = session.provenance?.appBundleId {
            needs.append("`\(app)` installed on a booted simulator — your own build, which is the point when verifying a fix")
        }
        if !requiredVariables.isEmpty {
            needs.append("these variables exported: " + requiredVariables.map { "`\($0)`" }.joined(separator: ", "))
        }
        out.paragraph(needs.isEmpty ? "Needs `simtool` and a booted simulator." : "You need " + sentence(needs) + ".")

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

    // The snippet ends here: everything from `// MARK: - helpers` to the end of
    // the file stays as it is, closing brace included. Delete only the private
    // `files(for:includedFiles:)`, which existed to read the manifest.
```

- [ ] **Step 4: Delete the archive and the commands that used it**

```bash
git rm Tool/Sources/SimToolCore/TestFlowArchive.swift \
       Tool/Sources/SimToolCLI/TestFlowCommands.swift \
       Tool/Tests/SimToolCoreTests/TestFlowArchiveTests.swift \
       Tool/Tests/SimToolCLITests/TestFlowCommandTests.swift
```

`emitNote` was defined at the bottom of the deleted `TestFlowCommands.swift` and is still called from `SimTool.swift`. Create `Tool/Sources/SimToolCLI/CLINotes.swift`:

```swift
import Foundation
import Noora

/// One line the operator should see but a script should not have to parse.
/// Under `--json` it goes to stderr, so stdout stays a single JSON document.
func emitNote(_ text: String, json: Bool) {
    if json {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    } else {
        makeNoora().info("\(text)")
    }
}
```

`formatBytes` had no caller outside the deleted code; it is gone with it.

- [ ] **Step 5: Cut the archive out of the `test` command surface**

In `Tool/Sources/SimToolCLI/SimTool.swift`:

`TestCommand.configuration`:

```swift
        subcommands: [Run.self, List.self]
```

`TestCommand.Run.configuration.discussion` — delete the final paragraph beginning "A `*.simflow.zip` from `simtool test export` runs the same way." and replace the paragraph about `${VAR}` resolution's last sentence so the discussion ends:

```
            `${VAR}` in a launch profile, in this test's own arguments or in a
            setup command is resolved from `variables:` first, then from the
            environment; `--var NAME=value` overrides both. A reference nothing
            defines fails the run before the simulator is touched. Writing the
            account under `variables:` is what makes a test say which account it
            runs as and travel ready-to-run — at the cost of carrying that value
            in the file. Leave it out of `variables:` to keep it in the shell
            instead.
```

`Run.test`'s help becomes `"Path to a YAML test file."`.

In `Run.run()`, replace the loading block

```swift
            let prepared = try await TestSourceLoader.load(path: test, config: projectConfig, overrides: overrides)
            let parsed = prepared.definition
            let testURL = prepared.file
```

with

```swift
            let testURL = URL(fileURLWithPath: test)
            let parsed = try TestDefinitionParser.load(contentsOf: testURL)
```

and delete the notes/build-drift block

```swift
            var notes = prepared.notes
            if let manifest = prepared.manifest {
                notes += await Self.buildDrift(manifest: manifest, test: parsed, config: projectConfig, client: client)
            }
            for line in notes { emitNote(line, json: common.json) }
```

together with the `static func buildDrift(...)` helper. In the executor options, `profiles:` becomes `projectConfig?.profiles ?? []` (the `prepared.extraProfiles` term goes).

- [ ] **Step 6: Trim the command-surface tests**

In `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift`, delete `testTestExportParsesTheRunToPackageAndWhatToLeaveOut`, `testTestExportNeedsNoArgumentsAtAll`, `testTestShowParsesTheArchiveAndItsModes`, `testTestShowRequiresAnArchive`, and rewrite:

```swift
    func testTestSubcommandsCoverRunningAndListing() {
        let names = TestCommand.configuration.subcommands.map { commandName(for: $0) }
        XCTAssertEqual(names, ["run", "list"])
    }
```

- [ ] **Step 7: Build and run the whole suite**

Run: `swift build --package-path Tool && swift test --package-path Tool`
Expected: PASS. If `TestReportRendererTests` reports a mismatched timeline offset, check the fixture's `videoDurationSeconds` against the entry timestamps rather than changing the renderer — the scaling is `videoDuration / (endedAt - recordingStartedAt)`, i.e. 10/20, so a step 10s in renders as `0:05`.

- [ ] **Step 8: Commit**

```bash
git add -A Tool docs
git commit -m "$(cat <<'EOF'
refactor(test)!: drop the flow archive, keep its report next to the run

The *.simflow.zip was more machinery than the handoff needs. What is worth
sending is the YAML test — readable, diffable, sendable in a chat message —
so `test export`, `test show` and running a test out of an archive are gone,
along with the manifest that described what an archive carried.

TestReportRenderer survives because the report was the good part: it now
renders one recorded session, and says what the receiver of the test file has
to supply rather than what the archive left out.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: A `${VAR}` nothing defines fails before the simulator is touched

**Files:**
- Modify: `Tool/Sources/SimToolCore/LaunchProfile.swift:57-72` (add an overload after `names(in text:)`)
- Modify: `Tool/Sources/SimToolCLI/SimTool.swift` (`TestCommand.Run`: new static helper + a call in `run()`)
- Create: `Tool/Tests/SimToolCoreTests/LaunchVariablesTests.swift`
- Modify: `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift` (add the unresolved-variable cases)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `LaunchVariables.names(in launch: ResolvedLaunch, setup: [String] = []) -> [String]`
  - `TestCommand.Run.unresolvedVariables(test: TestDefinition, profiles: [LaunchProfile], environment: [String: String], overrides: [String: String]) -> [String]`

- [ ] **Step 1: Write the failing test for the name collector**

Create `Tool/Tests/SimToolCoreTests/LaunchVariablesTests.swift`:

```swift
import Foundation
import XCTest
@testable import SimToolCore

final class LaunchVariablesTests: XCTestCase {
    func testCollectsNamesFromArgumentsEnvironmentDeeplinkAndSetup() {
        let launch = ResolvedLaunch(
            profile: "staging",
            arguments: ["-Environment", "stable", "-FastLoginPhone", "${ACCOUNT}"],
            environment: ["TOKEN": "${SESSION_TOKEN}"],
            deeplink: "myapp://invite/${INVITE_CODE}"
        )

        let names = LaunchVariables.names(in: launch, setup: ["simtool app launch -- -Phone \"${ACCOUNT}\" -Seed ${SEED}"])

        XCTAssertEqual(names, ["ACCOUNT", "SESSION_TOKEN", "INVITE_CODE", "SEED"])
    }

    func testIgnoresAnUnterminatedReferenceAndDeduplicates() {
        let launch = ResolvedLaunch(arguments: ["${ACCOUNT}", "${ACCOUNT}", "${OPEN"])

        XCTAssertEqual(LaunchVariables.names(in: launch), ["ACCOUNT"])
    }

    func testALaunchWithNoReferencesNeedsNothing() {
        XCTAssertEqual(LaunchVariables.names(in: ResolvedLaunch(arguments: ["-UITesting"])), [])
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Tool --filter LaunchVariablesTests`
Expected: compile failure — no `names(in:setup:)` overload.

- [ ] **Step 3: Add the overload**

In `Tool/Sources/SimToolCore/LaunchProfile.swift`, inside `enum LaunchVariables`, after the existing `names(in text: String)`:

```swift
    /// Names referenced where SimTool actually substitutes: the launch it is
    /// about to perform (profile argv, env values and deeplink, plus the test's
    /// inline ones) and the setup commands, which receive the variables as their
    /// shell environment.
    ///
    /// Deliberately not a scan of the whole test file: `${…}` inside a mock body
    /// is literal data the app decodes, not a demand on whoever runs the test.
    public static func names(in launch: ResolvedLaunch, setup: [String] = []) -> [String] {
        var found: [String] = []
        func add(_ text: String) {
            for name in names(in: text) where !found.contains(name) { found.append(name) }
        }
        launch.arguments.forEach(add)
        for key in launch.environment.keys.sorted() { add(launch.environment[key] ?? "") }
        if let deeplink = launch.deeplink { add(deeplink) }
        setup.forEach(add)
        return found
    }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path Tool --filter LaunchVariablesTests`
Expected: PASS

- [ ] **Step 5: Write the failing test for the run's pre-flight**

Add to `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift`:

```swift
    // The check the receiver of a test file hits first: the file refers to an
    // account it does not define, and nothing on this machine defines it either.
    func testUnresolvedVariablesNameWhatNothingDefines() {
        let test = TestDefinition(
            name: "Tab order",
            launch: TestLaunch(profile: "staging"),
            setup: ["echo ${SEED}"],
            steps: [TestStep(action: .waitFor(TestTarget(kind: .id, query: "Main"), timeout: nil))]
        )
        let profiles = [LaunchProfile(name: "staging", arguments: ["-FastLoginPhone", "${ACCOUNT}"])]

        let missing = TestCommand.Run.unresolvedVariables(
            test: test,
            profiles: profiles,
            environment: [:],
            overrides: [:]
        )

        XCTAssertEqual(missing, ["ACCOUNT", "SEED"])
    }

    func testTheTestFileTheEnvironmentAndAnOverrideAllSatisfyAReference() {
        var test = TestDefinition(
            launch: TestLaunch(profile: "staging"),
            steps: [TestStep(action: .waitFor(TestTarget(kind: .id, query: "Main"), timeout: nil))]
        )
        test.variables = ["ACCOUNT": "+34600000000"]
        let profiles = [LaunchProfile(name: "staging", arguments: ["-Phone", "${ACCOUNT}", "-Seed", "${SEED}"])]

        XCTAssertEqual(
            TestCommand.Run.unresolvedVariables(test: test, profiles: profiles, environment: ["SEED": "7"], overrides: [:]),
            []
        )
        XCTAssertEqual(
            TestCommand.Run.unresolvedVariables(test: test, profiles: profiles, environment: [:], overrides: ["SEED": "7"]),
            []
        )
    }

    // An exported empty string is not a value: it logs the run in as nobody.
    func testAnEmptyValueCountsAsUnresolved() {
        let test = TestDefinition(
            launch: TestLaunch(arguments: ["-Phone", "${ACCOUNT}"]),
            steps: [TestStep(action: .waitFor(TestTarget(kind: .id, query: "Main"), timeout: nil))]
        )

        XCTAssertEqual(
            TestCommand.Run.unresolvedVariables(test: test, profiles: [], environment: ["ACCOUNT": ""], overrides: [:]),
            ["ACCOUNT"]
        )
    }
```

- [ ] **Step 6: Run it to verify it fails**

Run: `swift test --package-path Tool --filter SimToolCommandSurfaceTests`
Expected: compile failure — no `unresolvedVariables`.

- [ ] **Step 7: Implement the helper and call it**

In `TestCommand.Run`, next to `parseVariableOverrides`:

```swift
        /// `${VAR}` the test refers to and nothing supplies: not its own
        /// `variables:`, not the environment, not `--var`.
        ///
        /// Checked before the run touches the simulator, because that is where
        /// this fails for the person a test was handed to: `expand` would report
        /// it too, but only after the boot, the reset and the mocks — and a name
        /// referenced only from `setup:` would never be reported at all, since
        /// the shell expands an unset variable to nothing.
        static func unresolvedVariables(
            test: TestDefinition,
            profiles: [LaunchProfile],
            environment: [String: String],
            overrides: [String: String]
        ) -> [String] {
            let profile = profiles.first { $0.name == test.launch.profile }
            let launch = test.launch.resolved(profile: profile)
            let available = test.resolvedVariables(environment: environment, overrides: overrides)
            return LaunchVariables.names(in: launch, setup: test.setup)
                .filter { (available[$0] ?? "").isEmpty }
        }
```

In `Run.run()`, right after `parsed` is loaded and before the client is resolved:

```swift
            let missing = Self.unresolvedVariables(
                test: parsed,
                profiles: projectConfig?.profiles ?? [],
                environment: ProcessInfo.processInfo.environment,
                overrides: overrides
            )
            if !missing.isEmpty {
                let one = missing.count == 1
                throw SimToolError("""
                    This test refers to \(missing.joined(separator: ", ")) without defining \(one ? "it" : "them") — \
                    usually the account it runs as. Export \(one ? "it" : "them"), pass `--var \(missing[0])=…`, \
                    or add \(one ? "it" : "them") under `variables:` in the test.
                    """)
            }
```

- [ ] **Step 8: Run the suite**

Run: `swift test --package-path Tool`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add -A Tool
git commit -m "$(cat <<'EOF'
fix(test): say which variable is missing before staging anything

A test file now travels on its own, so the receiver missing the account it
runs as is the normal case rather than an edge one. The names are collected
where SimTool actually substitutes — the resolved launch and the setup
commands — and the run stops before the boot, the reset and the mocks instead
of failing minutes in.

A name referenced only from `setup:` was never reported at all: the shell
expands an unset variable to nothing, so the command ran against no account.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Every recorded run writes `report.md`

**Files:**
- Create: `Tool/Sources/SimToolCore/TestReportWriter.swift`
- Create: `Tool/Tests/SimToolCoreTests/TestReportWriterTests.swift`
- Modify: `Tool/Sources/SimToolClient/TestRunExecutor.swift` (two new properties, the session-start block, `finish`, the cancelled path)
- Modify: `Tool/Sources/SimToolCLI/SimTool.swift` (`TestCommand.Run.printReport`)

**Interfaces:**
- Consumes: `TestReportRenderer.render(session:definition:requiredVariables:)` (Task 1), `LaunchVariables.names(in launch:setup:)` (Task 2).
- Produces: `TestReportWriter.write(session:definition:requiredVariables:into:) throws -> URL`, `TestReportWriter.fileName`.

- [ ] **Step 1: Write the failing test**

Create `Tool/Tests/SimToolCoreTests/TestReportWriterTests.swift`:

```swift
import Foundation
import XCTest
@testable import SimToolCore

final class TestReportWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TestReportWriterTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWritesTheReportIntoADirectoryItCreates() throws {
        let url = try TestReportWriter.write(session: session(), definition: nil, into: directory)

        XCTAssertEqual(url.lastPathComponent, "report.md")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("# Tab order\n"), contents.prefix(60).description)
    }

    // A re-run of the same session id is the same run being re-recorded; a stale
    // report next to fresh evidence is worse than no report.
    func testOverwritesAnExistingReport() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale\n".utf8).write(to: directory.appendingPathComponent("report.md"))

        let url = try TestReportWriter.write(session: session(), definition: nil, into: directory)

        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("stale"))
    }

    func testCarriesTheVariablesTheReceiverMustSupply() throws {
        let url = try TestReportWriter.write(
            session: session(),
            definition: nil,
            requiredVariables: ["ACCOUNT"],
            into: directory
        )

        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("export ACCOUNT=…"))
    }

    private func session() -> TestSession {
        TestSession(
            id: "2026-07-28-1955-vy1cu3",
            title: "Tab order",
            deviceUdid: "UDID",
            deviceName: "iPhone 16 Pro",
            startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            endedAt: Date(timeIntervalSince1970: 1_785_000_020),
            status: .failed,
            kind: .bug,
            criteria: [TestCriterionResult(label: "the Chat tab opens Chat", status: .unmet, step: 6)],
            verdict: .unsatisfied
        )
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Tool --filter TestReportWriterTests`
Expected: compile failure — no `TestReportWriter`.

- [ ] **Step 3: Write the writer**

Create `Tool/Sources/SimToolCore/TestReportWriter.swift`:

```swift
import Foundation

/// Puts the run's Markdown report in the run's own directory.
///
/// Separate from the renderer so the file-writing half is testable without a
/// simulator, and so the executor's failure handling stays one call deep: a
/// report that could not be written is a note on the run, never a failed run.
public enum TestReportWriter {
    public static let fileName = "report.md"

    @discardableResult
    public static func write(
        session: TestSession,
        definition: TestDefinition?,
        requiredVariables: [String] = [],
        into directory: URL
    ) throws -> URL {
        let markdown = TestReportRenderer.render(
            session: session,
            definition: definition,
            requiredVariables: requiredVariables
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try Data(markdown.utf8).write(to: url, options: [.atomic])
        return url
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path Tool --filter TestReportWriterTests`
Expected: PASS

- [ ] **Step 5: Have the executor write it**

In `Tool/Sources/SimToolClient/TestRunExecutor.swift`, next to `private var evidenceDirectory: URL?`:

```swift
    /// The run's own directory. Unlike `evidenceDirectory` this is not gated on
    /// the evidence level: `report.md` is the one artifact written for a person,
    /// and `--evidence none` is a statement about captures, not about that.
    private var sessionDirectory: URL?
    /// `${VAR}` the test refers to without defining, for the report's
    /// "what you have to supply" section.
    private var requiredVariables: [String] = []
```

Right after the launch is resolved (the `(launch, recordedLaunch) = try resolveLaunch(test)` line, inside the same `do` block):

```swift
            requiredVariables = LaunchVariables.names(in: recordedLaunch, setup: test.setup)
                .filter { test.variables[$0] == nil }
```

In the session-start block, replace

```swift
                    if let root = config.testSessionsPath, options.evidence != .none {
                        evidenceDirectory = URL(fileURLWithPath: root).appendingPathComponent(session.id, isDirectory: true)
                    }
```

with

```swift
                    if let root = config.testSessionsPath {
                        sessionDirectory = URL(fileURLWithPath: root).appendingPathComponent(session.id, isDirectory: true)
                        if options.evidence != .none { evidenceDirectory = sessionDirectory }
                    }
```

Add the writer call, and use it from both places a session is stopped. In `finish(...)`, after `let stopped = await stopSession(...)`:

```swift
        await writeReport(stopped, test: test)
```

In the cancelled path, capture what `stopSession` returns:

```swift
            let stopped = await stopSession(status: .interrupted, verdict: .inconclusive, criteria: criteria, mocks: evidence.mocks, detached: true)
            await writeReport(stopped, test: test)
```

And the helper, next to `stopSession`:

```swift
    /// Written after the session is stopped, because that response is where the
    /// finalized video length lives — and the report's timeline is in video time.
    private func writeReport(_ stopped: TestSession?, test: TestDefinition) async {
        guard let stopped, let directory = sessionDirectory else { return }
        do {
            try TestReportWriter.write(
                session: stopped,
                definition: test,
                requiredVariables: requiredVariables,
                into: directory
            )
        } catch {
            await note(["Report not written: \(message(of: error))"])
        }
    }
```

- [ ] **Step 6: Print the directory the run left behind**

`printReport` is a static, and the sessions root is a property of the project
config the caller already loaded, so pass it in rather than reaching for it:

```swift
        static func printReport(_ report: TestRunReport, sessionsRoot: URL?) {
            …
            takeaways += report.sessions.map { "Session: \($0)" }
            if let sessionsRoot, let id = report.sessions.last {
                takeaways.append("\(displayPath(sessionsRoot.appendingPathComponent(id))) — report.md, video.mp4")
            }
            …
        }

        /// Relative to the working directory when it is inside it: an absolute
        /// path is noise when the reader is standing in the checkout.
        private static func displayPath(_ url: URL) -> String {
            let cwd = FileManager.default.currentDirectoryPath
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(cwd + "/") else { return path }
            return String(path.dropFirst(cwd.count + 1))
        }
```

At the call site in `run()`:

```swift
                Self.printReport(report, sessionsRoot: projectConfig.map {
                    SimToolDirectory.testSessionsDirectory(in: $0.simtoolDirectory)
                })
```

- [ ] **Step 7: Build and run the suite**

Run: `swift build --package-path Tool && swift test --package-path Tool`
Expected: PASS

- [ ] **Step 8: Verify by hand against a simulator**

Run, from a checkout with a `.simtool/config.yml` and a booted simulator:

```bash
swift run --package-path Tool simtool serve --detach --json
swift run --package-path Tool simtool test run .simtool/tests/<any>.yml --evidence none
cat .simtool/test-sessions/<id>/report.md
```

Expected: the report exists despite `--evidence none`, its heading is the test's name, the verdict line matches the CLI's, and the timeline offsets are inside the video's length.

- [ ] **Step 9: Commit**

```bash
git add -A Tool
git commit -m "$(cat <<'EOF'
feat(test): every recorded run leaves a report next to its video

`report.md` lands in the session directory, so handing a test on is sending
the YAML plus, when it helps, the two files beside it. Written after the
session is stopped — that is when the video's real length is known, and the
timeline is in video time — and written regardless of `--evidence`, which is
a statement about captures rather than about the one artifact meant for a
person.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: One place that stops a session, and a server that can refuse to reclaim

**Files:**
- Create: `Tool/Sources/SimToolCLI/SessionControl.swift`
- Modify: `Tool/Sources/SimToolCLI/SimTool.swift` (`Kill.run`, `Serve` flags and `run`, `launchDetachedServer`, `runViewer`, `startStreamServer`)
- Modify: `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift` (the `serve` parse case)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `SessionControl.stop(_ session: SessionInfo) async`
  - `launchDetachedServer(parameters: ServeParameters, app: String?, verbose: Bool, reclaimPort: Bool = true) async throws -> SessionInfo`
  - `startStreamServer(config: StreamServerConfig, reclaimPort: Bool = true) async throws -> StreamServer`
  - `runViewer(…, reclaimPort: Bool = true, …)`

- [ ] **Step 1: Extract the teardown**

Create `Tool/Sources/SimToolCLI/SessionControl.swift`:

```swift
import Darwin
import Foundation
import SimToolCore

enum SessionControl {
    /// Stops a server session and cleans up after it.
    ///
    /// SIGTERM first, so the server runs its own graceful shutdown — which
    /// includes powering down the simulators it booted. If it will not die,
    /// force it and power those simulators down here instead, so a wedged or
    /// detached server cannot leak the simulator backend.
    static func stop(_ session: SessionInfo) async {
        Darwin.kill(session.pid, SIGTERM)
        for _ in 0..<60 where isProcessAlive(session.pid) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isProcessAlive(session.pid) {
            Darwin.kill(session.pid, SIGKILL)
            for udid in session.bootedDevices {
                await SimulatorDeviceClient.shutdown(udid)
            }
        }
        SessionStore.shared.remove(session.sessionId)
    }
}
```

`isProcessAlive` already exists in the CLI target (used by `Kill`); leave it where it is.

Then `Kill.run` becomes:

```swift
        guard let session else { throw SimToolError("No matching session found") }
        await SessionControl.stop(session)
        if common.json {
            try printJSON(["killed": session.sessionId])
        } else {
            makeNoora().success("Stopped session \(session.sessionId)")
        }
```

- [ ] **Step 2: Make the detached launcher return its session**

Change the signature and the two report paths in `launchDetachedServer`:

```swift
/// Spawns a background `serve --detached-child` process (inheriting this
/// process's environment, including the `SIMCTL_CHILD_` logger exports) and
/// waits for it to report a session.
///
/// `reclaimPort: false` forwards `--no-reclaim`, so the child fails instead of
/// killing whoever holds the port. Anything starting a server implicitly must
/// pass that: the port belongs to whoever is already on it.
func launchDetachedServer(
    parameters: ServeParameters,
    app: String?,
    verbose: Bool,
    reclaimPort: Bool = true
) async throws -> SessionInfo {
    // unchanged: the session id, ensureRoot, logPath, executable and the
    // Process/FileHandle setup, down to `try process.run()`.
    var args = ["serve", "--port", "\(parameters.port)", "--host", parameters.host, "--session-id", id, "--detached-child"]
    if let device = parameters.device { args += ["--device", device] }
    if let app, !app.isEmpty { args += ["--app", app] }
    if verbose { args += ["--verbose"] }
    if !reclaimPort { args.append("--no-reclaim") }
    // unchanged: the 330-second deadline comment and its computation.
    while Date() < deadline {
        if let session = try SessionStore.shared.session(id: id) { return session }
        if !process.isRunning {
            throw SimToolError("Detached server exited before reporting a session. See \(logPath.path)")
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw SimToolError("Detached server did not report a session within 330 seconds. See \(logPath.path)")
}
```

`Serve.runDetached` does the printing that moved out:

```swift
    private func runDetached(_ parameters: ServeParameters) async throws {
        let session = try await launchDetachedServer(
            parameters: parameters,
            app: app,
            verbose: verbose,
            reclaimPort: !noReclaim
        )
        if common.json {
            try printJSON(session)
        } else {
            makeNoora().success(.alert("SimTool server started", takeaways: ["Open \(session.url)"]))
        }
    }
```

- [ ] **Step 3: Plumb `--no-reclaim` through to the bind**

`Serve` gains, next to `detachedChild`:

```swift
    @Flag(name: .long, help: .hidden)
    var noReclaim = false
```

`Serve.run` passes it: `try await runViewer(…, reclaimPort: !noReclaim, …)`. `runViewer` gains the parameter (defaulted `true`, so `Run`'s call site is untouched) and forwards it: `let server = try await startStreamServer(config: config, reclaimPort: reclaimPort)`.

`startStreamServer` honours it:

```swift
func startStreamServer(config: StreamServerConfig, reclaimPort: Bool = true) async throws -> StreamServer {
    if reclaimPort, let pids = try? await PortReclaimer.listeningPIDs(port: config.port), !pids.isEmpty {
        emitPortReclaimMessage(port: config.port, pids: pids)
        let result = try await PortReclaimer.reclaim(port: config.port)
        cleanupSessions(for: result.pids)
    }

    do {
        let server = StreamServer(config: config)
        try server.start()
        return server
    } catch {
        // Killing the listener is a thing a user asked for by naming a port; it
        // is not a thing to do on someone's behalf, so a caller that opted out
        // gets the bind error and can pick another port.
        guard reclaimPort, PortReclaimer.isAddressInUse(error) else { throw error }
        // unchanged: listeningPIDs, emitPortReclaimMessage, reclaim,
        // cleanupSessions, the "no listening process" guard, and the retry.
    }
}
```

- [ ] **Step 4: Extend the `serve` parse test**

In `SimToolCommandSurfaceTests`:

```swift
    func testServeParsesWithoutBuiltInPortAndHostDefaults() throws {
        let command = try Serve.parse([])
        XCTAssertNil(command.device)
        XCTAssertNil(command.host)
        XCTAssertNil(command.port)
        XCTAssertNil(command.config)
        XCTAssertFalse(command.noReclaim)
    }

    // Hidden, but a started-on-our-own-initiative server depends on it.
    func testServeParsesNoReclaim() throws {
        XCTAssertTrue(try Serve.parse(["--no-reclaim"]).noReclaim)
    }
```

- [ ] **Step 5: Build and run the suite**

Run: `swift build --package-path Tool && swift test --package-path Tool`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add -A Tool
git commit -m "$(cat <<'EOF'
refactor(serve): one teardown, and a server that can decline to take a port

`Kill`'s SIGTERM-then-SIGKILL cleanup becomes SessionControl.stop so anything
that starts a server can stop it the same way, and launchDetachedServer
returns the session it started instead of printing it.

`--no-reclaim` exists because reclaiming a port means killing whoever holds
it. That is defensible when a user typed `--port 3200`; it is not something to
do on someone's behalf, and the next commit starts servers on its own
initiative.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Finding a port nobody is on

**Files:**
- Create: `Tool/Sources/SimToolCLI/ServerAutostart.swift`
- Create: `Tool/Tests/SimToolCLITests/ServerAutostartTests.swift`

**Interfaces:**
- Consumes: `ServeParameters` and `launchDetachedServer(parameters:app:verbose:reclaimPort:)` (Task 4).
- Produces:
  - `ServerAutostart.freePort(startingAt:limit:probe:) async throws -> UInt16`
  - `ServerAutostart.start(parameters: ServeParameters, json: Bool) async throws -> SessionInfo`

- [ ] **Step 1: Write the failing test**

Create `Tool/Tests/SimToolCLITests/ServerAutostartTests.swift`:

```swift
import Foundation
import XCTest
@testable import SimToolCLI
@testable import SimToolCore

final class ServerAutostartTests: XCTestCase {
    func testTakesTheConfiguredPortWhenNobodyIsOnIt() async throws {
        let port = try await ServerAutostart.freePort(startingAt: 3200) { _ in [] }

        XCTAssertEqual(port, 3200)
    }

    func testSkipsOccupiedPorts() async throws {
        let occupied: Set<UInt16> = [3200, 3201]

        let port = try await ServerAutostart.freePort(startingAt: 3200) { candidate in
            occupied.contains(candidate) ? [4242] : []
        }

        XCTAssertEqual(port, 3202)
    }

    func testNamesTheRangeItSearchedWhenEverythingIsTaken() async {
        do {
            _ = try await ServerAutostart.freePort(startingAt: 3200, limit: 3) { _ in [4242] }
            XCTFail("expected a thrown error")
        } catch {
            let message = (error as? SimToolError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("3200–3202"), message)
            XCTAssertTrue(message.contains("--server"), message)
        }
    }

    // A probe that cannot answer (no lsof, a timeout) must not make every port
    // look free — but it must not block the run either. Treat it as occupied and
    // move on, so the worst case is a higher port number.
    func testAFailingProbeSkipsThatPort() async throws {
        let port = try await ServerAutostart.freePort(startingAt: 3200) { candidate in
            if candidate == 3200 { throw SimToolError("lsof failed") }
            return []
        }

        XCTAssertEqual(port, 3201)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Tool --filter ServerAutostartTests`
Expected: compile failure — no `ServerAutostart`.

- [ ] **Step 3: Implement it**

Create `Tool/Sources/SimToolCLI/ServerAutostart.swift`:

```swift
import Foundation
import SimToolCore

/// Starts a server for a command that needs one and was not given one.
///
/// Deliberately unlike `simtool serve`: it never reclaims a port. A user who
/// types `serve --port 3200` has said which port they want; a test run that
/// needs *some* server has not, and killing whoever is on 3200 to get one would
/// be a surprise the caller never asked for.
enum ServerAutostart {
    /// How many ports upward from the configured one to consider.
    static let portSearchLimit = 10

    static func freePort(
        startingAt start: UInt16,
        limit: Int = portSearchLimit,
        probe: (UInt16) async throws -> [Int32] = { try await PortReclaimer.listeningPIDs(port: $0) }
    ) async throws -> UInt16 {
        var candidates: [UInt16] = []
        for offset in 0..<max(1, limit) {
            guard let port = UInt16(exactly: Int(start) + offset) else { break }
            candidates.append(port)
        }
        for port in candidates where ((try? await probe(port)) ?? [1]).isEmpty {
            return port
        }
        throw SimToolError("""
            No free port in \(start)–\(candidates.last ?? start) to start a server on. \
            Start one yourself (`simtool serve --port <free>`) and pass `--server`.
            """)
    }

    // SUPERSEDED BY A RULING DURING EXECUTION. The catch below retries *any*
    // spawn failure on the next port, which the review caught: a test run
    // against an unbooted simulator would spawn three servers before reporting
    // what was actually wrong. The human ruled that the finding governs. The
    // shipped code (392f980) instead extracts a testable `lostThePort(_:probe:)`
    // and rethrows unless the port really was taken — with the probe-cannot-
    // answer case returning false, the deliberate inverse of `freePort`'s
    // pessimism. Read `Tool/Sources/SimToolCLI/ServerAutostart.swift`, not this
    // block, for what the code does.

    /// The session of a server started here, on a port nobody was listening on.
    /// Retries on the next port when the bind loses a race with something that
    /// grabbed it between the probe and the spawn.
    static func start(parameters: ServeParameters, json: Bool) async throws -> SessionInfo {
        var attempt = parameters
        var lastError: Error?
        for _ in 0..<3 {
            attempt.port = try await freePort(startingAt: attempt.port)
            do {
                let session = try await launchDetachedServer(
                    parameters: attempt,
                    app: nil,
                    verbose: false,
                    reclaimPort: false
                )
                emitNote("No SimTool server running — started one on \(session.url)", json: json)
                return session
            } catch {
                lastError = error
                guard attempt.port < UInt16.max else { break }
                attempt.port += 1
            }
        }
        throw lastError ?? SimToolError("Could not start a SimTool server.")
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path Tool --filter ServerAutostartTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A Tool
git commit -m "$(cat <<'EOF'
feat(serve): find a free port instead of taking one

A command that starts a server on its own initiative searches upward from the
configured port and stops at one nobody is listening on, retrying when the
spawn loses a race with something that grabbed it in between. A probe that
cannot answer counts as occupied: the cost is a higher port number, and the
alternative is treating every port as free.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `test run` needs no server of its own

**Files:**
- Modify: `Tool/Sources/SimToolCLI/SimTool.swift` (`TestCommand.ServerOptions`, `TestCommand.Run.run`, the `Run.configuration.discussion`)
- Modify: `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift` (abstract/help assertion)

**Interfaces:**
- Consumes: `ServerAutostart.start(parameters:json:)` (Task 5), `SessionControl.stop(_:)` (Task 4).
- Produces: `TestCommand.ServerOptions.resolveClient(config:json:) async throws -> (SimToolClient, SessionInfo?)`.

- [ ] **Step 1: Add the resolver**

In `TestCommand.ServerOptions`, `test list` must keep resolving a server without
starting one — booting a simulator to print a table would be absurd — so
`client()` stays, and the `--server` branch both methods need is factored out
rather than written twice:

```swift
        /// The client `--server` names, or nil when it was not given.
        private func explicitClient() throws -> SimToolClient? {
            guard let server, !server.isEmpty else { return nil }
            guard let url = URL(string: server) else { throw SimToolError("Invalid server URL: \(server)") }
            return SimToolClient(baseURL: url)
        }

        func client() throws -> SimToolClient {
            if let explicit = try explicitClient() { return explicit }
            guard let session = try SessionStore.shared.latest(), let url = URL(string: session.api) else {
                throw SimToolError("No running SimTool server found. Start one with `simtool serve` or pass --server.")
            }
            return SimToolClient(baseURL: url)
        }

        /// The client a run should use, plus the server this process started for
        /// it. Nil means the server was already there: it belongs to someone
        /// else and must outlive the run.
        func resolveClient(config: ProjectConfig?, json: Bool) async throws -> (SimToolClient, SessionInfo?) {
            if let explicit = try explicitClient() { return (explicit, nil) }
            if let session = try SessionStore.shared.latest(), let url = URL(string: session.api) {
                return (SimToolClient(baseURL: url), nil)
            }
            let started = try await ServerAutostart.start(
                parameters: ServeParameters.resolve(device: nil, host: nil, port: nil, config: config),
                json: json
            )
            guard let url = URL(string: started.api) else {
                await SessionControl.stop(started)
                throw SimToolError("Started a server but its API URL is unreadable: \(started.api)")
            }
            return (SimToolClient(baseURL: url), started)
        }
```

- [ ] **Step 2: Use it, and stop only what it started**

In `TestCommand.Run.run()`, replace `let client = try serverOptions.client()` with:

```swift
            let (client, ownedServer) = try await serverOptions.resolveClient(config: projectConfig, json: common.json)
            var stopOwnedServer: (@Sendable () async -> Void)?
            if let ownedServer {
                let json = common.json
                stopOwnedServer = {
                    await SessionControl.stop(ownedServer)
                    emitNote("Stopped the server it started.", json: json)
                }
                // Ctrl-C during a run must not leave a server and a simulator
                // behind that the user never started and cannot see.
                SignalTrap.shared.installCleanup { await SessionControl.stop(ownedServer) }
            }
```

Wrap everything from the first executor construction to the `throw ExitCode(code)` in a `do`/`catch` that tears the server down on both paths:

```swift
            let report: TestRunReport
            do {
                report = try await Self.execute(
                    test: parsed,
                    file: testURL,
                    client: client,
                    projectConfig: projectConfig,
                    options: self,
                    overrides: overrides
                )
            } catch {
                await stopOwnedServer?()
                throw error
            }
            await stopOwnedServer?()

            if common.json {
                try printJSON(report)
            } else {
                Self.printReport(report, sessionsRoot: projectConfig.map {
                    SimToolDirectory.testSessionsDirectory(in: $0.simtoolDirectory)
                })
            }
            let code = report.verdict.exitCode
            if code != 0 { throw ExitCode(code) }
```

`Self.execute` is the repeat loop moved out verbatim — the `for attempt in 1...repeatCount` block that builds a `TestRunExecutor` per attempt, breaks on `infra`/`cancelled`, and returns `Self.report(for:test:file:)`. Moving it out is what lets one `do`/`catch` cover the whole run without the teardown appearing four times. Its signature:

```swift
        private static func execute(
            test: TestDefinition,
            file: URL,
            client: SimToolClient,
            projectConfig: ProjectConfig?,
            options: Run,
            overrides: [String: String]
        ) async throws -> TestRunReport
```

Note the exit code is thrown *after* the server is stopped: a non-zero verdict is a normal outcome, not a reason to leak a process.

- [ ] **Step 3: Say so in `--help`**

In `Run.configuration.discussion`, after the paragraph about implicit waits, add:

```
            A running SimTool server is not a prerequisite: when there is none,
            the run starts one on a free port and stops it again afterwards. A
            server that was already running is reused and left alone.
```

Update the `abstract` to `"Run a declarative YAML UI test on a simulator, recorded as a test session."` (it no longer requires "the served simulator"), and adjust the corresponding assertion in `SimToolCommandSurfaceTests` if one checks that string.

- [ ] **Step 4: Build and run the suite**

Run: `swift build --package-path Tool && swift test --package-path Tool`
Expected: PASS

- [ ] **Step 5: Verify by hand, three ways**

```bash
# 1. no server: one starts and stops
swift run --package-path Tool simtool kill || true
swift run --package-path Tool simtool test run .simtool/tests/<any>.yml
swift run --package-path Tool simtool sessions --json      # expect: no session left behind

# 2. a server already running: reused, still there afterwards
swift run --package-path Tool simtool serve --detach --json
swift run --package-path Tool simtool test run .simtool/tests/<any>.yml
swift run --package-path Tool simtool sessions --json      # expect: the same session id

# 3. Ctrl-C mid-run with no server: nothing left behind
swift run --package-path Tool simtool kill || true
swift run --package-path Tool simtool test run .simtool/tests/<any>.yml   # ^C after a step or two
swift run --package-path Tool simtool sessions --json
xcrun simctl list devices booted
```

Expected: case 1 prints "started one on …" and "Stopped the server it started."; case 2 prints neither; case 3 leaves no session file and no simulator booted by us.

- [ ] **Step 6: Commit**

```bash
git add -A Tool
git commit -m "$(cat <<'EOF'
feat(test): run a test without a server already running

Being handed a test file and told to run it should not also mean being told
about `simtool serve`. When no server is running the run starts one on a free
port and stops it afterwards, on every exit path including Ctrl-C and a
non-zero verdict; a server that was already there is reused and outlives the
run, because it is not ours.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6b: A run reuses only its own project's server

Added during execution. Verifying Task 6 by hand surfaced it: this machine had a
server running for a different checkout, and `resolveClient` would have reused it
— sending the test to another project's simulator, recording the session into that
project's `.simtool/test-sessions` (the server derives its sessions root from its
own working directory), and reporting a verdict about the wrong app. `client()`
always behaved this way, but a user who typed `simtool serve` knew which server
existed; a run that picks one up silently does not.

**Files:**
- Modify: `Tool/Sources/SimToolCore/SessionStore.swift` (`SessionInfo`)
- Modify: `Tool/Sources/SimToolCLI/SimTool.swift` (`runViewer`, `TestCommand.ServerOptions`)
- Modify: `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift`

**Interfaces:**
- Consumes: `TestCommand.ServerOptions.resolveClient(config:json:)` and
  `ServerAutostart.start(parameters:json:)` from Task 6.
- Produces: `SessionInfo.projectRoot: String?`;
  `TestCommand.ServerOptions.reusableSession(from: [SessionInfo], projectRoot: String?) -> SessionInfo?`

- [ ] **Step 1: Write the failing test**

Add to `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift`:

```swift
    // A server belonging to another checkout drives another simulator and writes
    // its sessions into another project. Reusing it would report a verdict about
    // the wrong app.
    func testAServerFromAnotherProjectIsNotReused() {
        let sessions = [session(id: "other", project: "/Users/x/Workspace/other", at: 200)]

        XCTAssertNil(TestCommand.ServerOptions.reusableSession(from: sessions, projectRoot: "/Users/x/Workspace/mine"))
    }

    func testTheNewestSessionOfThisProjectIsReused() {
        let sessions = [
            session(id: "newest-elsewhere", project: "/Users/x/Workspace/other", at: 300),
            session(id: "mine-new", project: "/Users/x/Workspace/mine", at: 200),
            session(id: "mine-old", project: "/Users/x/Workspace/mine", at: 100),
        ]

        XCTAssertEqual(
            TestCommand.ServerOptions.reusableSession(from: sessions, projectRoot: "/Users/x/Workspace/mine")?.sessionId,
            "mine-new"
        )
    }

    // Two runs outside any project share the "no project" context, which is what
    // the behaviour was before sessions recorded a project at all.
    func testOutsideAnyProjectASessionWithoutOneIsReused() {
        let sessions = [session(id: "rootless", project: nil, at: 100)]

        XCTAssertEqual(TestCommand.ServerOptions.reusableSession(from: sessions, projectRoot: nil)?.sessionId, "rootless")
        XCTAssertNil(TestCommand.ServerOptions.reusableSession(from: sessions, projectRoot: "/Users/x/Workspace/mine"))
    }

    private func session(id: String, project: String?, at seconds: TimeInterval) -> SessionInfo {
        SessionInfo(
            sessionId: id,
            pid: 1,
            device: SimulatorDevice(udid: "UDID", name: "iPhone", state: "Booted", runtime: "iOS 18.2", isAvailable: true),
            url: "http://127.0.0.1:3200",
            api: "http://127.0.0.1:3200/api/v1",
            startedAt: Date(timeIntervalSince1970: seconds),
            projectRoot: project
        )
    }
```

Check `SimulatorDevice`'s initializer before writing the fixture and match its
actual parameter list.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Tool --filter SimToolCommandSurfaceTests`
Expected: compile failure — `SessionInfo` has no `projectRoot`, `ServerOptions`
has no `reusableSession`.

- [ ] **Step 3: Record the project on the session**

In `SessionInfo` add, after `bootedDevices`:

```swift
    /// The project this server serves, so a command in another checkout does not
    /// reuse it: its simulator is another project's, and the sessions it records
    /// land in that project's `.simtool`. Nil when it was started outside one.
    public var projectRoot: String?
```

Thread it through the memberwise initializer (defaulted `nil`, last parameter),
`CodingKeys`, and the custom `init(from:)` with
`decodeIfPresent` — sessions written before this field existed must keep
decoding, exactly as `bootedDevices` does.

`runViewer` is the one place that builds a `SessionInfo`; it already computes the
project root for `StreamServerConfig`, so pass the same value:

```swift
        projectRoot: projectConfig?.simtoolDirectory.deletingLastPathComponent().standardizedFileURL.path
```

- [ ] **Step 4: Reuse only a matching session**

In `TestCommand.ServerOptions`:

```swift
        /// The newest running server that serves `projectRoot`, if any. Compared
        /// as paths rather than by device or port: what makes a server the wrong
        /// one is the project it records sessions into.
        static func reusableSession(from sessions: [SessionInfo], projectRoot: String?) -> SessionInfo? {
            sessions
                .filter { $0.projectRoot == projectRoot }
                .max { $0.startedAt < $1.startedAt }
        }
```

and in `resolveClient`, replace the `SessionStore.shared.latest()` branch:

```swift
            let projectRoot = config?.simtoolDirectory.deletingLastPathComponent().standardizedFileURL.path
            let sessions = (try? SessionStore.shared.list()) ?? []
            if let mine = Self.reusableSession(from: sessions, projectRoot: projectRoot),
               let url = URL(string: mine.api) {
                return (SimToolClient(baseURL: url), nil)
            }
            // Worth saying out loud: the reason a server is running and this run
            // still starts one is not obvious, and the alternative — driving
            // another checkout's simulator — is worse than a second server.
            if let foreign = sessions.first, let elsewhere = foreign.projectRoot {
                emitNote("A SimTool server is running for another project (\(elsewhere)) — starting one for this project instead.", json: json)
            }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path Tool --filter SimToolCommandSurfaceTests`
Expected: PASS. Then the full suite.

- [ ] **Step 6: Commit**

```bash
git add -A Tool
git commit -m "$(cat <<'EOF'
fix(test): reuse a server only when it serves this project

A machine running several checkouts has several servers, and the run took
whichever started last. That sends the test to another project's simulator,
records the session into that project's .simtool, and reports a verdict about
an app the test never drove.

A session now records the project it serves, and a run that finds only foreign
ones says so and starts its own.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: The installer grows an agent axis

**Files:**
- Modify: `Tool/Sources/SimToolCore/AgentSkill.swift` (types and installer; the markdown literal moves out)
- Create: `Tool/Sources/SimToolCore/Skills/SimtoolSkill.swift`
- Modify: `Tool/Sources/SimToolCLI/SimTool.swift` (`Init` at `:1721-1852`, the only caller of the old API together with one surface test)
- Modify: `Tool/Tests/SimToolCoreTests/AgentSkillTests.swift`
- Modify: `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift:70-84`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `AgentSkill(name: String, markdown: String)`, `AgentSkill.simtool`, `AgentSkill.all`
  - `AgentSkillInstaller.Scope` (`local`/`global`/`none`), `.Agent` (`claude`/`codex`), `.Outcome` (`created`/`updated`/`upToDate`/`conflict`), `.Installation` (`skill`, `agent`, `scope`, `outcome`, `path`)
  - `AgentSkillInstaller.directory(skill:agent:scope:projectDirectory:home:) -> URL?`
  - `AgentSkillInstaller.install(skills:agents:scope:projectDirectory:home:force:) throws -> [Installation]`

- [ ] **Step 1: Rewrite the installer's tests**

Replace `Tool/Tests/SimToolCoreTests/AgentSkillTests.swift`. The four fixture helpers (`root`, `project()`, `home()`, setUp/tearDown) stay as they are; the cases become:

```swift
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
```

`Installation` needs `Equatable` for the `== []` assertions; add it to the conformance list.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path Tool --filter AgentSkillTests`
Expected: compile failure — no `AgentSkillInstaller`.

- [ ] **Step 3: Move the document out**

Create `Tool/Sources/SimToolCore/Skills/SimtoolSkill.swift` holding the literal exactly as it is today, moved verbatim:

```swift
extension AgentSkill {
    public static let simtool = AgentSkill(name: "simtool", markdown: simtoolMarkdown)

    /// Mirrored by `skills/simtool/SKILL.md`, which is the copy to edit;
    /// regenerate this with `Scripts/sync-agent-skills.swift`.
    static let simtoolMarkdown = #"""
        ---
        name: simtool
        …the current contents of AgentSkill.markdown, unchanged…
        """#
}
```

- [ ] **Step 4: Rewrite the installer**

`Tool/Sources/SimToolCore/AgentSkill.swift` becomes:

```swift
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

    /// One element for now on purpose: `simtool-test` joins it in the task that
    /// authors it, because `AgentSkillTests` asserts every entry has an
    /// authoring copy under `skills/<name>/SKILL.md` and that file does not
    /// exist yet.
    public static let all: [AgentSkill] = [.simtool]

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

    /// Directory the skill is written into, or `nil` for `.none`. `home` is
    /// injectable so tests never touch the real `$HOME`.
    public static func directory(
        skill: AgentSkill,
        agent: Agent,
        scope: Scope,
        projectDirectory: URL,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
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
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
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
                let path = destination.standardizedFileURL.path
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
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --package-path Tool --filter AgentSkillTests`
Expected: PASS

- [ ] **Step 6: Teach `init` the second axis**

In `Tool/Sources/SimToolCLI/SimTool.swift`, `struct Init`:

```swift
    @Option(
        name: .long,
        help: "Install the agent skills: `local` (this project), `global` (all projects, under $HOME), or `none`. Omit to be asked interactively; non-interactive runs default to `none`."
    )
    var skill: AgentSkillInstaller.Scope?

    @Option(
        name: .long,
        help: "Whose skills layout to write: `claude` (.claude/skills), `codex` (.codex/skills), or `both`. Only used when skills are installed."
    )
    var skillAgent: SkillAgentOption = .claude
```

`InitResult.skill` becomes `var skills: [AgentSkillInstaller.Installation]`, and the install call:

```swift
        let scope = resolveSkillScope()
        let installations = try AgentSkillInstaller.install(
            agents: scope == .none ? [] : resolveSkillAgents(),
            scope: scope,
            projectDirectory: cwd,
            force: force
        )
```

The guard, the `--force` semantics and the "already exists" message keep their shape; `skill == nil || skill == .none` still decides whether there is nothing to do.

The interactive resolution becomes two prompts, and the second is only reached when the first installed something:

```swift
    /// The explicit `--skill`, else an interactive pick. Non-interactive runs
    /// install nothing: `init` is scriptable, and `global` writes outside the
    /// project, which must never happen without the user saying so.
    private func resolveSkillScope() -> AgentSkillInstaller.Scope {
        if let skill { return skill }
        guard !common.json, isatty(STDIN_FILENO) != 0 else { return .none }
        return makeNoora().singleChoicePrompt(
            title: "Agent skills",
            question: "Install the simtool agent skills?",
            options: SkillChoice.allCases,
            description: "Teaches a coding agent to build, launch, drive and mock your app with simtool, and to write UI tests that verify a bug or a feature."
        ).scope
    }

    /// Asked only when a scope was chosen interactively: someone who passed
    /// `--skill` and no `--skill-agent` gets the default rather than a prompt,
    /// so scripted runs stay scripted.
    private func resolveSkillAgents() -> [AgentSkillInstaller.Agent] {
        guard skill == nil, !common.json, isatty(STDIN_FILENO) != 0 else { return skillAgent.agents }
        return makeNoora().singleChoicePrompt(
            title: "Coding agent",
            question: "Which agent should read them?",
            options: SkillAgentOption.allCases,
            description: "The same documents, in each agent's own skills directory."
        ).agents
    }
```

with the prompt-facing option type next to `SkillChoice`:

```swift
enum SkillAgentOption: String, CaseIterable, CustomStringConvertible, ExpressibleByArgument, Equatable {
    case claude, codex, both

    var agents: [AgentSkillInstaller.Agent] {
        switch self {
        case .claude: [.claude]
        case .codex: [.codex]
        case .both: [.claude, .codex]
        }
    }

    var description: String {
        switch self {
        case .claude: "Claude Code (.claude/skills)"
        case .codex: "Codex (.codex/skills)"
        case .both: "Both"
        }
    }
}
```

And `extension AgentSkillInstaller.Scope: ExpressibleByArgument {}` replaces the old `AgentSkill.Scope` one. `SkillChoice.description` loses the parenthetical directory names, which now belong to the agent question:

```swift
        var description: String {
            switch self {
            case .local: return "This project only"
            case .global: return "All projects (under $HOME)"
            case .skip: return "Don't install"
            }
        }
```

Takeaways become one line per installation:

```swift
    private func skillTakeaways(_ installations: [AgentSkillInstaller.Installation]) -> [String] {
        guard !installations.isEmpty else { return ["Skills: not installed"] }
        return installations.map { installation in
            let verb = switch installation.outcome {
            case .created: "installed"
            case .updated: "updated"
            case .upToDate: "already up to date"
            case .conflict: "kept your edited copy (pass --force to replace it)"
            }
            return "\(installation.skill): \(verb) at \(installation.path)"
        }
    }
```

and the todo fires when the `simtool` skill in particular landed, since it is the one with placeholders to fill:

```swift
        if installations.contains(where: { $0.skill == AgentSkill.simtool.name && ($0.outcome == .created || $0.outcome == .updated) }) {
            todos.append("Fill in the skill's project options and launch-argument catalog for this app.")
        }
```

The `headline` for a skills-only run becomes `"Installed the simtool agent skills"`.

- [ ] **Step 7: Update the `init` parse tests**

In `SimToolCommandSurfaceTests`:

```swift
    func testInitParsesTheSkillScopeAndAgent() throws {
        XCTAssertEqual(try Init.parse(["--skill", "local"]).skill, .local)
        XCTAssertEqual(try Init.parse(["--skill", "global"]).skill, .global)
        XCTAssertEqual(try Init.parse(["--skill", "none"]).skill, AgentSkillInstaller.Scope.none)
        XCTAssertThrowsError(try Init.parse(["--skill", "everywhere"]))

        XCTAssertEqual(try Init.parse([]).skillAgent, .claude)
        XCTAssertEqual(try Init.parse(["--skill-agent", "codex"]).skillAgent, .codex)
        XCTAssertEqual(try Init.parse(["--skill-agent", "both"]).skillAgent.agents, [.claude, .codex])
        XCTAssertThrowsError(try Init.parse(["--skill-agent", "cursor"]))
    }
```

keeping `testInitDefaultsToNoSkillChoice` as it is.

- [ ] **Step 8: Build and run the suite**

Run: `swift build --package-path Tool && swift test --package-path Tool`
Expected: PASS

- [ ] **Step 9: Verify the two prompts by hand**

```bash
mkdir -p /tmp/init-check && cd /tmp/init-check
swift run --package-path ~/Workspace/SimTool/Tool simtool init
```

Expected: the scope question, then the agent question, then the files in the chosen layout. `simtool init --skill local --json` in a second empty directory prints `skills` as an array and asks nothing.

- [ ] **Step 10: Commit**

```bash
git add -A Tool
git commit -m "$(cat <<'EOF'
feat(init): install skills into Claude Code's or Codex's layout

The installer grows a second axis. Both agents read the same
`<root>/<agent>/skills/<name>/SKILL.md`, so one document serves either and the
choice is only where to write it — `claude` by default, because writing into
~/.codex for someone who does not use Codex is noise.

The `simtool` document moves into its own file: the installer is worth reading
without scrolling past five hundred lines of Markdown, and a second skill is
about to land next to it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Stop hand-carrying the skill documents

**Files:**
- Create: `Scripts/sync-agent-skills.swift`

**Interfaces:**
- Consumes: `AgentSkill.all`'s naming convention — `skills/<name>/SKILL.md` ↔ `Tool/Sources/SimToolCore/Skills/<Pascal>Skill.swift` with properties `<camel>` and `<camel>Markdown`.
- Produces: a script the next task and every future skill edit runs.

- [ ] **Step 1: Write the script**

Create `Scripts/sync-agent-skills.swift`:

```swift
#!/usr/bin/env swift
import Foundation

// Regenerates the shipped Swift literals from the authoring copies:
//
//   skills/<name>/SKILL.md  →  Tool/Sources/SimToolCore/Skills/<Pascal>Skill.swift
//
// AgentSkillTests asserts the two are identical, but a test that only reports
// drift after the fact is not the same as not drifting. Run this after editing
// any SKILL.md, from the repository root:
//
//   swift Scripts/sync-agent-skills.swift

let indent = String(repeating: " ", count: 8)

func camelCase(_ name: String) -> String {
    let parts = name.split(separator: "-")
    return (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.capitalized }.joined()
}

func pascalCase(_ name: String) -> String {
    name.split(separator: "-").map { $0.capitalized }.joined()
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
let outputRoot = root.appendingPathComponent("Tool/Sources/SimToolCore/Skills", isDirectory: true)

guard let names = try? FileManager.default.contentsOfDirectory(atPath: skillsRoot.path).sorted(), !names.isEmpty else {
    FileHandle.standardError.write(Data("No skills/ directory here. Run this from the repository root.\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

for name in names {
    let source = skillsRoot.appendingPathComponent(name).appendingPathComponent("SKILL.md")
    guard let markdown = try? String(contentsOf: source, encoding: .utf8) else { continue }
    // The raw literal's own delimiter cannot appear inside it, and quietly
    // producing a file that does not compile is worse than stopping.
    guard !markdown.contains("\"\"\"#") else {
        FileHandle.standardError.write(Data("\(name): SKILL.md contains the literal's closing delimiter.\n".utf8))
        exit(1)
    }
    // Every line indented to the closing delimiter's column, which Swift then
    // strips: that is what makes the literal equal the file byte for byte.
    let body = markdown
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : indent + $0 }
        .joined(separator: "\n")
    let property = camelCase(name)
    let contents = """
        extension AgentSkill {
            public static let \(property) = AgentSkill(name: "\(name)", markdown: \(property)Markdown)

            /// Mirrored by `skills/\(name)/SKILL.md`, which is the copy to edit;
            /// regenerate this with `Scripts/sync-agent-skills.swift`.
            static let \(property)Markdown = #\"\"\"
        \(body)
        \(indent)\"\"\"#
        }

        """
    let destination = outputRoot.appendingPathComponent("\(pascalCase(name))Skill.swift")
    try Data(contents.utf8).write(to: destination, options: [.atomic])
    print("\(name) → \(destination.lastPathComponent) (\(markdown.count) chars)")
}
```

- [ ] **Step 2: Run it and confirm it reproduces what is already committed**

```bash
chmod +x Scripts/sync-agent-skills.swift
swift Scripts/sync-agent-skills.swift
git diff --stat
```

Expected: `simtool → SimtoolSkill.swift (…)` printed, and `git diff` empty. If the diff is non-empty, the generator's shape and the hand-written file disagree — fix the generator until it reproduces the committed file, not the other way round, unless the difference is only the doc comment above the property (in which case take the generator's).

- [ ] **Step 3: Confirm the build and the sync test still agree**

Run: `swift build --package-path Tool && swift test --package-path Tool --filter AgentSkillTests`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add -A Scripts Tool
git commit -m "$(cat <<'EOF'
chore(skills): generate the shipped literals from the authoring copies

With one skill the hand-carry was survivable. With two it is a guaranteed
drift, and the sync test only reports drift after the fact.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: The `simtool-test` skill

**Files:**
- Create: `skills/simtool-test/SKILL.md`
- Create (generated): `Tool/Sources/SimToolCore/Skills/SimtoolTestSkill.swift`
- Modify: `skills/simtool/SKILL.md` and its generated `SimtoolSkill.swift`
- Modify: `Tool/Sources/SimToolCore/AgentSkill.swift` (`all`)

**Interfaces:**
- Consumes: `AgentSkill`, the generator from Task 8.
- Produces: `AgentSkill.simtoolTest`, and `AgentSkill.all == [.simtool, .simtoolTest]`.

- [ ] **Step 1: Author `skills/simtool-test/SKILL.md`**

Frontmatter verbatim:

```yaml
---
name: simtool-test
description: Write a declarative YAML UI test for an iOS app and drive the red→green loop with it — encode a reported bug or an unbuilt feature as a test that asserts the *expected* behaviour, run it with `simtool test run` (whose exit code is the verdict: 0 satisfied, 1 unsatisfied, 2 inconclusive, 3 infra), change the product, and re-run the same file as the regression guard. Covers the test file format (launch profiles, state reset, in-test backend mocks, criteria), finding element ids, reading the evidence a run leaves behind, and handing a test to another developer or agent. Use when asked to reproduce a bug on the simulator, prove a bug exists before fixing it, write a repro test, write a test for acceptance criteria before the feature exists, verify a fix, or share a test — "напиши тест на баг", "воспроизведи баг тестом", "докажи что баг есть", "тест на ожидаемое поведение фичи", "сделай по TDD", "проверь что починилось", "передай тест другому разработчику".
argument-hint: [a bug report, acceptance criteria, or a path to an existing test]
allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
---
```

Then, in this order:

1. `# Verifying tests for an iOS app (via simtool)` — one paragraph on what a
   verifying test is: a YAML file that stages a scenario and asserts a claim, run
   from the CLI or the viewer, recorded with video and evidence. Install line:
   `brew tap mstroshin/simtool && brew trust mstroshin/simtool && brew install simtool`.
2. `## The rule that governs both loops` — **assert the expected behaviour,
   never the current broken one.** A repro fails today, and that failure *is* the
   reproduction; the same file starts passing when the defect is fixed, so it
   becomes the regression guard. A test that asserts the broken state has to be
   inverted after the fix, and inverted tests get deleted.
3. `## A reported bug` — the loop as numbered steps: read the report and, if
   anything about the account or the environment is unstated, ask with
   `AskUserQuestion` rather than guessing → drive the app by hand to find the ids
   → write the test with `kind: bug` and one `criterion:` → run → expect
   `unsatisfied` (exit 1); `satisfied` means the report is wrong, the scenario is
   not staged as described, or you are on a different build → fix the product →
   re-run → `satisfied`. Keep the file.
4. `## A feature that does not exist yet` — one `criterion:` label per
   acceptance item, `kind: feature`, red before the work, green after, and the
   note that one run reports every criterion.
5. `## Before the first run` — a booted simulator (`xcrun simctl boot` / open
   Simulator.app; simtool boots nothing itself), the app installed — the build
   you intend to judge — and `.simtool/config.yml`. State explicitly that no
   `serve` step is needed: `test run` starts a server when none is running and
   stops it afterwards.
6. `## The file` — the full YAML schema as a commented example (the same shape
   as `simtool test run --help`, which is named as the source of truth because
   flags move between versions), followed by target semantics (`id` exact
   accessibilityIdentifier, `label` exact label/title, `text` case-insensitive
   substring, a bare string means `text`) and the note that every step polls, so
   tests need no sleeps.
7. `## Staging the scenario` — environment, account, country and the rest are
   the *app's own* launch arguments; simtool knows nothing about them and must
   not. Inline in `launch.arguments` is the simple option and the default advice
   (argv reaches `simctl` as separate elements, so spaces need no escaping). A
   named `profiles:` entry from `.simtool/config.yml` plus `variables:` is for a
   recipe shared by several tests, or a value needed twice (a `setup:` launch and
   the run's own). A real credential stays in the shell: refer to it as `${VAR}`
   and define it nowhere — the run stops before touching the simulator and names
   what to export. Resolution order `--var` → `variables:` → environment, and why
   the file beats the environment. `reset:` replaces hand-written state-clearing
   shell and travels with the test; `permissions:` pre-answers the system alerts
   that would otherwise block the drive, because `simtool input` cannot reach a
   system alert and while one is up the a11y tree is unreadable — which reads
   exactly like a broken app. The notification prompt has no simctl backdoor.
   `setup:` is the escape hatch for what `reset:` cannot express; non-zero exits
   are recorded, never fatal, and a machine-specific path in there is what stops
   a test from travelling.
8. `## Finding the ids` — `simtool ax find <needle>`, `simtool ax tree --flat
   --labeled`, while driving the app with `simtool input`. Prefer `id`, then
   `label`, then `text`.
9. `## Mocks belong in the test` — declared in `mocks:`, applied before launch,
   the run waits until the app confirms it has them, and existing rules are cleared
   first (not at the end — verified against TestRunExecutor during execution), so the
   scenario reproduces on another machine. `strict: true` makes a rule that never
   fired an `infra` run instead of a quiet pass against the real backend. Use
   `simtool mock set` while exploring, then move what worked into the test. Unary
   gRPC only; a `body:` that does not decode into the method's response type is
   ignored and the real backend answers.
10. `## Verdicts` — the four-row table (`satisfied`/`unsatisfied`/
    `inconclusive`/`infra` × `bug`/`feature`) and what to do with each:
    `inconclusive` and `infra` mean fix the test, not the product; `--repeat N`
    for an intermittent claim, because a defect that passes once looks fixed.
11. `## What the run leaves behind` — the session directory listing
    (`report.md`, `video.mp4`, `logs.jsonl`, `network.jsonl`, `state.jsonl`,
    `mocks.json`, `failure-step-<n>.png` and `-ax.txt`), that `report.md` is
    written regardless of `--evidence`, and that step entries carry log-cursor
    ranges plus start/end timestamps so one step's logs and requests can be
    sliced out. The viewer's Tests tab: Run buttons and live progress, History
    with the timeline synced to the video.
12. `## Handing it on` — send the YAML; attach `report.md` and `video.mp4` when
    they help. The receiver needs `simtool`, a booted simulator, their own build
    of the app, and any `${VAR}` the test does not define. Do not send the
    evidence files outside the team: they hold the account's real traffic and log
    output. Their run against their build is the run that matters to them.
13. `## Anti-patterns` — a table of the mistake and what to do instead:
    `wait: 5` where `waitFor` belongs; a `criterion:` on a staging step (only
    assertions may carry one, and a failure without a criterion is
    `inconclusive`); asserting the broken state; `simtool mock set` instead of
    `mocks:`; no `kind:`, which throws away the verdict; an absolute path or a
    personal account in `setup:`.

Constraints while writing: no bundle id, scheme, workspace, environment name,
account or tracker key from any real project — `com.example.myapp`,
`MyApp.xcworkspace`, `+34600000000`, `PROJ-42` are the placeholders in use.
Do not reproduce simtool's flag tables; point at `--help`.

- [ ] **Step 2: Trim the `simtool` skill**

In `skills/simtool/SKILL.md`:
- Delete the `#### Handing the test to whoever comes next` section entirely.
- Shrink `### UI tests (simtool test run)` to two paragraphs: what a YAML test
  is, that runs are recorded as reviewable sessions under
  `.simtool/test-sessions/<id>/` with a `report.md` and a video, and the
  commands (`simtool test run <file>`, `--json`, `--repeat`, `--evidence`,
  `--no-session`, `simtool test list`). Then: **to write one, or to run the
  bug/feature loop, use the `simtool-test` skill** — it owns the file format,
  the criteria and the verdicts.
- Delete the `#### Verifying tests: kind, criterion and the verdict` and
  `#### Evidence` subsections (they move to `simtool-test`), keeping the
  `#### Reading live model state (@SimToolDebugState)` subsection where it is.
- In the frontmatter `description`, drop "and package a test with its verdict
  and evidence into one archive to hand to whoever comes next (simtool test
  export / show / run <archive>)" and the "hand a test and its proof to someone
  else" trigger phrases; replace with "write or run declarative YAML UI tests
  (see the `simtool-test` skill for writing one and for the bug/feature loop)".
- In `## Notes`, the last sentence of the `.simtool/` bullet ("Because the
  directory is gitignored, a test and its session are machine-local: `simtool
  test export` is how one leaves the machine…") becomes: "Because the directory
  is gitignored, a test travels as a file: send the YAML, and the session's
  `report.md` or `video.mp4` when they help."

- [ ] **Step 3: Generate the literals and register the new skill**

```bash
swift Scripts/sync-agent-skills.swift
```

In `Tool/Sources/SimToolCore/AgentSkill.swift`:

```swift
    public static let all: [AgentSkill] = [.simtool, .simtoolTest]
```

- [ ] **Step 4: Run the suite**

Run: `swift build --package-path Tool && swift test --package-path Tool`
Expected: PASS. `AgentSkillTests.testEverySkillIsAValidSkillDocument` catches a
frontmatter `name` that does not match the directory; `testNoSkillCarriesProjectSpecificIdentifiers`
catches a leaked identifier; `testEverySkillMatchesItsRepositoryCopy` catches a
literal you forgot to regenerate.

- [ ] **Step 5: Install into a scratch directory and read it back as an agent would**

```bash
mkdir -p /tmp/skill-check && cd /tmp/skill-check
swift run --package-path ~/Workspace/SimTool/Tool simtool init --skill local --skill-agent both
find . -name SKILL.md
```

Expected: four files — `.claude/skills/{simtool,simtool-test}/SKILL.md` and the
same two under `.codex/skills/`. Read `simtool-test/SKILL.md` end to end and
check that someone with no context could follow the bug loop from it without
opening the SimTool repository.

- [ ] **Step 6: Commit**

```bash
git add -A skills Tool
git commit -m "$(cat <<'EOF'
feat(skills): a skill for writing a test and driving it red to green

The loop this tool exists for was written down nowhere: a task arrives, an
agent writes a test asserting the behaviour that *should* hold, the test is
red, the product changes, the test goes green and stays as the regression
guard. `simtool-test` owns that loop, the file format, the criteria and the
verdicts; `simtool` keeps build, launch, drive, mock and inspect, and points
at its sibling.

Splitting them also splits the triggers. One skill answering to both "build
and run the app" and "write a test for this bug" was answering neither
precisely.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: The README says what the tool now does

**Files:**
- Modify: `README.md:100-195` (the tests and sessions section) and the project-config section's `init` paragraph

**Interfaces:**
- Consumes: everything above.
- Produces: nothing code-facing.

- [ ] **Step 1: Rewrite `#### Handing a test on` as `#### Sharing a test`**

Replace the whole section (README.md:164-194, ending before the `ax tree` paragraph) with:

```markdown
#### Sharing a test

The test is the artifact. It carries everything needed to stage its scenario, so
sending the `.yml` file is the whole handoff — to the agent that will fix the
bug, to a reviewer, to whoever tests the fix:

```bash
swift run simtool test run .simtool/tests/my-test.yml     # on the receiving side
```

Attach the two files next to the run when they help: `report.md` — the run
written for a person, with the claim, the verdict, the timeline and what the
receiver has to supply — and `video.mp4`.

What the receiver needs: `simtool`, a booted simulator, their own build of the
app (which is the point when verifying a fix), and any `${VAR}` the test refers
to without defining. A test that defines its `variables:` travels ready-to-run;
anything it leaves to the shell is checked before the simulator is touched, so a
missing account fails in a second rather than mid-run. `--var NAME=value`
overrides a value the test does define.

Do not forward the evidence files outside the team: `logs.jsonl` and
`network.jsonl` hold the real traffic and log output of the account the run used.
`report.md` says so too.
```

- [ ] **Step 2: Add `report.md` to the evidence paragraph and the autostart to the intro**

In `#### Evidence`, after the sentence listing `logs.jsonl`, `network.jsonl`,
`state.jsonl`, `mocks.json` and the failure screenshot, add:

```markdown
Every recorded run also writes `report.md` — the same run rendered for a person —
regardless of `--evidence`, which controls captures rather than that.
```

In `### Tests and sessions`, after the code block, add:

```markdown
A running server is not a prerequisite: when none is running, `test run` starts
one on a free port and stops it again afterwards. One that was already running is
reused and left alone.
```

- [ ] **Step 3: Document the skills in the project-config section**

Wherever `simtool init` is described, state that it can also install the two
bundled agent skills — `simtool` (build, launch, drive, mock, inspect) and
`simtool-test` (write a verifying test and drive it red to green) — with
`--skill local|global|none` choosing the tree and `--skill-agent
claude|codex|both` choosing the layout (`.claude/skills` or `.codex/skills`).
Note that a skill you edited is never overwritten without `--force`, because the
`simtool` skill has two sections you are expected to fill in for your app.

- [ ] **Step 4: Read the whole section back**

Run: `grep -n "simflow\|test export\|test show" README.md`
Expected: no matches.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: sharing a test is sending the file

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification of the whole plan

After Task 10:

```bash
swift build --package-path Tool
swift test --package-path Tool
grep -rn "simflow\|TestFlowArchive\|TestFlowManifest" --include="*.swift" --include="*.md" . | grep -v '^\./\.build\|^\./Tool/\.build\|^\./docs/superpowers'
```

Expected: build and tests pass, and the grep returns nothing outside the spec and
plan documents.

Then, against a booted simulator and a project with a `kind: bug` test:

```bash
swift run --package-path Tool simtool kill || true
swift run --package-path Tool simtool test run .simtool/tests/<bug>.yml ; echo "exit $?"
cat .simtool/test-sessions/<id>/report.md
```

Expected: exit 1 with "Bug reproduced", a `report.md` whose "Re-running this"
section names what a receiver supplies, and no leftover session or simulator.
