# `.simtool/` project directory

**Date:** 2026-06-12
**Status:** Approved

## Goal

Everything SimTool stores for a project lives in a single `.simtool/` directory
inside that project (the project simtool is invoked from):

- `.simtool/config.yml` — the project config (renamed from `.simtool.yml`)
- `.simtool/build/<identityKey>.json` — build checksum metadata + install records
- `.simtool/test-sessions/<session-id>/` — test session artifacts (session.json, video.mp4)
- `.simtool/.gitignore` — auto-created with `*` so git ignores the whole directory

This is a clean break: no fallback to the old `.simtool.yml` name, no legacy
detection or migration hints, no reading of old `~/.simtool/test-sessions`
sessions, no reuse of old checksum metadata in `~/Library/Caches/SimTool`.
DerivedData stays in `~/Library/Caches/SimTool` (it can weigh gigabytes and is
rebuildable); only the checksum metadata moves into the project.

## Directory resolution: `SimToolDirectory` (SimToolCore)

One shared helper defines how the `.simtool/` directory is found:

- `name = ".simtool"`, `configFileName = "config.yml"`.
- **Locate:** walk up from a start directory (default: cwd) looking for an
  existing `.simtool` directory; return the first match.
- **Resolve:** locate, or fall back to `<startDirectory>/.simtool` when no
  existing directory is found anywhere up the tree.
- **Ensure:** create the directory if missing and write `.gitignore`
  containing `*` into it (only when the gitignore file does not already
  exist, so a user edit is never overwritten).

All consumers (config loader, build cache, test session store) derive their
paths from this helper so the anchor rule lives in one place.

## Config: `.simtool/config.yml`

`ProjectConfigLoader`:

- Discovery walks up from cwd looking for `.simtool/config.yml` (via the
  shared locate rule applied to the config file path).
- Miss → error: `No .simtool/config.yml found in the current directory or any
  parent. Create one or pass --config <path>.`
- `--config <path>` is used verbatim as today (no upward search). The
  containing directory of the explicit config file is treated as the
  `.simtool` directory for everything else in that invocation.
- Relative paths inside the config (`build.workspace`, `build.project`,
  `build.derivedDataPath`) currently resolve against the config file's
  directory. They now resolve against the **project root** (the parent of the
  `.simtool` directory), so existing configs keep meaning the same thing after
  `mv .simtool.yml .simtool/config.yml`.

## Build checksum metadata: `.simtool/build/`

`SimulatorAppBuildCache` splits its single root into two:

- `metadataRoot` — `<simtoolDir>/build`; holds `<identityKey>.json` files
  (checksum, app bundle path, bundle id, install records). Writing ensures the
  `.simtool` directory + `.gitignore` exist.
- `derivedDataRoot` — unchanged `~/Library/Caches/SimTool/app-builds/DerivedData`.

The `.shared` singleton is removed. Each call site constructs the cache with a
resolved `.simtool` directory:

- Config-driven commands (`run`, `open`, interactive) anchor on the loaded
  config's `.simtool` directory.
- Flag-driven commands (`app build/launch/test`) anchor on cwd via the shared
  resolve rule (found `.simtool` up the tree, else `cwd/.simtool`).

## Test sessions: `.simtool/test-sessions/`

- `TestSessionStore.defaultRoot` (`~/.simtool/test-sessions`) is removed; the
  store always receives an explicit root.
- `simtool run` passes `<configSimtoolDir>/test-sessions` into
  `StreamServer.Config.testSessionsRoot` (mechanism already exists).
- Standalone `simtool serve` resolves the root from cwd via the shared resolve
  rule at startup.
- The directory (and `.simtool/.gitignore`) is created lazily when the first
  session is written, not at server start.

## Out of scope / unchanged

- DerivedData location and cache-eviction behavior.
- The fingerprint walk already excludes `.simtool` from hashing — no change.
- No automatic migration of old configs, sessions, or cache metadata.

## Documentation and tests

- Update CLI help texts that mention `.simtool.yml` (`run`, `open`,
  interactive `--config` help).
- Update README and any docs describing config discovery or test session
  storage.
- Update existing tests (`SimToolCommandSurfaceTests`,
  `InteractiveDeeplinksTests`, `ProjectConfig` loader tests,
  `TestSessionController` tests) and add coverage for: upward `.simtool`
  discovery, fallback-to-cwd resolution, `.gitignore` auto-creation (and
  non-overwrite), and config-relative path resolution against the project
  root.
