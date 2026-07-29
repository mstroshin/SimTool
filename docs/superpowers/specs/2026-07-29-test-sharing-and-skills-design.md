# Sharing a test as a file, and teaching agents to write one

Date: 2026-07-29

## Why

A verifying test exists so that someone else re-runs it: the agent that fixes the
bug, a reviewer, whoever tests the fix. The current answer to "someone else" is
`simtool test export` — a `*.simflow.zip` carrying the test, a manifest, a report
and the run's evidence, plus `test show` to read one and `test run <archive>` to
run one.

That is more machinery than the job needs. The thing worth handing over is the
YAML test: it already carries everything needed to stage its scenario, it is
readable, it is diffable, and a person can send it in a chat message. The video
is worth attaching sometimes, and the report is worth attaching sometimes; both
are files in a directory the run already writes.

So: the archive goes, the report survives as a file next to the run, and the
handoff becomes "send the YAML, and the video if it helps".

The second half of the work is that neither the format nor the loop it serves is
taught anywhere. `simtool init` installs one skill covering ten subjects, of
which tests are one section. The loop this tool was built for — a task arrives,
an agent writes a test that asserts the expected behaviour, the test is red, the
product is changed, the test goes green — is written down nowhere. It becomes its
own skill.

## Scope

Four parts, in this order:

1. Remove the archive; write `report.md` into the session directory; check
   unresolved `${VAR}` before the simulator is touched.
2. `simtool test run` starts its own server when none is running, and stops only
   the one it started.
3. Split the bundled skill in two — `simtool` and `simtool-test` — and let
   `simtool init` install either into Claude Code's or Codex's skills layout.
4. Documentation and test coverage for all of the above.

Out of scope: any new YAML key. A test's environment, account and country are the
app's own launch arguments, and SimTool must keep knowing nothing about them —
they are expressed inline in `launch.arguments`, or by naming a `profiles:` entry
from `.simtool/config.yml` and parameterising it through `variables:`. The
`simtool-test` skill teaches that; the parser does not change.

---

## Part 1 — the archive goes, the report stays

### Removed

| Path | Note |
|---|---|
| `Tool/Sources/SimToolCore/TestFlowArchive.swift` | `TestFlowManifest` and `TestFlowArchive` |
| `Tool/Sources/SimToolCLI/TestFlowCommands.swift` | the whole file; see "moved" below |
| `Tool/Tests/SimToolCoreTests/TestFlowArchiveTests.swift` | |
| `Tool/Tests/SimToolCLITests/TestFlowCommandTests.swift` | |

Within `TestFlowCommands.swift` the deleted types are `TestCommand.Export`,
`TestCommand.Show`, `PreparedTest`, `TestSourceLoader` (including
`rebuiltProfile`) and `BuildDrift`. `TestCommand.configuration.subcommands`
becomes `[Run.self, List.self]`.

`emitNote(_:json:)` moves to `Tool/Sources/SimToolCLI/CLITerminal.swift` — it is
called from `SimTool.swift` and Part 2 gives it more callers. `formatBytes(_:)`
has no caller outside the removed code and is deleted with it.

`TestCommand.Run` loses `prepared`/`manifest` handling: it loads the test with
`TestDefinitionParser.load(contentsOf:)` again, and `Self.buildDrift` goes with
`BuildDrift`.

One capability goes with `test show --import`: replaying *someone else's run* in
this project's viewer. After this change a receiver re-runs the YAML and gets
their own session, which is the run that matters to them anyway — theirs is
against their build.

`SimToolCommandSurfaceTests` drops its `export`/`show` cases and asserts
`["run", "list"]`.

### `TestReportRenderer` renders a session

New entry point, in place of the manifest-shaped one:

```swift
public static func render(session: TestSession, definition: TestDefinition?) -> String
```

Everything the sections need is already on `TestSession` — `kind`, `reference`,
`verdict`, `criteria`, `mocks`, `evidence`, `entries`, `provenance`, the video
duration. From the definition it needs `description` (not recorded on the
session) and `variables` (to say what a receiver has to supply). The definition
is optional so a report can still be rendered for a session whose test file is
gone.

Section changes:

- **Heading** — `definition?.name ?? session.title`.
- **Verdict paragraph** — unchanged for a verdict; for a session without one
  (plain pass/fail test) it states `session.status` instead of "this archive
  carries a test that has not been run".
- **Facts table** — the `Packaged` row goes (nothing is being packaged); `Recorded`
  keeps `session.startedAt` and `provenance.simtoolVersion`.
