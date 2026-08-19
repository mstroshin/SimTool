extension AgentSkill {
    public static let simtool = AgentSkill(
        name: "simtool",
        markdown: simtoolMarkdown,
        companions: [
            AgentSkill.Companion(fileName: "cartograph.md", markdown: simtoolCartographMarkdown),
        ]
    )

    /// The document `simtool init` installs as `skills/simtool/SKILL.md`.
    /// This literal is the only copy — edit it here.
    static let simtoolMarkdown = #"""
        ---
        name: simtool
        description: Build an iOS app and install + launch it on an iOS Simulator via the simtool CLI, then drive and inspect it (input, accessibility tree, logs, network, viewer), mock backend gRPC responses (simtool mock — errors, custom bodies, delays for corner cases), and run declarative YAML UI tests (simtool test run; writing one, and the bug/feature loop, belong to the `simtool-test` skill). Optionally launch with the app's own debug/test arguments — environment switch, jump to a screen, clean state, locale, deeplink, config overrides. Use when asked to "build and run", "запусти app", "rebuild", "пересобери", "build-only", to launch with specific arguments, switch environment, open a screen on launch, reset app state, tap/type/swipe on the simulator, read the accessibility tree, tail app logs (OSLog/stdout), inspect network traffic, mock a backend response ("замокай ответ", "верни ошибку на этот запрос"), open the live viewer, run a YAML UI test ("запусти ui тест", "прогони тест"), review recorded test sessions, or map the app's screens into the Картограф canvas ("составь карту приложения", "запусти картографа" — the pass algorithm lives in cartograph.md next to this file).
        argument-hint: [simtool args like app build / app launch --configuration Debug -- -MyAppFlag …]
        allowed-tools: [Bash, Read, AskUserQuestion]
        ---

        # Build, Run & Drive an iOS App on the Simulator (via simtool)

        Everything here runs through the **`simtool`** CLI (on `PATH`, installed from
        Homebrew). If it is missing or you want the latest:

        ```bash
        brew tap mstroshin/simtool
        brew trust mstroshin/simtool   # recent Homebrew requires this for third-party taps
        brew install simtool           # already installed → brew upgrade simtool
        ```

        ## Adapt this skill to your app

        This skill is app-agnostic on purpose. Two sections below are **placeholders you
        are expected to fill in for your project**, and once filled they become the
        authoritative reference for the agent:

        1. **[Project options](#project-options)** — your workspace/scheme/configuration.
        2. **[Launch argument catalog](#launch-argument-catalog)** — the debug/test argv
           *your app* reads. simtool knows nothing about them, so nothing but this table
           can document them.

        Everything else works unchanged for any app.

        ## `simtool --help` is the source of truth

        simtool owns its own command surface, and **it changes between versions** — new
        subcommands appear, flags get renamed, layouts move (e.g. 0.3.0 relocated the CLI
        out of the package root). So do **not** trust remembered command syntax. Before
        relying on any subcommand or flag, confirm it against the installed binary:

        ```bash
        simtool --help                 # the current list of subcommands
        simtool <subcommand> --help    # e.g. simtool app --help, simtool mock --help, simtool input --help
        simtool app build --help       # nested subcommands have their own --help too
        ```

        This skill deliberately does **not** reproduce simtool's flag tables — they would
        drift out of date. When you need exact options for `app`, `input`, `ax`, `logs`,
        `network`, `mock`, `test`, `serve`, `run`, `devices`, … read their `--help`.

        What this skill *does* own is everything `--help` can't tell you:

        - **The project options** — the workspace/scheme/configuration values to pass.
        - **The launch-argument catalog** — the debug/test argv the *app itself* reads.
        - **Env-var wiring** for the network/state loggers, and the mock/state caveats.
        - **Gotchas** — booting a simulator, the `.simtool/` layout, generated-project desync.

        ## Project options

        > **Fill this in.** Replace the placeholders with your project's real values, and
        > note the repo root the commands must run from.

        Run from the repo root. Pass these on every `app build` / `app launch` (confirm
        flag names with `simtool app --help`):

        ```bash
        --workspace MyApp.xcworkspace --scheme MyApp --configuration Debug --derived-data-path DerivedData
        ```

        Use `--project MyApp.xcodeproj` instead of `--workspace` if the project has no
        workspace.

        - **Configuration**: list yours and what each is wired to — typically a debug
          build against a mock/dev backend (bundle `com.example.myapp.debug`) and a
          staging build against a real test backend (`com.example.myapp.beta`). Note
          which configurations compile the debug arguments in at all: they are usually
          gated out of Release, so a Release build silently ignores the whole catalog.
        - **Device**: every command resolves `--device` first, then `simulator:` from
          `.simtool/config.yml`, then whatever is booted — and **refuses to guess when
          several simulators are booted and neither was given**. That refusal is
          deliberate: on a machine running parallel checkouts, guessing means driving
          another one's simulator, where the taps land elsewhere and the accessibility
          tree merely looks stale. `simtool app build/launch` boots nothing itself —
          boot first (`xcrun simctl boot <udid>` / open Simulator.app). List devices:
          `simtool devices --json`.
        - **Launch profiles**: name the argv recipes your tests and runs need in
          `profiles:` in `.simtool/config.yml`, and refer to them by name from a test's
          `launch.profile`. Values may interpolate `${VAR}` from the shell, so accounts
          and passcodes stay out of every file:

          ```yaml
          # .simtool/config.yml
          profiles:
            staging-account1:
              arguments: [-UITesting, -Environment, staging, -AutoLogin, "${ACCOUNT1}"]
              env: { SOME_FLAG: "1" }
          ```
        - **Lifecycle**: a launch is build (cached by source checksum → reuses the `.app`
          when nothing changed, else `xcodebuild`) → install if needed → **cold** launch
          (so launch args/env always take effect). Use the force-rebuild flag to bypass a
          valid cache. See `simtool app build --help` / `simtool app launch --help`.

        ### Canonical commands

        ```bash
        # Build only — fastest path for a quick syntax check
        simtool app build \
          --workspace MyApp.xcworkspace --scheme MyApp --configuration Debug \
          --derived-data-path DerivedData

        # Build (cached) + install + cold launch; app launch arguments go after `--`
        simtool app launch \
          --workspace MyApp.xcworkspace --scheme MyApp --configuration Debug \
          --derived-data-path DerivedData \
          -- <app launch arguments>
        ```

        ## Launch arguments vs. environment

        Two different channels — don't confuse them:

        - **Launch arguments (argv)** — everything in the catalog below. The app reads
          them via `CommandLine.arguments` / the `NSArgumentDomain` of `UserDefaults`.
          Forward them **after a literal `--`**.
        - **Environment variables** — forwarded with the env flag (`--env KEY=VALUE`,
          exported to the app as `SIMCTL_CHILD_*`). Used to arm the app-side SimTool
          network/state loggers (`SIMTOOL_NETWORK_LOGGER`, `SIMTOOL_STATE_LOGGER`,
          `SIMTOOL_SERVER_URL`).

        ```bash
        simtool app launch --workspace MyApp.xcworkspace --scheme MyApp \
          --configuration Debug --derived-data-path DerivedData \
          -- -UITesting -Environment mock -InitialScreenName Main
        ```

        ## When to invoke this skill

        Trigger phrases (EN/RU):
        - "build and run", "запусти приложение", "запусти app", "rebuild", "пересобери"
        - "build only", "только собери"
        - "open the app on the simulator", "launch with arguments …", "запусти с deeplink …"
        - "switch environment", "open a specific screen on launch", "reset app state"
        - "tap/type/swipe on the simulator", "read the accessibility tree", "tail the
          logs", "inspect the network", "open the live viewer"
        - "mock/stub a backend response", "замокай ответ", "верни ошибку на этот
          запрос", "подмени ответ бэкенда", "протестируй корнер-кейс с моком"
        - "map the app's screens", "составь карту приложения", "запусти картографа",
          "пройди по приложению и нарисуй карту экранов" → follow
          [cartograph.md](cartograph.md)

        Do NOT invoke for:
        - Test-scheme orchestration — that belongs to your CI / UI-testing skill.
          (simtool can run schemes via `simtool app test`, but orchestration doesn't
          belong here.)
        - Pure builds without launch — still OK, just use `simtool app build`.

        ## CRITICAL: ask the user first when launching with scenario arguments

        A plain build & run (or build-only) needs no questions — just run it.

        But do NOT guess argument values. Accounts, environments, passcodes, screen
        names, deeplinks, etc. are environment- and account-specific. When the user
        wants a scenario but did not give exact values:

        1. Ask with `AskUserQuestion` which scenario / arguments they want and the
           concrete values.
        2. Only then build the argument string and launch.

        If the user already gave exact arguments/values, skip the question and use them.

        ## Launch argument catalog

        > **Fill this in.** These are *your app's* debug/test argv — passed after `--`,
        > read by the app, and usually compiled only into non-Release builds. They are
        > not simtool flags, so `simtool --help` does not list them; this table is their
        > only reference. A launch is always a cold launch, so they always apply.
        >
        > Group them the way your app groups them. The columns below carry the
        > information an agent actually needs; keep them.

        "Master switch?" = requires your app's UI-testing master switch (if it has one)
        to also be present. "Build" = which configurations compile the option in.

        ### Authentication / session
        | Argument | Value | Master switch? | Build | Effect |
        |---|---|---|---|---|
        | `-AutoLogin…` | account identifier | no | non-Release | Log in automatically at cold start. |
        | `-hardLogout` | flag | yes | non-Release | Reset the session on launch. |

        ### Initial screen
        | Argument | Value | Master switch? | Build | Effect |
        |---|---|---|---|---|
        | `-InitialScreenName` | screen name | no | non-Release | Jump directly to a screen at launch. |
        | `-InitialScreenData` | base64 string | no | non-Release | Data payload for the initial screen. |

        ### Environment & config overrides
        | Argument | Value | Master switch? | Build | Effect |
        |---|---|---|---|---|
        | `-Environment` | `mock`, `dev`, `staging`, `production` | depends | non-Release | Select the backend environment. |
        | `-RemoteConfig` | `<key> <value>` (repeatable) | yes | debug only | Override remote-config values. |
        | `-AppStorage` | `<key> <value>` (repeatable) | yes | non-Release | Set `UserDefaults` values. |

        ### Reset / clean state
        | Argument | Value | Master switch? | Build | Effect |
        |---|---|---|---|---|
        | `-FullCleanUserDefaults` | flag | yes | non-Release | Reset all UserDefaults suites. |
        | `-disableOnboardings` | flag | yes | non-Release | Mark all onboardings as already seen. |

        ### UI / testing / locale
        | Argument | Value | Master switch? | Build | Effect |
        |---|---|---|---|---|
        | `-UITesting` | flag | — | non-Release | Typical master switch: disables animations, clears feature toggles, unlocks the options marked "yes" above. Side effects usually make it unsuitable for testing a real account. |
        | `-ShowLocalizationKeys` | flag | no | — | Show localization keys instead of translated text. |
        | `-AppleLanguages` | e.g. `(es)`, `(en)` | no | any | Standard iOS language override. |
        | `-AppleLocale` | e.g. `es_ES`, `en_US` | no | any | Standard iOS region override. |

        ### Deeplink
        | Argument | Value | Master switch? | Build | Effect |
        |---|---|---|---|---|
        | `-Deeplink` | url, e.g. `myapp://invite` | yes | non-Release | Open a deeplink on launch. |

        ### Catalog examples

        ```bash
        APP_OPTS=(--workspace MyApp.xcworkspace --scheme MyApp --derived-data-path DerivedData)

        # Mock backend, jump straight into the app
        simtool app launch "${APP_OPTS[@]}" --configuration Debug \
          -- -UITesting -Environment mock -InitialScreenName Main

        # Fully reset app state
        simtool app launch "${APP_OPTS[@]}" --configuration Debug \
          -- -UITesting -hardLogout -FullCleanUserDefaults -disableOnboardings

        # Spanish localization keys visible
        simtool app launch "${APP_OPTS[@]}" --configuration Debug \
          -- -AppleLanguages "(es)" -ShowLocalizationKeys
        ```

        ## Driving & inspecting the running app

        After launch, drive and read the simulator with the subcommands below. **For the
        exact flags of each, run `simtool <command> --help`** — only the wiring and
        caveats that `--help` won't tell you are spelled out here. Most commands accept
        `--device` and `--json`.

        ### Screenshots
        There is no `simtool screenshot` subcommand. Either fetch one from a running
        server (`GET /api/v1/screenshot`, see the viewer below) or use
        `xcrun simctl io <udid> screenshot /tmp/shot.png` and Read the PNG. The first
        frame is usually the splash — capture again to see the settled screen.

        ### Input · accessibility · logs
        - `simtool input …` — taps and long-presses (by label / a11y-id / coordinates),
          type, swipe, hardware buttons.
        - `simtool ax …` — read the accessibility tree / find an element.
        - `simtool logs …` — OSLog stream; a `--stdout` mode **relaunches** the app to
          attach its console (useful when the app logs richly to stdout — networking,
          navigation, etc.). Note OSLog can be quiet while the app is idle.

        ### Network (app gRPC/HTTP via the logger)
        `simtool network …` covers a system-level snapshot and app-emitted events. App
        events require the app to be **launched with the network logger armed**:

        ```bash
        simtool serve --detach --json --port 3311
        simtool app launch --workspace MyApp.xcworkspace --scheme MyApp --derived-data-path DerivedData \
          --env SIMTOOL_NETWORK_LOGGER=1 --env SIMTOOL_SERVER_URL=http://127.0.0.1:3311
        simtool network events --server http://127.0.0.1:3311 --json   # request paths, status, timings
        ```

        ### Mock backend responses (`simtool mock`)
        Live-replace **unary gRPC** responses to test corner cases (errors, payloads,
        delays) without the real backend: the app's `SimToolNetworkInterceptor`
        short-circuits a matching call and synthesizes the response. Active only in
        non-Release builds with the network logger armed (same env as above); the app
        polls the server (~2s) and applies rules on the fly — no relaunch. Flag syntax:
        `simtool mock --help` (and `simtool mock set --help`). What `--help` won't tell you:

        - **Find the method path** first by triggering the call once and reading
          `simtool network events --protocol grpc` (the request `path`).
        - `--error` takes a canonical gRPC status name (`unavailable`, `deadlineExceeded`,
          `notFound`, …); the CLI rejects unknown names.
        - A `--body` must decode into the method's typed protobuf Response. If it can't
          (wrong/unknown fields), the mock is **not** applied and the real backend
          answers — a malformed mock never breaks the app. Prefer `--error` for corner
          cases, or mirror a real response's shape.
        - **Unary only** — streaming RPCs and plain HTTP are not mocked yet.
        - Needs an app linked against a SimTool version that exposes the mock store.
        - Mocked calls show a 🎭 badge in the viewer's Network tab.
        - **For a test, declare the rules in the test's `mocks:` block instead.** Rules
          set from the CLI live outside the test, so a scenario that needs a specific
          backend answer only reproduces on the machine where someone typed them. Use
          `simtool mock set` while exploring, then move what worked into the test —
          where `strict: true` also makes a rule that never fired fail the run.

        ### UI tests (`simtool test run`)
        Declarative YAML tests in `.simtool/tests/*.yml` drive the app through the
        accessibility tree: every step polls until its target appears (or disappears),
        so tests need no sleeps. A test carries everything needed to stage its scenario,
        so it reproduces on another machine: `launch:` (a named profile from
        `.simtool/config.yml` plus inline argv/env), `reset:` (UserDefaults, data
        container, permission alerts, locale) and `mocks:` (backend answers, applied
        before launch).

        A run needs no `serve` step and no build of your own: with `build:` in
        `.simtool/config.yml` it rebuilds and reinstalls the app when the sources
        changed, and with no server running it starts one on a free port. Both happen
        *before* the recorder starts — together with `reset:` and `setup:` — so the video
        holds the test rather than an Xcode build, while the staging still appears in the
        timeline. The server it started is **left running**, because it is what serves
        the viewer showing that run.

        Every run is recorded as a reviewable test session — timestamped steps, a screen
        recording and the run's evidence — under `.simtool/test-sessions/<id>/`, where a
        `report.md` written for a person sits next to `video.mp4`; the viewer's Tests tab
        lists the tests with Run buttons and live progress, and its History subtab the
        recorded sessions with the timeline synced to the video — including a run started
        from the command line, which the tab follows as it happens. Commands:
        `simtool test run <file>` (`--json` for the machine-readable report, `--repeat N`
        to check an intermittent claim, `--evidence none|failure|full`, `--no-session` to
        skip recording, `--no-build` to judge what is installed, `--stop-server` to stop
        a server the run started) and `simtool test list` (this project's recorded
        sessions with their verdicts; it needs a server started for this project, or
        `--server`). One test runs at a time.

        **To write one, or to run the bug/feature loop, use the `simtool-test` skill** —
        it owns the file format, the criteria and the verdicts.

        #### Reading live model state (`@SimToolDebugState`)
        To observe view-model state while driving the app, use the state logger:

        1. **Annotate** the model: `import SimToolStateLogger`, put `@SimToolDebugState`
           on the `@Observable` / `ObservableObject` class, and register the instance —
           e.g. at the end of `init`:
           ```swift
           #if DEBUG
           if #available(iOS 17.0, *) {
               Task { @MainActor in SimToolState.track(self, poll: .milliseconds(500)) }
           }
           #endif
           ```
           (`@Observable` → diff via observation; plain `ObservableObject` → polling, so
           pass `poll:`.) Add the `SimToolStateLogger` product to the target's
           dependencies; with a generated project (Tuist, XcodeGen, …) regenerate and
           rebuild afterwards.
        2. **Launch with the logger armed**: `--env SIMTOOL_STATE_LOGGER=1 --env
           SIMTOOL_SERVER_URL=http://127.0.0.1:<port>`.
        3. **Read snapshots incrementally**:
           ```bash
           curl -s "http://127.0.0.1:<port>/api/v1/state/events?since=<cursor>&limit=500"
           # → { events:[{name, seq, snapshot, launchId, cursor}], nextCursor }
           ```
           Poll with `since=nextCursor`. Keep only events whose `launchId` matches the
           running app (the latest from `GET /api/v1/launches`), or a previous run bleeds
           into step 1.

        **What state logging cannot see — get it from OSLog instead:** the serializer
        emits only scalars and collections of scalars. `Decimal` (money amounts), nested
        structs/classes, and enums-with-payload render as `<Type>` placeholders, so their
        changes produce no event. Likewise, state that never lands in a tracked property
        (e.g. an error routed straight to a presenter, leaving `errorState == nil`) is
        invisible here — grab it from OSLog.

        ### Live browser viewer
        `simtool serve` opens a viewer (stream + Logs + Network panels); scoping
        `--app <bundle>` captures that app's OSLog **and** stdout and auto-opens the Logs
        panel. `simtool run` reads `.simtool/config.yml` and does build → launch → viewer
        in one step. Flags: `simtool serve --help` / `simtool run --help`.

        ### Картограф — the screen map
        The viewer's Картограф tab renders the app as a map: one node per screen (its
        screenshot, deeplinks found in the source, localization keys), arrows for
        forward navigation only. A map can be produced by the built-in robot
        (`POST /api/v1/explore/start`) or by the agent walking the app itself — the full
        pass algorithm (settle-wait, screen identity and dedup, deeplinks from source
        without opening them, edge rules, the `graph.json` format) is in
        **[cartograph.md](cartograph.md)**, installed next to this file.

        ## Workflow

        1. Decide the configuration (mock-friendly debug vs. a real backend). Ask if
           unclear.
        2. If launching a scenario, ask the user (`AskUserQuestion`) for the concrete
           values — do not guess account/environment/screen. Skip for plain build & run
           / build-only.
        3. Build the launch-argument list (after `--`).
        4. Launch via `simtool app launch …` with the project options and chosen
           config/device. Stream stdout — a fresh build can take ~30s to several minutes;
           simtool's progress lines are useful feedback.
        5. For UI verification capture a screenshot and Read the PNG, or use the live
           viewer.

        ## Notes

        - `simtool app build` / `app launch` boot nothing themselves — boot a simulator
          first (`xcrun simctl boot <udid>` / open Simulator.app) or pass an
          already-booted device. `simtool serve` and `simtool run` do boot the simulator
          named under `simulator:` in `.simtool/config.yml` (which is also why a test run
          that starts its own server can boot it); with nothing named they use whichever
          simulator is already booted.
        - Scenarios that talk to a real backend (auto-login, remote config) need the
          device to have network access to it; failures are typically logged and leave
          the regular screen for manual entry.
        - simtool keeps per-project state in `.simtool/` at the repo root (self-gitignored
          via an auto-created `.gitignore`): the config `.simtool/config.yml` (simulator,
          app, build, launch profiles), build checksum metadata in `.simtool/build/`,
          YAML tests in `.simtool/tests/`, and recorded sessions with their evidence in
          `.simtool/test-sessions/`. Discovered by walking up from the working directory,
          so run simtool from inside the repo. Because the directory is gitignored, a
          test travels as a file: send the YAML, and the session's `report.md` or
          `video.mp4` when they help.
        - With a generated project (Tuist, XcodeGen, …), switching git branches can
          desync it; if a build fails with a missing input file, regenerate the project
          before rebuilding.

        """#

    /// The companion `simtool init` installs next to SKILL.md as `cartograph.md`.
    /// This literal is the only copy — edit it here.
    static let simtoolCartographMarkdown = #"""
        # Картограф: crawl an app into a screen map (via simtool)

        The Картограф tab of the simtool viewer (`simtool serve` → 🗺️ Картограф) draws a
        map of the app: one card per screen with its screenshot, arrows for forward
        navigation, and a details drawer with the screen's deeplinks and localization
        keys. The project has **one** map — a single store under `.simtool/explore/`:

        ```
        .simtool/explore/
        ├── graph.json          # the map: nodes (screens) + edges (transitions)
        └── shots/
            ├── s-main.png      # one screenshot per node, named `<node id>.png`
            └── s-profile.png
        ```

        Every run — robot or agent — opens this store and modifies it: attaches to the
        screens it already holds, adds the new ones, retakes the screenshots of the
        screens it reaches. Runs never create a second copy. (`run` in `graph.json`
        describes the *latest* run; `stats.steps`/`stats.relaunches` accumulate across
        runs.) The tab re-reads the store every few seconds, so nodes appear on the
        canvas as they are written.

        Two ways to grow the map:

        - **The built-in robot** — `POST /api/v1/explore/start` (stop it with
          `POST /api/v1/explore/stop`). Fully automatic; it taps everything reachable
          and needs no agent. It resumes from `graph.json` on its own: known screens
          are matched by their structural key, and their persisted `triedActionKeys`
          keep it from re-tapping what previous runs already tried. Deeplinks it
          annotates the way this pass does — mined from the source and matched to
          screen names, never opened — so a screen enters the map only when a tap
          reaches it.
        - **The agent pass** — this document. *You* drive the app with simtool
          primitives and modify the store yourself. Use it when the blind crawl
          is not enough: you can name screens properly, attribute deeplinks by reading
          the source instead of probing, and judge what is worth tapping.

        Trigger phrases: "составь карту приложения", "запусти картографа", "пройди по
        приложению и нарисуй карту экранов", "map the app's screens".

        ## The pass, step by step

        Launch once, then repeat the per-screen step until every reachable screen is
        mapped or the budget is spent.

        **0. Preflight.** Start the viewer (`simtool serve --detach --json`), make sure
        a simulator is booted. Open the store: read `.simtool/explore/graph.json` if it
        exists — its nodes are your dedup base and its `run.app` must match the app you
        are about to map (a different app means the store is another app's map: start
        it over). If there is no store yet, create `.simtool/explore/shots/` and write
        an initial `graph.json` with empty `nodes`/`edges`. Update `run` to describe
        your pass (fresh `id` timestamp, `startedAt`, `finishedAt: null`). Cold-launch
        the app with the project's usual options (`simtool app launch … -- <args>`); if
        `.simtool/config.yml` has a launch profile named `explore` (mock backend,
        auto-login), use its argv — the map must not depend on backend luck. Do not run
        the pass while the built-in robot is scanning: one run owns the simulator (and
        the store) at a time.

        **1. Wait until the screen is truly loaded.** Read the accessibility tree
        (`simtool ax tree --json`) every second or so until two consecutive reads are
        structurally identical AND no node's id/type contains a loading marker:
        `skeleton`, `shimmer`, `spinner`, `loading`, `activityindicator`, `progress`.
        A screenshot taken mid-shimmer maps a loading state, not the screen — wait it
        out (bounded: after ~10 extra reads, accept the screen as it is).

        **2. Identify the screen** from the accessibility tree, strongest signal first:

        1. a *unique* identifier on a near-full-screen container (`ProfileScreen`) —
           SwiftUI/UIKit screens often carry one;
        2. the dominant identifier prefix over *distinct* ids (`MainScreen-Balance`,
           `MainScreen-TransferButton` → `MainScreen`);
        3. the navigation-bar title (a short StaticText near the top of the screen).

        That identity becomes the node's `title` and — more importantly — its dedup key.

        **3. One node per screen — never two.** If a screen with this identity already
        has a node in `graph.json`, do not add another: you navigated to a known screen,
        or to another *state* of it (a spinner, an empty list, an expanded section —
        states differ structurally, screens differ by identity). Content — balances,
        names, dates — never distinguishes screens.

        **4. Screenshot and node.** Capture `xcrun simctl io <udid> screenshot`,
        downscale (`sips -Z 700 <png>`), save as `shots/<nodeId>.png` — on first
        sighting of a new screen, and once per pass for a known screen you reach
        (overwrite its old shot: the store's pictures must show the app as it is now).
        Node ids may contain only letters, digits, `-` and `_` — they become file
        names and the shot URL (`/api/v1/explore/shot?node=<id>`).

        **5. Deeplinks — from the source code, never by opening them.** In the project
        checkout, find out whether a deeplink opens this screen: URL literals
        (`grep -rn "myapp://"` — the schemes are in the app's Info.plist under
        `CFBundleURLSchemes`), and the router/coordinator that maps routes to screens.
        Record the URLs in the node's `deeplinks`. Do **not** open a deeplink during
        the pass: the map records how a user reaches the screen, a probe perturbs the
        navigation stack, and the source already answers the question.

        **6. Localization keys.** Take the screen's visible strings (labels/titles from
        *its own* subtree of the accessibility tree — a sheet's tree still carries the
        presenting screen underneath) and reverse-look them up in the project's
        localization tables (`*.strings`, `*.xcstrings`, `*.stringsdict`): a key whose
        value equals a visible string belongs in the node's `localizationKeys`.

        **7. Publish.** Append the node (and edge, if the rules below allow one) to
        `graph.json`, update `stats`, and write **atomically** — write `graph.json.tmp`,
        then `mv` it over. The tab polls every ~3 s; a torn write shows up as a broken
        map until the next write.

        **8. Tap and descend.** Pick an untried tappable element (Buttons, Cells,
        Links, tab items) and `simtool input tap …`. Skip destructive vocabulary —
        logout / sign out / delete / remove / call / «выйти» / «удалить» / «позвонить».
        Then return to step 1 and classify where the tap landed:

        - **A new screen** → a new node at `depth = depth(from) + 1`, plus an edge —
          unless the edge rules veto it.
        - **A known screen** → no new node, and usually no edge (see the rules).
        - **The same screen** → a state change, not a transition; keep tapping, or
          scroll to reveal content below the fold.
        - **Outside the app** (app switcher, Safari, a crash to SpringBoard) →
          relaunch and continue; what is not the app is not on the map.

        When the current screen has no untried actions left, replay recorded taps to
        reach the closest screen that still has some, or relaunch and descend again.

        ## Edge rules — when NOT to draw a connection

        The map draws **forward navigation only**. Never record an edge when:

        - **The tap goes back.** A back / close / ✕ / cancel control, or any tap that
          lands on the screen you arrived from — iOS back buttons are titled after the
          previous screen, so judge by the destination, not the label. Return edges say
          nothing about the app's structure and tangle the map.
        - **The destination is not deeper.** Only `depth(to) > depth(from)` edges are
          drawn; a hop to a same-depth or shallower screen (the home tab, a modal's ✕,
          a cross-tab jump) is the crawl retreating, not the app navigating forward.
        - **Source and destination are the same node.** A state change inside one
          screen is not a transition.

        One edge per (from, to, control): a repeated tap increments the edge's `count`
        instead of adding a parallel arrow.

        ## `graph.json` — the format

        Top level: `schemaVersion` (currently 2), `run`, `stats`, `nodes`, `edges`.
        Keys are camelCase, timestamps ISO 8601. The run id is a
        `2026-08-19T14-03-00`-style timestamp naming the latest pass over the store.

        ```json
        {
          "schemaVersion": 2,
          "run": {
            "id": "2026-08-19T14-03-00",
            "app": "com.example.myapp",
            "device": "iPhone 16",
            "profile": "explore",
            "startedAt": "2026-08-19T11:03:00Z"
          },
          "stats": { "screens": 2, "transitions": 1, "steps": 5, "relaunches": 1 },
          "nodes": [
            {
              "id": "s-main",
              "title": "MainScreen",
              "fingerprint": "s-main",
              "key": "s-main",
              "screenshot": "shots/s-main.png",
              "depth": 0,
              "visits": 3,
              "states": 1,
              "actionsTotal": 8,
              "actionsTried": 5,
              "firstSeenAt": "2026-08-19T11:03:20Z",
              "deeplinks": ["myapp://main"],
              "localizationKeys": ["main.title", "main.transfer_button"]
            },
            {
              "id": "s-profile",
              "title": "ProfileScreen",
              "fingerprint": "s-profile",
              "screenshot": "shots/s-profile.png",
              "depth": 1,
              "visits": 1,
              "actionsTotal": 4,
              "actionsTried": 1,
              "firstSeenAt": "2026-08-19T11:04:02Z"
            }
          ],
          "edges": [
            {
              "id": "e-1",
              "from": "s-main",
              "to": "s-profile",
              "action": { "kind": "tap", "targetId": "MainScreen-ProfileButton", "targetLabel": "Профиль" },
              "count": 1
            }
          ]
        }
        ```

        Field notes:

        - Node — required: `id`, `title`, `fingerprint`, `screenshot`, `depth`,
          `visits`, `actionsTotal`, `actionsTried`, `firstSeenAt`; optional: `key`,
          `states`, `triedActionKeys`, `deeplinks`, `localizationKeys`. `fingerprint`
          is the robot's structural hash and `key` its screen-identity hash — the
          robot resumes by them; in an agent pass any stable unique string works for
          both — reuse the node id. `triedActionKeys` is the robot's persisted
          frontier; leave it alone if you did not compute it.
        - `depth` is the shortest observed distance from the launch screen; the canvas
          lays columns out by depth, so keep it honest (shrink it if you rediscover a
          screen closer to the root — and re-check the depth rule for its edges).
        - Edge — required: `id`, `from`, `to`, `action` (`kind` plus optional
          `targetId`/`targetLabel` — the tab renders them as the arrow label), `count`.
        - Update `stats` as you go; when the pass ends, set `run.finishedAt`.

        """#
}
