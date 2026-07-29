# SimTool

Swift CLI/server for streaming and automating Apple Simulators.

The MVP focuses on a local browser viewer with JPEG and H.264/AVCC streams and a
machine-readable CLI for agents.

## Build

The repository is two SwiftPM packages: the root package vends the embeddable
logger libraries (`SimToolNetworkLogger`, `SimToolStateLogger`), and the `Tool/`
package builds the `simtool` CLI. Build the CLI from `Tool/`:

```sh
swift build --package-path Tool
```

## Install

Recommended Homebrew install after the public tap is published:

```sh
brew tap mstroshin/simtool
brew trust mstroshin/simtool   # recent Homebrew requires trusting a third-party tap before install
brew install simtool
simtool doctor
```

Upgrade or remove:

```sh
brew update
brew upgrade simtool
brew uninstall simtool
```

Runtime prerequisites:

- macOS 14 or newer.
- Xcode or Command Line Tools with installed simulator runtimes.
- `xcode-select` pointing at the selected developer directory.
- AXe for accessibility automation commands such as `ax` and accessibility-based `input` actions.

Source fallback for development:

```sh
swift build --package-path Tool
swift run --package-path Tool simtool doctor
```

## Basic Usage

The `swift run simtool …` examples below run against the CLI package in `Tool/`.
Either `cd Tool` first and use them verbatim, or keep them as `swift run
--package-path Tool simtool …` from the repo root.

```sh
swift run simtool devices --json
swift run simtool serve --device <udid-or-name> --port 3200
```

Open `http://127.0.0.1:3200` after starting `serve` (the URL is printed on start),
or pass `--web` to open the browser viewer automatically.

`serve` runs fully headless: when `--device`, `--host`, or `--port` are omitted
it falls back to `simulator:` and `server:` from `.simtool/config.yml` (when one
is discovered, or passed via `--config`), and boots the target simulator via
`simctl` if it is not running yet — no Simulator.app window is ever opened; watch
the device in the web viewer instead. With `--detach --json` the started session
is printed as JSON whose `url` field is the viewer address, ready to feed into a
browser or another tool.

Run `simtool` with no subcommand (or `simtool interactive`) in a terminal to
pick and open configured deeplinks in a loop. Requires a `deeplinks:` list in
`.simtool/config.yml`; select `Exit` or press Ctrl+C to leave. Non-interactive
callers should keep using explicit subcommands such as `simtool devices` —
bare `simtool` no longer defaults to `devices`.

For detached agent usage:

```sh
swift run simtool serve --detach --json --port 3200
swift run simtool status --json
swift run simtool kill <session-id> --json
```

## Automation

```sh
swift run simtool input button home --json
swift run simtool ax tree --json
swift run simtool ax tree --flat --labeled
swift run simtool ax find Continue --json
swift run simtool logs tail --lines 20 --seconds 2 --json
swift run simtool logs tail --app com.example.MyApp --lines 20 --seconds 2 --json
swift run simtool logs tail --app com.example.MyApp --stdout --seconds 4 --json
swift run simtool network snapshot --seconds 2 --limit 50 --json
```

### Tests and sessions

Declarative YAML tests in `<project>/.simtool/tests/` drive the simulator
through the served accessibility tree: every step polls until its target
appears, so tests need no sleeps. Each run is recorded as a reviewable test
session — timestamped steps, a screen recording and the run's evidence — shown
in the web viewer's **Tests** tab, which also lists the tests with Run buttons
and live progress. Finished sessions play their recording in place of the live
stream, and clicking a step seeks the video to that moment.

```bash
swift run simtool test run .simtool/tests/my-test.yml
swift run simtool test run .simtool/tests/my-test.yml --json --repeat 5
swift run simtool test list --json
```

A running server is not a prerequisite: when none is running, `test run` starts
one on a free port and stops it again afterwards. One already running for this
project is reused and left alone; one belonging to another checkout is not — the
run says so and starts its own instead.

A test carries everything needed to stage its scenario, so it reproduces on
another machine: `launch:` (a named profile from `.simtool/config.yml` plus
inline argv/env), `reset:` (UserDefaults, data container, permission alerts,
locale) and `mocks:` (backend answers, applied before launch). See
`simtool test run --help` for the full file format.

