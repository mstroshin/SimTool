# Web Viewer: Tests Tab

**Date:** 2026-06-12
**Status:** Approved

## Problem

When an AI agent tests a freshly built feature through SimTool (launching the app, tapping
through screens, reading logs), the human gets no artifact of that testing. The agent's
observations live in its transcript; the simulator screen activity is gone the moment it
happens. The user has to trust the agent's prose summary.

A new **Tests** inspector tab turns agent testing into a reviewable artifact: a timeline of
steps the agent narrated, the log lines it judged important, and a screen recording of the
simulator for the whole session — so the user can *watch* how the feature was tested.

## Design Overview

The agent drives an explicit **test session**:

```bash
simtool test start "Verify preference editing"
simtool test step "Opened the preferences screen"
simtool test step "Tapped Save — confirmation toast appeared" --log "[Settings] save OK"
simtool test log "[Sync] cache refreshed"
simtool test stop --status passed
```

`start` begins a simulator screen recording (`xcrun simctl io recordVideo`) owned by the
server; `stop` finalizes it. Between the two, the agent appends timestamped timeline
entries. Sessions persist on disk and survive server restarts.

In the web viewer, the Tests tab lists sessions and shows the selected session's timeline.
While a session is **running**, the timeline updates in real time and the left pane keeps
showing the live simulator stream (the agent is driving it right now). Once the session
**finishes**, the left pane switches to playback of the recorded video; clicking a timeline
step seeks the video to that moment.

## Data Model & Storage (`SimToolCore`)

Sessions live under `~/.simtool/test-sessions/<sessionId>/`:

```
~/.simtool/test-sessions/
  └── 2026-06-12-1430-a1b2c3/
      ├── session.json   ← metadata + timeline, rewritten on every mutation
      └── video.mp4      ← simctl recordVideo output
```

The directory is user-global (not per-project): the server is bound to a device, not a
project, and `$TMPDIR` (where daemon sessions live) gets periodically cleaned — test
artifacts must outlive that.

`session.json`:

```json
{
  "id": "2026-06-12-1430-a1b2c3",
  "title": "Verify preference editing",
  "deviceUdid": "…",
  "deviceName": "iPhone 16 Pro",
  "startedAt": "2026-06-12T14:30:00Z",
  "endedAt": "2026-06-12T14:30:42Z",
  "recordingStartedAt": "2026-06-12T14:30:00.4Z",
  "status": "running | passed | failed | interrupted",
  "videoError": null,
  "entries": [
    { "kind": "step", "at": "…", "text": "Opened the preferences screen" },
    { "kind": "step", "at": "…", "text": "Tapped Save — toast appeared",
      "logs": ["[Settings] save OK"] },
    { "kind": "log",  "at": "…", "logs": ["[Sync] cache refreshed"] }
  ]
}
```

- **Two entry kinds.** `step` carries narrated text plus optional attached log lines;
  `log` carries important log lines not tied to a step. Logs are agent-curated — SimTool
  does not auto-capture logs into sessions; the Logs tab already covers raw streaming.
- **Video offset** for an entry is `at − recordingStartedAt`, computed client-side for
  seek-on-click. Wall-clock precision is sufficient for this purpose.
- **One active session per server.** A second `start` while one is running is an error.
- **Incremental persistence.** `session.json` is rewritten after every mutation, so a
  crash loses at most the in-flight entry.
- **`interrupted` status.** On startup the server scans the sessions directory and marks
  any session still `running` as `interrupted` (the server died with it open).
- **Entry size limit.** Attached logs are capped (64 KB total per entry); oversized
  requests are rejected so a runaway agent can't bloat `session.json`.

New `TestSessionStore` in `SimToolCore` owns directory layout, JSON persistence, status
transitions, and the startup `interrupted` sweep. The `simctl` recording process hides
behind the existing process-runner protocol pattern for testability.

## Server (`StreamServer.swift`)

| Method | Endpoint | Purpose |
|---|---|---|
| POST | `/api/v1/tests/start` | Create session, spawn `xcrun simctl io <udid> recordVideo --codec h264 video.mp4` |
| POST | `/api/v1/tests/entries` | Append a step/log entry to the active session |
| POST | `/api/v1/tests/stop` | SIGINT the recorder, await mp4 finalization, set final status |
| GET | `/api/v1/tests` | All sessions with timelines (tab polls this like other tabs) |
| GET | `/api/v1/tests/:id/video` | Serve `video.mp4` with HTTP Range support |

