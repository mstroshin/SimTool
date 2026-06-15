# Interactive Deeplinks Mode

Date: 2026-06-12
Status: Approved

## Goal

Running bare `simtool` (no subcommand) in a terminal starts an interactive
session that lists the deeplinks from `.simtool.yml` and lets the user open
them on the configured simulator repeatedly, without re-running the command.

## Entry Point

- New subcommand `interactive` defined in `Sources/SimToolCLI/SimTool.swift`.
- Registered as `defaultSubcommand` of the root `SimTool` command, so bare
  `simtool` launches it. `simtool --help`, `simtool open <name>`, and every
  other subcommand keep working unchanged.
- `simtool interactive` also works explicitly and appears in help output.

## Behavior

The mode is a loop built on `Noora().singleChoicePrompt` (no full-screen TUI):

1. Load the project config via `ProjectConfigLoader.load(explicitPath:)`.
   The command accepts the same `--config` option as `open`.
2. Show a single-choice prompt listing each configured deeplink (display the
   name; include the URL in the option description) plus a final
   "Exit" entry.
3. On selecting a deeplink:
   - Resolve the simulator from the config (`SimulatorDeviceClient.resolve`)
     and boot it if needed (`ensureBooted`). Resolution and boot happen on the
     first open only; the booted device is reused for subsequent opens within
     the session.
   - Open the URL via `SimulatorDeeplinkClient.open(name:url:device:)`.
   - Report the outcome with `Noora().success(...)` on success or an error
     alert on failure, then return to the prompt.
4. Selecting "Exit" (or pressing Ctrl+C) ends the session.

## Non-Interactive Guard

If stdin is not a TTY (agents, pipes, CI) or `--json` is passed, the command
does not enter the loop. It exits with an error suggesting `simtool --help`
and `simtool open <name>` instead. This preserves today's expectation that a
non-interactive bare `simtool` invocation fails fast rather than hanging on a
prompt.

## Error Handling

- Missing config or empty `deeplinks:` list → clear error naming the config
  path (or how to create one) and exit; never enter the loop.
- A failure while opening a specific deeplink (e.g. simulator died, simctl
  error) → show the error and return to the prompt; the session keeps running.
  The cached device is dropped so the next attempt re-resolves and re-boots.

## Out of Scope

- `simtool open` is unchanged, including its existing one-shot prompt.
- No additional sections (logs, input, device status) in this iteration.

## Testing

Loop/selection logic is separated from Noora behind a thin seam so unit tests
cover:

- Building the prompt option list from a config (deeplinks order + Exit entry).
- Empty-deeplinks and missing-config errors.
- The non-TTY / `--json` guard path.

The interactive prompt itself is verified manually.