- **The claim**, **Mocked backend**, **Timeline** — unchanged.
- **Evidence** — the file table stays, but the paragraph naming
  `runs/<session>/` is replaced by the session directory's own name: these files
  are in the same directory as the report.
- **Re-running this** — now describes re-running from the YAML: `simtool`, a
  booted simulator, the app installed (the receiver's own build), and the
  `${VAR}` the test refers to without defining. The `simtool serve --detach` line
  in the snippet goes away because Part 2 makes it unnecessary; the snippet
  becomes the `export` lines for undefined variables plus
  `simtool test run <file>`. The exit-code sentence stays. The paragraphs about
  the archive's recorded launch standing in for a missing profile, and about
  `requires.carries`, go.
- **Before you forward this** — kept, minus `--no-evidence` (the receiver of a
  YAML gets no evidence unless the sender attaches it): `logs.jsonl`,
  `network.jsonl` and `state.jsonl` hold the real traffic and log output of the
  account the run used, so they are team-internal; and a `variables:` value
  written inline travels wherever the file travels.
- **What is not here** — goes with `manifest.notes`.

`prettyRuntime`, the `Markdown` builder and the private helpers are untouched.

### Where the report is written

`TestRunExecutor` gains a `sessionDirectory: URL?`, set whenever
`options.recordSession` is on and the server reports a `testSessionsPath` —
independent of `options.evidence`, which currently gates `evidenceDirectory`. A
report is not evidence; it is the one artifact written for a person, and
`--evidence none` should not remove it.

After `stopSession(...)` returns the stopped session — that response already
carries the finalized `videoDurationSeconds`, which the timeline needs to scale
step offsets onto real video time — the executor writes

```
.simtool/test-sessions/<id>/report.md
```

atomically. `report.md` is **not** appended to `session.evidence`: that list is
what the run captured, and the report is a reading of it. A write failure is
recorded as a run note, never as a failure of the test.

The same path runs for viewer-triggered runs, because the server's
`TestRunController` drives the same executor.

For a testable seam the write itself lives in Core:

```swift
public enum TestReportWriter {
    @discardableResult
    public static func write(
        session: TestSession,
        definition: TestDefinition?,
        into directory: URL
    ) throws -> URL
}
```

`--no-session` writes nothing (there is no directory). `--repeat N` writes one
report per session, since each run is its own session.

### CLI output

`TestCommand.Run.printReport` currently ends with `Session: <id>` per session.
It gains the directory, so the video and the report are one copy-paste away:

```
  Session: 2026-07-29-1436-a1b2c3
           .simtool/test-sessions/2026-07-29-1436-a1b2c3 — report.md, video.mp4
```

The path is printed relative to the working directory when it is inside it, and
absolute otherwise. `--json` output is unchanged: `TestRunReport.sessions`
already carries the ids, and the directory is derivable.

### Unresolved `${VAR}`, before the simulator is touched

The archive flow checked this and the plain-YAML flow does not: today an
undefined `${ACCOUNT}` surfaces from `LaunchVariables.expand` in the middle of
the launch, after boot, reset and mocks — and a name referenced only from a
`setup:` command never surfaces at all, because the shell expands it to an empty
string.

Now that a YAML file travels on its own, the receiver missing a variable is the
normal case, so the check moves into `test run` for every test:

```swift
extension LaunchVariables {
    /// Names referenced where SimTool substitutes: the resolved launch
    /// (profile argv/env/deeplink plus the test's inline ones) and the setup
    /// commands, which receive the variables as shell environment.
    public static func names(in launch: ResolvedLaunch, setup: [String]) -> [String]
}
```

Deliberately not a scan of the raw YAML text (what `TestFlowArchive.requirements`
did): `${...}` inside a mock body is literal data and must not become a demand on
the receiver.

`TestCommand.Run` runs the check after parsing the test and resolving the profile
from `.simtool/config.yml`, and **before** it resolves a client — so a test that
cannot run does not cause a server to be started:

```
The test refers to ACCOUNT without defining it — usually the account it runs as.
Export it, pass `--var ACCOUNT=…`, or add it under `variables:` in the test.
```

Plural when several. `LaunchVariables.expand` keeps its own error for anything
that slips past.

The same helper feeds the report's "Re-running this" section, filtered by
`definition.variables` rather than by the process environment: what the sender
happened to have exported is not what the receiver needs to know.

---

## Part 2 — `test run` starts its own server

Today `test run` needs a server already running (`simtool serve`, `simtool run`,
or `--server`), which is the first thing a receiver of a test file hits.

### Reusable pieces

`launchDetachedServer` already spawns a background `serve --detached-child` and
waits for it to report a session. It changes shape:

```swift
func launchDetachedServer(
    parameters: ServeParameters,
    app: String?,
    verbose: Bool,
    reclaimPort: Bool = true
) async throws -> SessionInfo
```

It returns the session instead of printing it; `serve --detach` does the
printing. `reclaimPort: false` forwards a hidden `--no-reclaim` to the child.

`Kill`'s teardown — SIGTERM, wait up to six seconds, then SIGKILL plus
`SimulatorDeviceClient.shutdown` for every UDID in `session.bootedDevices`, then
drop the session file — moves to `SessionControl.stop(_ session: SessionInfo)
async` and is used by both `Kill` and the autostart teardown.

### Resolution order in `TestCommand.ServerOptions`

```swift
func resolveClient(config: ProjectConfig?) async throws -> (SimToolClient, SessionInfo?)
```

1. `--server` given → that URL, nothing owned.
2. A live session in `SessionStore` → its API, nothing owned.
3. Otherwise start one, and return it as owned.

`TestCommand.List` keeps the existing `client()` and its "no running SimTool
server found" error: listing recorded sessions must not boot a simulator.

The autostart takes `device`, `host` and `port` from `ServeParameters.resolve`,
i.e. the same `.simtool/config.yml` values `serve` uses, so the test runs against
the project's configured simulator.

### Never reclaim a port implicitly

`runViewer` reclaims an occupied port by SIGTERM/SIGKILLing whoever holds it.
That is a defensible thing to do when a user typed `serve --port 3200`; it is not
something `test run` may do on its own — port 3200 could be somebody's dev
server.

So the autostart finds a free port instead:

```swift
enum ServerAutostart {
    /// The first port from `start` upward with no listener, probing at most
    /// `limit` candidates.
    static func freePort(
        startingAt start: UInt16,
        limit: Int = 10,
        probe: (UInt16) async throws -> [Int32] = { try await PortReclaimer.listeningPIDs(port: $0) }
    ) async throws -> UInt16
}
```

The probe is injected so this is unit-testable without opening sockets. The
spawned child gets `--no-reclaim`, which makes `runViewer` throw on
`EADDRINUSE` rather than kill; the autostart then advances to the next candidate,
up to three spawn attempts. When no candidate is free:

```
No free port in 3200–3209 to start a server on. Start one yourself
(`simtool serve --port <free>`) and pass `--server`.
```

A live simtool session on the configured port is found in step 2 and never
reaches this.

### Teardown

The run stops an owned server on every exit path — success, verdict failure,
thrown error, cancellation — with the same guard the executor already uses for
detached work, so a cancelled task can still make the HTTP calls. A server we
did not start is never touched.

Notes, on stderr under `--json`:

```
No SimTool server running — started one on http://127.0.0.1:3200
Stopped the server it started.
```

### Sequencing

The autostart happens after the `${VAR}` check and after the test parses, and the
child may need up to `ensureBooted`'s budget to boot the simulator, which the
existing 330-second poll already covers.

---

## Part 3 — two skills, two agent layouts

### File layout

```
Tool/Sources/SimToolCore/AgentSkill.swift                 types + installer
Tool/Sources/SimToolCore/Skills/SimtoolSkill.swift        the `simtool` literal
Tool/Sources/SimToolCore/Skills/SimtoolTestSkill.swift    the `simtool-test` literal
skills/simtool/SKILL.md                                   authoring copies,
skills/simtool-test/SKILL.md                              kept in sync by tests
```

Splitting the literals out keeps `AgentSkill.swift` about installation; two
500-line raw string literals in the file that also holds the install logic would
bury it.

### Types

```swift
public struct AgentSkill: Sendable, Equatable {
    public let name: String        // directory name: "simtool", "simtool-test"
    public let markdown: String

    public static let simtool: AgentSkill
    public static let simtoolTest: AgentSkill
    public static let all: [AgentSkill] = [.simtool, .simtoolTest]
}

public enum AgentSkillInstaller {
    public enum Scope: String, CaseIterable, Sendable { case local, global, none }

    /// Which agent's skills directory to write into. The layout is identical —
    /// `<root>/.claude/skills/<name>/SKILL.md` and
    /// `<root>/.codex/skills/<name>/SKILL.md` — so one document serves both.
    public enum Agent: String, CaseIterable, Sendable {
        case claude, codex
        var directoryName: String { "." + rawValue }   // .claude / .codex
    }

    public enum Outcome: String, Encodable, Sendable {
        case created, updated, upToDate, conflict
    }

    public struct Installation: Encodable, Sendable {
        public var skill: String    // "simtool-test"
        public var agent: String    // "codex"
        public var scope: String    // "global"
        public var outcome: Outcome
        public var path: String
    }

    public static func directory(
        skill: AgentSkill, agent: Agent, scope: Scope,
        projectDirectory: URL, home: URL
    ) -> URL?

    public static func install(
        skills: [AgentSkill] = AgentSkill.all,
        agents: [Agent],
        scope: Scope,
        projectDirectory: URL,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        force: Bool = false
    ) throws -> [Installation]
}
```

`scope: .none` or an empty `agents` returns `[]`; the `skipped` outcome goes,
because an empty result already says it. `Installation.path` becomes
non-optional for the same reason.

Per-file behaviour is exactly today's: identical contents → `upToDate`; a file
the user edited → `conflict`, left alone unless `force`. That check is per skill
per agent, so a user who filled in `simtool`'s catalog can still receive a fresh
`simtool-test`.

### `simtool init` surface

```
--skill <local|global|none>     where the skills go (unchanged)
--skill-agent <claude|codex|both>   whose layout to write (default: claude)
```

`claude` is the default because writing into `~/.codex` for someone who does not
use Codex is noise, and because it preserves today's behaviour for anyone
scripting `init --skill local`.

Interactively (a tty, no `--json`, `--skill` absent) two prompts, the second
skipped when the first is "don't install":

1. *Install the simtool agent skills?* — This project (`.claude`/`.codex` in the
   project) · All projects (under `$HOME`) · Don't install
2. *For which agent?* — Claude Code · Codex · Both

Non-interactive runs still install nothing unless `--skill` says otherwise.

The guard for re-running `init` in a configured project keeps its shape: an
existing `.simtool/config.yml` aborts only when there is nothing else to do, and
the message keeps pointing at `--skill <local|global>`.

`InitResult.skill: AgentSkill.Installation` becomes
`InitResult.skills: [AgentSkillInstaller.Installation]`. This changes
`init --json` output. Acceptable: skill installation shipped one release ago and
the archive it sits next to never shipped at all.

Terminal takeaways: one line per installation
(`simtool-test → ~/.claude/skills/simtool-test/SKILL.md (created)`), and the
existing "fill in the skill's project options and launch-argument catalog" todo
whenever the `simtool` skill was created or updated.

### `skills/simtool-test/SKILL.md`

App-agnostic, like its sibling. Frontmatter:

```yaml
name: simtool-test
description: >
  Write a declarative YAML UI test for an iOS app and drive the red→green loop
  with it: encode a reported bug or an unbuilt feature as a test that asserts the
  expected behaviour, run it with `simtool test run` (its exit code is the
  verdict), change the product, and re-run the same file as the regression guard.
  Use when asked to reproduce a bug on the simulator, prove a bug exists, write a
  repro test, write a test for acceptance criteria before the feature exists,
  check whether a fix worked, or hand a test to someone else — "напиши тест на
  баг", "воспроизведи баг тестом", "докажи что баг есть", "тест на ожидаемое
  поведение", "сделай по TDD", "проверь что починилось", "передай тест".
argument-hint: [a bug report, a ticket key, or acceptance criteria]
allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
```

Sections:

1. **What this is for** — the two shapes of the loop (a reported bug, an unbuilt
   feature) and the one rule that governs both: *assert the expected behaviour,
   never the current broken one.* A test that asserts the broken state has to be
   inverted after the fix, and inverted tests get deleted.
2. **The loop, for a bug** — write it → run → `unsatisfied` (exit 1) *is* the
   reproduction → change the product → run the same file → `satisfied` (exit 0),
   and the file stays as the regression guard. `inconclusive` or `infra` means
   fix the test, not the product.
3. **The loop, for a feature** — criteria from the acceptance list, one
   `criterion:` label each → red → implement → green. `kind: feature` reports
   every criterion from one run, so "AC-1 ok, AC-3 unmet" costs one run.
4. **Before the first run** — a booted simulator, the app installed (the build
   you intend to judge), `.simtool/config.yml`. No `serve` step: `test run`
   starts a server when none is running.
5. **The file format** — the full schema with `simtool test run --help` named as
   the source of truth, since flags move between versions.
6. **Staging the scenario** — environment, account, country and the rest are the
   *app's* launch arguments, which simtool knows nothing about. Inline in
   `launch.arguments` is the simple option and the default advice; a named
   `profiles:` entry plus `variables:` is for a recipe shared by several tests or
   a value needed twice; a real credential stays in the shell as `${VAR}`,
   defined nowhere in the file. Resolution order, and why the file beats the
   environment.
7. **Finding targets** — `simtool ax find <needle>`, `ax tree --flat --labeled`
   while driving the app by hand; `id` over `label` over `text`.
8. **Mocks belong in the test** — declared in `mocks:`, applied before launch,
   cleared after; `strict: true` so a rule that never fired makes the run
   `infra` instead of a quiet pass against the real backend.
9. **Verdicts** — the table, and what to do with each of the four.
10. **What the run leaves behind** — the session directory: `report.md`,
    `video.mp4`, `logs.jsonl`, `network.jsonl`, `state.jsonl`, `mocks.json`,
    failure screenshot and a11y dump; step entries carry log-cursor ranges and
    start/end timestamps, so the logs and requests of one step can be sliced out.
11. **Handing it on** — send the YAML file, and `report.md` / `video.mp4` when
    they help. What the receiver needs: `simtool`, a booted simulator, their own
    build of the app, and any `${VAR}` the test does not define. What not to
    send: evidence files carry the account's real traffic.
12. **Anti-patterns** — `wait:` where `waitFor` belongs; a `criterion:` on a
    staging step; asserting the broken state; a machine-specific path in
    `setup:`; no `kind:`, which throws away the verdict.

### `skills/simtool/SKILL.md`

The "Handing the test to whoever comes next" section goes. The UI-test section
shrinks to what it is and when it applies, plus a pointer to `simtool-test` for
writing one and for the loop. The `description` frontmatter loses its export and
archive triggers and gains the sibling's name, so an agent that loaded the wrong
one of the two is told where to go.

### `Scripts/sync-agent-skills.swift`

Regenerates both Swift literals from `skills/*/SKILL.md`: read the file, indent
every line by eight spaces, wrap in `#"""` … `"""#`, write
`Skills/<Name>Skill.swift`. Refuses a document containing `"""#`.

With one copy the hand-carry was survivable; with two it is a guaranteed drift,
and the sync test only reports drift after the fact.

---

## Part 4 — documentation and tests

### README

- `#### Handing a test on` becomes `#### Sharing a test`: the YAML is the
  artifact; `report.md` and `video.mp4` sit in the session directory when
  something needs attaching; what the receiver supplies. The `test export` /
  `test show` snippets go.
- `#### Evidence` gains `report.md` in the list of what a run writes, and says it
  is written regardless of `--evidence`.
- `### Tests and sessions` says `test run` starts a server when none is running
  and stops only the one it started.
- The project-config section documents `init --skill-agent` and the two skills.

### Tests

| Area | Test |
|---|---|
| `TestReportRendererTests` | rewritten against `render(session:definition:)`; keeps a case per section, adds one for a session with no verdict and one with no definition |
| `TestReportWriterTests` | writes into a temp directory, returns the path, overwrites an existing report |
| `TestDefinitionParserTests` | unchanged — the format does not change |
| `LaunchProfileTests` (new or existing) | `names(in launch:setup:)` collects from argv, env values, deeplink and setup commands, deduplicated in first-appearance order, and ignores text outside those fields |
| `SimToolCommandSurfaceTests` | `test` subcommands are `["run", "list"]`; `init` parses `--skill-agent`; a `${VAR}` the test neither defines nor can resolve fails `Run` before any client work |
| `ServerAutostartTests` | `freePort` returns the first candidate with no listener, skips occupied ones, and throws naming the range when all are taken |
| `AgentSkillTests` | the existing cases run over `AgentSkill.all`: frontmatter validity, no project-specific identifiers, sync with the authoring copy, `upToDate`/`conflict`/`force` per file; new cases for the agent axis (`claude` writes `.claude/skills`, `codex` writes `.codex/skills`, `both` writes both, `global` writes under the injected home and not into the project) |

`SessionControl.stop` and the autostart's spawn path are exercised by hand
against a real simulator, as the rest of the server lifecycle already is; the
decision logic they contain (`freePort`) is unit-tested.

## Commit order

1. `refactor(test)!: drop the flow archive, keep its report next to the run` —
   Part 1, including the `${VAR}` pre-flight.
2. `feat(test): run a test without a server already running` — Part 2.
3. `feat(init): a skill for writing tests, and Codex as a target` — Part 3.
4. `docs: sharing a test is sending the file` — Part 4's README work, if it has
   not already landed with the commits above.

Each commit builds and passes `swift test --package-path Tool`.
