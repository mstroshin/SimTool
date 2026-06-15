# Logs tab: remove source/bundle-id controls, default subsystem filter chip

Date: 2026-06-12
Status: approved

## Problem

The Logs tab in the web UI (`Sources/SimToolWeb/WebViewer.swift`) has three input
surfaces: the shared filter field (`inspectorFilter`, substring chips over
message/subsystem/category/process/level), a source select (`logsSource`:
all/oslog/stdout), and a bundle-id input (`logsApp`). The target app now logs
exclusively via OSLog, so the stdout source and the extra controls are dead
weight. One filter field is enough.

## Decision

All changes are confined to `Sources/SimToolWeb/WebViewer.swift`.

1. **Remove controls.** Delete the `logsSource` select and the `logsApp` input
   from the `logsControls` block, along with their JS references: the
   source-based filtering branch in `renderLogsList`, and the `change`
   listeners. Keep the `logsStatus` indicator.
2. **OSLog-only capture.** Store `config.logApp` from the `/config` bootstrap
   response in a JS variable. `startLogsCapture` sends `{ app }` (no
   `captureStdout`), so stdout/`print` capture is never started.
   `restartLogsCapture` is no longer reachable from the UI and is removed.
   Server-side capture remains scoped by the existing `appLogPredicate`
   (subsystem BEGINSWITH bundle id OR process match), unchanged.
3. **Empty filter by default.** ~~Seed a default include chip with the bundle
   id~~ — reverted same day by user request: the filter field starts empty;
   capture is already scoped server-side by the predicate, so the chip added
   noise rather than signal.
4. **Selection context menu (added in the same change).** Right-clicking a log
   row with an active text selection replaces the "Copy entry" menu with three
   items acting on the selected text: **Copy Selected** (clipboard, verbatim),
   **Include Selected** and **Exclude Selected** (create the corresponding
   filter chip; multi-line selections are collapsed to one line because chips
   match a single-line haystack). Without a selection the menu still shows
   "Copy entry".
5. **Field-scoped filter syntax (follow-up, same day).** On the Logs tab a
   term written as `field:text` — where field is one of `message`,
   `subsystem`, `category`, `process`, `level` — matches only that field
   instead of the joined haystack. Works for chips (Enter, including the `-`
   exclude form) and for the live input. Unknown prefixes (e.g. `https:`)
   stay plain substring terms; other tabs are unaffected. This reverses the
   earlier "rejected alternative": with the default chip gone, precise
   subsystem filtering needed an explicit syntax.

## Alternatives rejected

- Prefilling the bundle id as text in the filter input: easy to clobber, and
  the live input ANDs with chips, blocking ad-hoc searches.
- A structured `subsystem:` chip syntax: more precise but a new mechanism for
  a single use case (YAGNI).

## Out of scope

- Backend (`LogCapture.swift`, `StreamServer.swift`) stays as is; the
  `captureStdout` API field remains for CLI/other clients.
- No change to log entry rendering or polling cadence.

## Testing

- Existing Swift tests must keep passing.
- If WebViewer HTML/JS has snapshot/content tests, update them; otherwise
  verify manually by running the server: Logs tab shows only the filter field
  plus status, the bundle-id chip is present by default, removing it widens
  the view, and capture status reports oslog only.