#### Verdicts

A test that declares `kind: bug` or `kind: feature` and marks the assertions
that check its claim with `criterion:` gets a verdict instead of a bare
pass/fail — and a distinct exit code, so an agent can branch without parsing
output:

| Verdict | Exit | `kind: bug` | `kind: feature` |
|---|---|---|---|
| `satisfied` | 0 | not reproduced / fixed | feature confirmed |
| `unsatisfied` | 1 | bug reproduced | feature not confirmed |
| `inconclusive` | 2 | the run never reached a criterion | same |
| `infra` | 3 | the run cannot be trusted | same |

The point of the split is that a run which fell over while staging the scenario
proves nothing: reporting it as "the bug reproduces" sends someone to fix the
wrong thing. `infra` covers a run whose staging silently did not happen — a
`strict:` mock that never intercepted a call, an app that never picked up its
mock rules, a `reset:` that failed — and is never reported as a pass.

A `bug` run stops at the first unmet criterion; a `feature` run reports every
criterion from one run. Tests with no `kind:` keep the old behaviour (0 or 1).
`--repeat N` runs the test N times and reports how many runs held the claim,
because an intermittent defect that passes once looks fixed.

#### Evidence

Sessions persist under `<project>/.simtool/test-sessions/<session-id>/`
alongside the project the server was started for, and survive server restarts.
Besides `session.json` and `video.mp4`, a run writes what explains it — the
runner arms the log capture itself and scopes it to its own launches:
`logs.jsonl`, `network.jsonl` (with `mocked` and the rule id per event),
`state.jsonl`, `mocks.json` (what each declared rule actually did) and a
screenshot plus visible-element dump at the point of failure. `--evidence
none|failure|full` controls how much; `full` also captures every step.
`session.json` additionally records provenance: an inline copy of the test, the
app's bundle id and version, the device and runtime, the simtool version, and
the commit.

Every recorded run also writes `report.md` — the same run rendered for a person —
regardless of `--evidence`, which controls captures rather than that.

One session is active at a time; sessions can also be driven directly over HTTP
via `POST /api/v1/tests/start|entries|stop`.

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

Do not forward the evidence files outside the team: `logs.jsonl`,
`network.jsonl` and `state.jsonl` hold the real traffic and log output of the
account the run used. `report.md` says so too.

`ax tree` and `ax find` omit the bulky raw AXe payload by default; pass `--raw`
(or `?raw=1` on `/api/v1/ax/tree` and `/api/v1/ax/find`) to include it. For the
cheapest screen summary use `ax tree --flat` (`?format=flat`) — a depth-annotated
node list with identifiers, labels, and frames — and add `--labeled`
(`&labeled=1`) to keep only nodes an agent can address. JSON output is
pretty-printed at a terminal and compact when piped.

`logs tail --app` accepts a bundle identifier, subsystem prefix, or process name.
For dotted bundle identifiers, SimTool also matches the final component as a
process name so app `print` output can be found more reliably.

By default `logs tail` samples only unified logging (OSLog). Add `--stdout` (with
`--app <bundle-id>`) to also capture the app's `print`/stdout output via
`simctl launch --console-pty` — this **terminates and relaunches the app** to
attach its console. Each captured line is tagged with its `source` (`oslog` or
`stdout`).

## App Build and Launch

Build an iOS simulator app from an Xcode workspace or project:

```sh
swift run simtool app build --workspace MyApp.xcworkspace --scheme MyApp --json
swift run simtool app build --project MyApp.xcodeproj --scheme MyApp --configuration Debug --json
```

Launch builds only when the build-input checksum changes. If the checksum matches
the last successful build, SimTool reuses the cached `.app`; if the selected
simulator does not have that checksum installed yet, SimTool installs it before
launching. Checksum metadata is stored in `.simtool/build/` inside the project;
build products (DerivedData) stay in `~/Library/Caches/SimTool`.

```sh
swift run simtool app launch --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp --json
swift run simtool app launch --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp --json
```

