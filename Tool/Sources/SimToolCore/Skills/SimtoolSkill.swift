extension AgentSkill {
    public static let simtool = AgentSkill(name: "simtool", markdown: simtoolMarkdown)

    /// Mirrored by `skills/simtool/SKILL.md`, which is the copy to edit;
    /// regenerate this with `Scripts/sync-agent-skills.swift`.
    static let simtoolMarkdown = #"""
        ---
        name: simtool
        description: Build an iOS app and install + launch it on an iOS Simulator via the simtool CLI, then drive/inspect it (input, accessibility tree, logs, network, browser viewer), mock backend gRPC responses (simtool mock — return errors/custom bodies/delays for corner-case testing), and write or run declarative YAML UI tests (see the `simtool-test` skill for writing one and for the bug/feature loop). Optionally launch with the app's own debug/test arguments — environment switch, jump to a screen, clean state, locale, deeplink, config overrides. Use when asked to "build and run", "запусти app", "rebuild", "build-only", "build & run", "compile and run", to run/launch with specific arguments, switch environment, open a specific screen on launch, reset app state, rebuild after code changes, tap/type/swipe on the simulator, read the accessibility tree, tail app logs (OSLog/stdout), inspect network traffic, mock/stub a backend response ("замокай ответ", "верни ошибку на этот запрос", "подмени ответ"), open the live simulator viewer, run or write a YAML UI test ("запусти ui тест", "прогони тест", "напиши тест для экрана"), or review recorded test sessions.
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
        before launch). A running server is not a prerequisite — with none, the run
        starts one on a free port and stops it again afterwards.

        Every run is recorded as a reviewable test session — timestamped steps, a screen
        recording and the run's evidence — under `.simtool/test-sessions/<id>/`, where a
        `report.md` written for a person sits next to `video.mp4`; the viewer's Tests tab
        lists the tests with Run buttons and live progress, and its History subtab the
        recorded sessions with the timeline synced to the video. Commands:
        `simtool test run <file>` (`--json` for the machine-readable report, `--repeat N`
        to check an intermittent claim, `--evidence none|failure|full`, `--no-session` to
        skip recording) and `simtool test list` (recorded sessions with their verdicts).
        One test runs at a time.

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

        - simtool boots nothing itself — boot a simulator first (`xcrun simctl boot
          <udid>` / open Simulator.app) or pass an already-booted device.
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
}
