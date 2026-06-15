# CLI: Browser Viewer Becomes Opt-In (`--web`)

**Date:** 2026-06-11
**Status:** Approved

## Problem

`simtool run` and `simtool serve` open the web viewer in the default browser automatically.
Users who drive the viewer themselves (scripts, cmux, a pinned browser tab) get an unwanted
browser window on every run. The printed URL already makes self-serve workflows possible.

## Design

The server always starts and the viewer URL is always reported (console takeaway
`Open <url>`, or the `url` field in `--json` output). The browser is opened only when
explicitly requested with `--web`.

### `simtool run`

- Default: launch app + server, print URL, do NOT open the browser.
- `--web`: additionally open the browser viewer.
- `--native`: unchanged (native SwiftUI window). `--web --native` stays an error.

### `simtool serve`

- Default: start server, print URL, do NOT open the browser.
- New `--web` flag: open the browser viewer. `--web --window` is an error.
- `--no-open` becomes a deprecated no-op kept for script compatibility (help text says so);
  the detached-child invocation no longer passes it.

### Shared logic

One internal helper `shouldOpenBrowser(webRequested:json:nativeWindow:detachedChild:)`
encodes the decision for both commands and is unit-tested directly.

### URL must reach scripts

Noora suppresses its alerts when stdout is not a terminal, which would leave piped
`simtool run | …` invocations without the URL. When stdout is not a TTY (and `--json` is not
set), `runViewer` prints the same information as plain text (`SimTool server started`,
`Open <url>`, `Device: <name>`), so scripts can grep the address.

## Docs

README sections describing `run --web` as "the default viewer" are updated: the web viewer is
the default UI, but the browser is only auto-opened with `--web`; the printed URL supports
automation (e.g. open it in cmux).

## Testing

`SimToolCommandSurfaceTests`: parser accepts `serve --web`, keeps `--no-open` parsing,
rejects `serve --web --window`; `shouldOpenBrowser` truth table. Manual: `simtool serve`
prints the URL and does not open a browser; `simtool serve --web` opens one.