Pass runtime flags to the launched app with repeatable `--env KEY=VALUE`
options. This is useful for enabling app-side SimTool diagnostics:

```sh
swift run simtool serve --detach --json --port 3311
swift run simtool app launch \
  --device <udid-or-name> \
  --workspace MyApp.xcworkspace \
  --scheme MyApp \
  --env SIMTOOL_NETWORK_LOGGER=1 \
  --env SIMTOOL_SERVER_URL=http://127.0.0.1:3311 \
  --json
swift run simtool network events --server http://127.0.0.1:3311 --json
```

Pass launch **arguments** (argv) to the app — as opposed to environment
variables — by listing them after a `--` terminator. They are forwarded verbatim
after the bundle id and reach the app through `CommandLine.arguments` (and the
`NSArgumentDomain` of `UserDefaults`), which is how most debug/test launch flags
are wired:

```sh
swift run simtool app launch \
  --device <udid-or-name> \
  --workspace MyApp.xcworkspace \
  --scheme MyApp \
  -- -DebugFlag 1234 -SomeDebugFlag YES
```

`app launch` always cold-launches with `--terminate-running-process`, so launch
arguments and `SIMCTL_CHILD_*` environment take effect even when the app is
already running.

`SimToolNetworkLogger.makeFromEnvironment()` reads `SIMTOOL_NETWORK_LOGGER` and
`SIMTOOL_SERVER_URL` for you, returning `nil` (no capture) unless the logger is
enabled. For simulator development prefer `SimToolNetworkLogger.resolved()`: it
behaves like `makeFromEnvironment()` but, **only in the iOS Simulator**, also
self-activates from an on-device marker it persists the first time SimTool arms
it. That keeps network events flowing after you fully kill and relaunch the app
outside SimTool — by tapping its icon or running from Xcode — where the
`SIMTOOL_*` environment is gone. It is hard-gated to the simulator, so device,
TestFlight, and App Store builds never auto-enable, and an explicit
`SIMTOOL_NETWORK_LOGGER=0` opts a run out. The bundled `URLProtocol` capture
covers `URLSession` traffic automatically. Apps whose network layer is gRPC (or
any non-`URLSession` transport) record from their own client interceptor by
calling the framework-agnostic API — `resolved()`/`makeFromEnvironment()` then
`recordGRPC`/`startGRPCCall` — passing bounded message previews that surface as
request/response bodies.

Both viewers include a `Network` toggle that opens a Proxyman-style inspector
beside the live stream: a request list plus a request/response detail pane
(metadata/headers, body previews, status, timing, errors), updated live from the
events endpoint.

Both viewers also include a `Logs` toggle that opens a live log inspector,
filterable by source (`oslog`/`stdout`) and free text. When scoped to an app it
captures both the app's OSLog and its `print`/stdout output (via
`--console-pty`), polling the capture endpoint incrementally by cursor; no app
instrumentation is required.

Both inspectors group entries by **app launch**: the server detects each launch
of the inspected app from the OSLog process id (and from network-logger
batches), and the logs and network lists draw an `App launch · <time> · pid <n>`
divider wherever the launch changes. So when you fully kill and relaunch the
app, its new logs and requests keep streaming below a fresh divider while earlier
launches stay visible above (for the life of the server). OSLog
(`os.Logger`/`NSLog`) and network events continue across such a relaunch;
`print`/stdout does **not** — it is only captured while SimTool itself launches
the app with `--console-pty`, so after an icon-tap or Xcode relaunch only OSLog
remains for that source.

Start the server with `--app <bundle-id>` to scope log capture to one app. The
server then captures that app's OSLog **and** `print`/stdout (instead of
flooding with system-wide OSLog), advertises the app via `/config`, and both
viewers auto-open the `Logs` panel scoped to it. Capturing relaunches the app
once (to attach its console); after that, opening or closing the panel does
**not** restart it — the server-owned capture stays alive and reopening reuses
it:

```sh
swift run simtool serve --device <udid-or-name> --app com.example.MyApp
```

After editing source, resources, project metadata, or common app configuration
files, the checksum changes and the next launch performs a new simulator build:

```sh
swift run simtool app launch --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp --json
```

Run XCTest or UI test schemes on a resolved simulator with `app test`:

```sh
swift run simtool app test --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyAppUITests --json
swift run simtool app test --device <udid-or-name> --project MyApp.xcodeproj --scheme MyAppTests --configuration Debug --json
```

## Model state inspector (`@SimToolDebugState`)

Stream your `@Observable` models' state to the SimTool web UI in debug builds.
Annotate the model and register the instance once:

```swift
import SimToolStateLogger

@Observable                      // optional — see polling below
@SimToolDebugState
final class AppModel {
    var count = 0
    var coords = Coords()        // @SimToolDebugState struct → expands
}

@SimToolDebugState
struct Coords { var x = 0.0 }

// register once (name defaults to the type name):
SimToolState.track(model)
// or chain it where the instance is created — works from DI factories too:
let model = AppModel().simToolTracked()
// plain (non-@Observable) classes are polled (default 1 s); tune with poll:
SimToolState.track(legacy, poll: .milliseconds(250))
```

Add the package to your app (debug configurations only is fine):

```swift
.package(path: "path/to/SimTool/StateLogger"),
// target dependency:
.product(name: "SimToolStateLogger", package: "StateLogger"),
```

The logger is inert unless the app is launched with `SIMTOOL_STATE_LOGGER=1` and
`SIMTOOL_SERVER_URL` (SimTool's app-launch flow sets these). Every change — from
methods, SwiftUI bindings, or async tasks — is debounced (~100 ms) and pushed to
the **State** tab: latest snapshot per model as an expandable tree, plus a diff
history. Notes:

- Requires iOS 17+ for the tracker. `@Observable` classes stream per-transition
  diffs via observation tracking; plain classes auto-fall back to polling
  (1 s default; pass `poll:` to tune — transitions shorter than the interval
  are not captured). Structs cannot be tracked top-level; annotate them to
  expand inside a tracked model. `track` is idempotent per instance and
  `name:` defaults to the type name.
- Snapshots include stored properties only, and only **scalars and collections of
  scalars** (Bool/numbers/String/Date/URL). Nested structs and classes render as a
  `"<TypeName>"` placeholder — annotate the nested class with `@SimToolDebugState`
  too if you want its contents. `@ObservationIgnored` properties appear in
  snapshots (as scalars or placeholders) but do not trigger updates.
- If a tracked model is also nested inside another tracked model (e.g.
  `ScreenModel.counter` where both are tracked), the change history shows
  only the parent's entry (`counter.state.filling: …`) — the child's standalone
  entries would duplicate it, so they are hidden while the parent is alive. The
  child still gets its own card in the model list.
- No method attribution: events tell you *what* changed, not *which method* changed it.
- Snapshots over 256 KB are replaced with a truncation marker.

## Project Config, `run`, and `open`

For a checked-out project you can record the simulator, app, build selection, and
deeplinks once in `.simtool/config.yml` at the project root, then drive everything
with one command. SimTool discovers the config by searching the working directory
and walking up to parent directories. The `.simtool` folder is automatically
git-ignored via its own auto-created `.gitignore`. Pass `--config <path>` to point
at a specific file; its directory then plays the `.simtool` role, so relative paths
in the config resolve against that directory's parent.

Run `simtool init` from the project root to scaffold a starter `.simtool/config.yml`:
it detects the `.xcworkspace`/`.xcodeproj` and scheme where it can, defaults
`simulator` to `booted`, creates the self-ignoring `.gitignore`, and leaves `# TODO`
fields (such as `bundleId`) for you to fill in. It refuses to clobber an existing
config unless you pass `--force`.

`init` also offers to install the two bundled **agent skills** — `simtool`
(build, launch, drive, mock, inspect) and `simtool-test` (write a verifying test
and drive it red to green) — Markdown briefs that teach a coding agent how to
work with your app through this CLI. Run interactively it asks where to put
them; pass `--skill local|global|none` to choose the tree up front and
`--skill-agent claude|codex|both` to choose the layout (`.claude/skills` or
`.codex/skills`):

| Scope | Destination | Applies to |
|---|---|---|
| `--skill local` | `<project>/.claude/skills/` (or `.codex/skills/`) | this checkout (commit it to share with the team) |
| `--skill global` | `~/.claude/skills/` (or `~/.codex/skills/`) | every project on this machine |
| `--skill none` | — | nothing installed |

Non-interactive runs (`--json`, or no TTY) default to `none`, so scripted `init`
never writes outside the project. Re-running `init` leaves an installed skill
alone once you have edited it — `--force` replaces it with the bundled version,
because the `simtool` skill has two placeholder sections, *Project options* and
*Launch argument catalog*, that you are expected to fill in with your
workspace/scheme and with the debug launch arguments your own app reads.

```sh
swift run simtool init --skill local                        # config + both skills for this project
swift run simtool init --skill global --skill-agent both    # …skills for both agents, everywhere
swift run simtool init --skill local --force                 # refresh config and skills from the bundled versions
```

```yaml
# .simtool/config.yml
simulator: "iPhone 16 Pro"          # UDID, name, or `booted` for the first booted simulator
bundleId: com.example.MyApp
build:
  workspace: MyApp.xcworkspace      # or `project: MyApp.xcodeproj`
  scheme: MyApp
  configuration: Debug              # optional, defaults to Debug
  # derivedDataPath: ./DerivedData  # optional
server:                             # optional viewer settings
  host: 127.0.0.1
  port: 3200
deeplinks:
  - name: Details
    url: myapp://items/42
  - name: Settings
    url: myapp://settings?section=general
profiles:                           # optional named launch recipes for tests
  staging-account1:
    arguments: [-UITesting, -Environment, staging, -AutoLogin, "${ACCOUNT1}"]
    env: { SOME_FLAG: "1" }         # exported to the app as SIMCTL_CHILD_*
    # deeplink: myapp://home        # opened once the app is running
```

A test refers to a profile by name (`launch: { profile: staging-account1 }`), so
the app-specific arguments — environment switches, a UI-testing master switch,
the shape of the login arguments — stay in the project config and out of every
test file.

A test that carries its own arguments can simply write the account into them
(`arguments: [-Environment, stable, -FastLoginPhone, "+52 971 624 9725"]`) — argv
reaches `simctl` as separate elements, so spaces need no escaping, and that is
the simplest form. `variables:` covers what inline argv cannot: parameterising a
*shared* profile, and stating a value once when both a `setup:` command and the
run's own launch need it.

```yaml
variables: { ACCOUNT: "+52 971 624 9725" }
launch: { profile: staging-account1 }     # whose argv refers to ${ACCOUNT}
```

`${VAR}` is resolved from `variables:` first, then from the process environment,
and `--var NAME=value` overrides both. The file beats the environment on purpose:
a stale `export` must not silently redirect a test to a different account. Keep a
value out of `variables:` when it must stay in the shell — a real credential,
anything for a production account. Either way an unresolved `${VAR}` fails the
run rather than expanding to nothing, because an empty account argument logs in
as nobody and the test then tests nothing.

`simulator:` is also the default device for **every** command, not just
`run`/`serve`/`open`. With several simulators booted and neither `--device` nor a
config to go by, commands fail instead of picking one: on a machine running
parallel checkouts, guessing means driving another one's simulator, where taps
land elsewhere and the accessibility tree merely looks stale.

Relative `workspace`/`project`/`derivedDataPath` paths resolve against the config
file's directory.

`simtool run` reads the config, boots the configured simulator if needed, builds
(reusing the checksum cache), installs, and launches the app, then starts the
viewer server and prints its URL (`Open http://…`, or the `url` field with
`--json`) — handy for scripts that open the page themselves. Pass `--web` to
also open the browser viewer. It runs in the foreground like `serve` (Ctrl-C
stops it), or pass `--detach` to leave the viewer server running in the
background once the app is launched — build and launch still report in the
foreground, and the printed session (`url` with `--json`) is ready to open.

```sh
swift run simtool run            # server only; open the printed URL yourself
swift run simtool run --web      # …and open the browser viewer
swift run simtool run --detach   # build, launch, leave the server in the background
swift run simtool run --device booted        # run on the first booted simulator
swift run simtool run --device "iPhone 16"   # …or a specific UDID/name, overriding the config
swift run simtool run --config path/to/.simtool/config.yml
```

`run` enables the app-side SimTool network and state loggers by default so the
viewer's Network and State panels work out of the box — it exports
`SIMTOOL_NETWORK_LOGGER`, `SIMTOOL_STATE_LOGGER`, and `SIMTOOL_SERVER_URL` to the
app (via the `SIMCTL_CHILD_` prefix, so they also survive the server's
stdout-capture relaunch). Both are inert for apps that do not link the
corresponding logger package and are compiled out of Release builds. Turn them
off with `--no-network` / `--no-state` or `networkLogger: false` /
`stateLogger: false` in the config.

The source fingerprint hashes only git-tracked (and untracked-but-not-ignored)
files when the project is in a git work tree, falling back to a filesystem walk
otherwise. This keeps gitignored, generated artifacts — a Tuist-managed
`.xcodeproj`/`Derived/` that xcodebuild rewrites on every build, DerivedData,
SPM checkouts — out of the checksum, so they don't spuriously invalidate the
cache.

`run --force` skips the checksum cache: it always runs xcodebuild and
reinstalls the app. Use it when a dependency the fingerprint cannot see
changed — e.g. a local package outside the project root, or a Tuist binary
cache that went stale (then regenerate with `tuist generate` first).

`simtool checksum` records the source checksum for an app you built outside
SimTool — typically from an Xcode post-build phase — so the next `simtool run`
sees a cache hit and reuses that `.app` instead of re-running xcodebuild. It
reads the same `.simtool/config.yml` as `run` (so the recorded checksum and its
cache key match what `run` looks up) and writes the metadata against the built
bundle. The bundle path defaults to `$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME`
(set inside Xcode build phases); pass `--app-path` to override.

```sh
# As an Xcode "Run Script" post-build phase, from $SRCROOT:
simtool checksum --config "$SRCROOT/.simtool/config.yml"

# Or standalone, pointing at a built bundle:
swift run simtool checksum --app-path /path/to/MyApp.app --json
```

`simtool open` opens a configured deeplink on the configured simulator via
`xcrun simctl openurl`. Pass a deeplink `name` to open it directly, or omit it to
choose interactively. `--json` prints a structured result.

```sh
swift run simtool open                 # interactive picker
swift run simtool open Details         # open by name
swift run simtool open Settings --json
```

## HTTP API

Local endpoints:

```text
GET /health
GET /config
GET /api/v1/status
GET /api/v1/devices
GET /api/v1/metrics
GET /stream.avcc
GET /stream.jpeg
GET /stream.mjpeg
POST /api/v1/input
GET /api/v1/ax/tree?raw=1&format=flat&labeled=1
GET /api/v1/ax/raw
GET /api/v1/ax/find?q=<text>&raw=1
GET /api/v1/logs?lines=200&seconds=2
POST /api/v1/logs/capture
GET /api/v1/logs/capture?since=<cursor>&limit=500
POST /api/v1/logs/capture/stop
GET /api/v1/network?seconds=2&limit=200
GET /api/v1/mocks
GET /api/v1/mocks/ack
GET /api/v1/screenshot?maxDim=800
```

`mocks/ack` reports the server's mock-rule generation and the newest one an app
has confirmed applying (learned from its poll). A run that declares `mocks:`
waits for the two to meet before its first step — otherwise the app can still be
answering from the real backend while the test believes it is mocked.

`screenshot` returns the full-resolution PNG by default; `maxDim` scales it so
the longest edge fits the given pixel size — agents reading the screen pay for
image pixels, and an 800px screenshot is still perfectly legible.

The `logs/capture` routes drive a continuous capture (OSLog plus optional
stdout/`print`) into a bounded buffer that clients poll incrementally by cursor;
`GET /api/v1/logs` remains the one-shot bounded snapshot.

`SimToolClient` exposes these routes as typed async Swift calls.