- The recorder child process is owned by the server, so it spans CLI invocations and dies
  cleanly: graceful server shutdown SIGINTs an active recorder (simctl finalizes the mp4),
  then marks the session `interrupted`.
- **Range support is required** — `<video>` seeking does not work without it, and Swifter
  does not provide it. Header parsing (`bytes=0-`, `bytes=100-200`, invalid forms) is a
  pure function with unit tests; responses use 206/416 semantics.
- New payload types in `APIModels.swift` follow the existing naming pattern:
  `TestSessionPayload`, `TestSessionListPayload`, `TestEntryRequest`, etc.

## CLI (`SimTool.swift`)

New `simtool test` command group — thin wrappers over the HTTP API of the running server
(resolved the same way `simtool status` finds it). All commands print JSON for agent
consumption, matching existing CLI output conventions.

```
simtool test start <title>                 → session id
simtool test step <text> [--log <line>]…   → appended entry
simtool test log <line>…                   → appended log-only entry
simtool test stop --status passed|failed   → finalized session (status flag is required)
simtool test list                          → sessions summary
```

The name sits beside `simtool app test` (XCTest runner); they don't conflict technically
and serve different verbs: *running* tests vs *reporting* a testing session.

## Web UI (`WebViewer.swift`)

New `Tests` tab button after AX, with the standard count badge (number of sessions).

**Tab pane** (polls `GET /api/v1/tests` while active, like Network/Logs):

- **Sessions list** — title, status badge (`✓ passed` green, `✗ failed` red, `● running`
  amber, `interrupted` gray), duration, and start time.
- **Timeline of the selected session** — steps with `m:ss` video offsets and text;
  attached log lines render monospace under their step; `log` entries render monospace
  inline in the timeline.

**Left pane behavior** (the live-stream area):

- Session **running**: the live simulator stream stays — the user watches the agent test
  in real time while the timeline grows. The video file is still being written and is not
  playable yet.
- Session **finished** (any terminal status with a playable video): selecting it swaps the
  left pane to a `<video>` player (`/api/v1/tests/:id/video`) with native controls and a
  "← Back to live" button. If the session the user is
  currently watching finishes, the pane switches from live stream to its recording
  automatically.
- Clicking a timeline step seeks the video to `at − recordingStartedAt`; during playback
  the current step is highlighted as time passes.
- Leaving the Tests tab or pressing "Back to live" restores the live stream.

## Error Handling

- `start` while a session is active → HTTP 409 with the active session id.
- `step`/`log`/`stop` with no active session → HTTP 409.
- Recorder fails to spawn (no Xcode CLT, device shut down) → the session is still created
  with `videoError` set; steps and logs work; the tab shows the timeline without a player.
  The report matters more than the footage.
- Video requested for an unfinished session → HTTP 409 (file still being written).
- Hard server kill: session stays `running` on disk, marked `interrupted` on next startup;
  an unfinalized mp4 that fails to play shows a "video unavailable" note while the
  timeline remains fully readable.
- Corrupt/partial `session.json` found during the directory scan → skipped with a server
  log warning; the rest of the list loads.

## Testing

- **SimToolCore** (`TestSessionStore`): create/append/persist round-trips, status
  transitions, `interrupted` sweep, entry size limit, recorder lifecycle via a mock
  process runner.
- **SimToolServer**: endpoint tests for happy paths and every 409 case; Range header
  parser unit tests (`bytes=0-`, `bytes=100-200`, malformed → full response).
- **SimToolWeb** (existing `SimToolWebTests` pattern): HTML embeds `tabTests` button,
  pane containers, and the JS functions (`renderTestsList`, `startTestsPolling`, player
  swap logic).
- **SimToolCLI**: argument parsing for the `test` group, including the required `--status`
  on `stop`.
- Manual: run a real session against a booted simulator — start, tap around, attach logs,
  stop — then review the tab: timeline correct, video plays, step click seeks, running
  session updates live and auto-switches to playback on stop.

## Out of Scope

- Auto-capturing all logs/network/state events into sessions (the other tabs already
  stream those live).
- Deleting sessions from the web UI; cleanup is manual (`rm -rf` of a session directory)
  for now.
- MCP tools — the CLI is the agent surface today.
- Recording the agent's input gestures as overlays on the video.
