# Run Progress Spinners

Date: 2026-06-12
Status: Approved

## Goal

`simtool run` (and `simtool app build` / `simtool app launch`) currently stay
silent through the long stages — simulator boot, xcodebuild, install, launch —
so the command looks frozen. Each stage gets a Noora `progressStep` spinner,
and during the build the status line is replaced in place with the current
xcodebuild action ("Compiling HomeView.swift", "Linking MyApp") instead of
streaming xcodebuild's full output.

## User-Visible Behavior

Interactive `simtool run`:

```
✔ Resolved simulator iPhone 16 Pro
✔ Booted iPhone 16 Pro
⠹ Building MyApp (Debug) · Compiling HomeView.swift   ← one line, updated in place
✔ Built MyApp (Debug) [42s]
⠹ Launching MyApp · Installing…                        ← one line, updated in place
✔ Launched com.example.myapp [3s]
✔ Launched com.example.myapp        ← existing summary alert with takeaways, unchanged
```

- Cache hit: the build step completes immediately ("✔ Built MyApp [0.2s]");
  the "reused (checksum cache)" detail stays in the final alert as today.
- `--json`: no spinners at all; output is byte-identical to today.
- Non-interactive terminal (CI, pipes): Noora's `progressStep` prints plain
  stage lines itself. Live xcodebuild statuses are NOT forwarded there, so CI
  logs get one line per stage, not hundreds.
- Build failure: `progressStep` prints its ⨯ line, and the existing
  `SimToolError` with xcodebuild details propagates unchanged.

## Changes by Layer

### 1. `SimToolCore/ProcessRunner.swift`

`ProcessRunner.run` gains an optional parameter
`onStdoutLine: (@Sendable (String) -> Void)? = nil`. Incoming stdout data is
split on `\n`; complete lines are delivered as they arrive (partial trailing
data is buffered until its newline or process exit). Result buffering and all
existing call sites are unchanged.

### 2. New `SimToolCore/XcodebuildProgress.swift`

A pure mapping `XcodebuildProgress.status(forLine:) -> String?` that turns
known xcodebuild step lines into short human statuses:

| Line prefix | Status |
| --- | --- |
| `SwiftCompile`, `CompileSwift`, `CompileC` | `Compiling <file>` |
| `Ld` | `Linking <name>` |
| `CodeSign` | `Signing <name>` |
| `CompileAssetCatalog` | `Compiling asset catalogs` |
| `CompileStoryboard`, `CompileXIB` | `Compiling <file>` |
| `PhaseScriptExecution` | `Running script <name>` |
| `ProcessInfoPlistFile` | `Processing Info.plist` |
| `CopySwiftLibs`, `CpResource`, `PBXCp`, `Copy` | `Copying resources` |
| `Resolve Package Graph`, `Resolving` | `Resolving packages` |
| `Planning`, `Build description` | `Planning build` |

Unknown lines return `nil` (the previous status stays on screen). File/name is
the last path component, unescaped.

### 3. `SimToolCore/SimulatorAppLifecycle.swift`

- `build(...)` gains `progress: (@Sendable (String) -> Void)? = nil`. When
  set, xcodebuild runs with `onStdoutLine` and parsed statuses are forwarded.
- The post-build tail of `launch` (install decision, cache records, launch,
  missing-install retry) moves into a new public
  `installAndLaunch(build:device:launchEnvironment:launchArguments:force:cache:timeoutSeconds:progress:)`
  with phase statuses `Installing…`, `Launching…`, `Reinstalling…`.
- `launch(...)` remains as the composition `build` + `installAndLaunch` and
  also accepts the optional progress callbacks. No retry/cache logic is
  duplicated.

### 4. `SimToolCLI/SimTool.swift`

- `Run.run()` wraps each stage in `Noora().progressStep`:
  resolve → boot → build → install+launch. Build/launch callbacks feed
  `updateMessage` as `"<stage message> · <status>"`.
- Updates are deduplicated (identical status skipped) and throttled to ~10/s.
- Live statuses are forwarded only when stdout is a TTY (`isatty`); `--json`
  skips spinners entirely and keeps current output.
- `app build` and `app launch` subcommands adopt the same wrappers.
- The final success alert of `run` is unchanged.

## Testing

- Unit tests for `XcodebuildProgress.status(forLine:)` against real xcodebuild
  output lines, including unknown lines → `nil`.
- `ProcessRunner` streaming test: run `/bin/sh -c` emitting multiple lines,
  assert lines are delivered and the buffered result still matches.
- Existing lifecycle/CLI tests must pass unchanged (all new parameters are
  optional with `nil` defaults).
- Spinner rendering is verified manually in an interactive terminal.

## Out of Scope

- No progress bars with percentages (xcodebuild does not report totals).
- No live-output collapsible view (rejected: xcodebuild is too noisy).
- `simtool app test` keeps its current behavior.
