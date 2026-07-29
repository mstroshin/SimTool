extension AgentSkill {
    public static let simtool = AgentSkill(name: "simtool", markdown: simtoolMarkdown)

    /// Mirrored by `skills/simtool/SKILL.md`, which is the copy to edit;
    /// regenerate this with `Scripts/sync-agent-skills.swift`.
    static let simtoolMarkdown = #"""
        ---
        name: simtool
        description: Build an iOS app and install + launch it on an iOS Simulator via the simtool CLI, then drive/inspect it (input, accessibility tree, logs, network, browser viewer), mock backend gRPC responses (simtool mock — return errors/custom bodies/delays for corner-case testing), and write or run declarative YAML UI tests (simtool test run — implicit-wait steps over the accessibility tree, launch profiles, state reset, in-test mocks, and a verdict that says whether a bug reproduces or a feature is confirmed; every run recorded as a session with video and evidence, also runnable from the viewer's Tests tab), and package a test with its verdict and evidence into one archive to hand to whoever comes next (simtool test export / show / run <archive>). Optionally launch with the app's own debug/test arguments — environment switch, jump to a screen, clean state, locale, deeplink, config overrides. Use when asked to "build and run", "запусти app", "rebuild", "build-only", "build & run", "compile and run", to run/launch with specific arguments, switch environment, open a specific screen on launch, reset app state, rebuild after code changes, tap/type/swipe on the simulator, read the accessibility tree, tail app logs (OSLog/stdout), inspect network traffic, mock/stub a backend response ("замокай ответ", "верни ошибку на этот запрос", "подмени ответ"), open the live simulator viewer, run or write a YAML UI test ("запусти ui тест", "прогони тест", "напиши тест для экрана"), review recorded test sessions, or hand a test and its proof to someone else ("передай тест", "экспортируй тест", "отправь тестировщику", "send the repro").
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
        Declarative YAML tests drive the app through the accessibility tree: every step
        polls until its target appears (or disappears), so tests need no sleeps. Needs a
        running SimTool server (the `serve`/`run` one, or pass `--server`). Every run is
        recorded as a test session — timestamped steps, screen recording and the run's
        evidence — persisted under `.simtool/test-sessions/<id>/` and shown in the
        viewer's Tests tab (History subtab) with the timeline synced to the video.

        Tests live in `.simtool/tests/*.yml`. Schema (full reference:
        `simtool test run --help`):

        ```yaml
        name: tab bar badges
        kind: feature                # optional; bug | feature — see "Verifying tests"
        reference: "PROJ-42"         # optional; free-form origin, stored, never parsed
        description: >               # what is tested and the expected result
          Home shows the summed count badge; opening the second tab clears the red dot.
        app: com.example.myapp.debug # relaunched before steps
        variables:                   # values for the ${VAR} the profile/setup below use
          ACCOUNT: "+34600000000"    #   the account this test runs as
        launch:                      # how to launch it
          profile: staging-account1  #   a `profiles:` entry from .simtool/config.yml
          arguments: [-RemoteConfig, some_flag, "true"]   # appended after the profile's
          env: { SOME_FLAG: "1" }    #   exported to the app as SIMCTL_CHILD_*
          deeplink: myapp://home     #   opened once the app is running
        reset:                       # simulator state, before launch
          defaults: true             #   clear the app's UserDefaults
          container: false           #   wipe the app's data container (keeps it installed)
          permissions: { att: deny, location: grant }     # grant | deny | reset
          locale: es_ES              #   applied as -AppleLocale / -AppleLanguages
          language: es
        mocks:                       # backend answers, applied before launch
          - method: "*/GetBadges"    #   gRPC full-method or HTTP path, `*` globs
            body: { count: 3 }       #   YAML or a JSON string (or `error: unavailable`)
            strict: true             #   must fire, or the run is reported as `infra`
        setup:                       # escape hatch: shell before launch, {udid}/{app}
          - xcrun simctl spawn {udid} defaults delete …   # substituted; failures logged
        timeout: 10                  # default per-step wait, seconds
        steps:
          - waitFor: { id: MainScreenView, timeout: 45 }
          - tap: { id: tabbar_second }
          - longPress: { id: tabbar_main, duration: 1 }
          - assertVisible: { text: "Welcome", criterion: AC-1 }   # id / label / text
          - assertHidden: { id: some-badge, timeout: 15 }
          - swipe: up
          - type: "hello"
          - wait: 2                  # escape hatch; prefer waitFor/assert
        ```

        Key semantics:
        - **Targets**: `id` matches accessibilityIdentifier exactly, `label` matches
          label/title exactly, `text` is a case-insensitive substring across fields;
          a bare string target means `text`.
        - **Launch profiles keep app-specific argv out of the test.** A test names a
          profile; the environment switches, the master switch and the shape of the
          login arguments live in `profiles:` in `.simtool/config.yml` (see
          [Project options](#project-options)), which refers to accounts as `${VAR}`.
        - **Writing the account inline is fine and is the simplest thing that works**:
          `launch: { arguments: [-Environment, stable, -FastLoginPhone, "+52 971 624 9725"] }`.
          argv reaches `simctl` as separate elements, so spaces need no escaping. Reach
          for this when the test carries its own arguments.
        - **`variables:` is for the two cases inline cannot cover**: parameterising a
          *shared* profile (the recipe is in `.simtool/config.yml` and must not carry one
          test's account), and needing the same value twice (typically a `setup:` launch
          plus the run's own launch) without keeping two copies in sync.
          ```yaml
          variables: { ACCOUNT: "+52 971 624 9725" }
          launch: { profile: staging-account1 }        # its argv refers to ${ACCOUNT}
          setup: [simtool app launch … -FastLoginPhone "$ACCOUNT"]
          ```
          Resolution order is `--var NAME=value`, then `variables:`, then the process
          environment — the file beating the environment on purpose, so a stale `export`
          in someone's shell cannot silently redirect the test to another account.
          `variables:` also reach `setup:` commands as shell environment.
        - **What belongs in the shell rather than in the file**: a real credential, or
          anything touching a production account. Refer to it as `${VAR}` and define it
          nowhere in the test; an unresolved reference fails the run rather than
          expanding to nothing, and an exported archive then names it as the receiver's
          to supply.
        - **`reset:` replaces hand-written state-clearing shell** and travels with the
          test. `permissions:` pre-answers the system alerts that would otherwise block
          the drive — `simtool input` cannot reach a system alert, and while one is up
          the a11y tree is unreadable, which reads exactly like a broken app. The
          notification prompt has no simctl backdoor: answer it once by hand.
        - **`mocks:` belongs in the test, not in `simtool mock set`.** Rules declared
          here are applied before launch, the run waits until the app confirms it has
          them, and they are cleared afterwards — so the scenario reproduces on another
          machine. Existing rules are cleared first, so a leftover manual rule cannot
          answer a call this test never accounted for.
        - **`setup` is for what `reset:` cannot express**; non-zero exits are recorded
          but never fail the test.
        - Discover ids for steps with `simtool ax find <needle>` / `ax tree` while
          driving the app manually.

        #### Verifying tests: `kind`, `criterion` and the verdict

        Add `kind:` and mark the assertions that check the claim with `criterion:`, and
        the run answers *whether the claim holds* instead of merely pass/fail:

        | Verdict | Exit | `kind: bug` | `kind: feature` |
        |---|---|---|---|
        | `satisfied` | 0 | not reproduced / fixed | feature confirmed |
        | `unsatisfied` | 1 | **bug reproduced** | feature not confirmed |
        | `inconclusive` | 2 | the run never reached a criterion — fix the test | same |
        | `infra` | 3 | the run cannot be trusted — see below | same |

        - **Assert the expected behaviour, not the current one.** A bug repro fails
          today — that failure *is* the reproduction — and the same file starts passing
          when the bug is fixed, so it becomes the regression guard. A test that asserts
          the broken state has to be inverted after the fix, and inverted tests get
          deleted.
        - Steps without a `criterion:` merely stage the scenario. A failure there is
          `inconclusive`, never a reproduction: it means the run never got to what it
          checks. Fix the test, not the report.
        - `kind: bug` stops at the first unmet criterion; `kind: feature` reports every
          criterion from one run, so "AC-1 ok, AC-3 unmet" does not cost three runs.
        - `infra` means the run proves nothing in either direction: a `strict:` mock
          never fired, the app never picked up its mock rules (its network logger is not
          running), or `reset:` could not be applied. An `infra` run is never reported as
          a pass — that is the direction that would tell a fixing agent the bug is gone.
        - `criterion:` labels are free-form: an id like `AC-2` when the work came with
          acceptance criteria, a short sentence when it came as prose. SimTool assumes no
          issue tracker; `reference:` is stored and displayed but never parsed.

        #### Evidence

        Unless `--evidence none`, the run arms the log capture itself, scopes it to its
        own launches, and writes into the session directory next to `video.mp4`:

        - `logs.jsonl` — the app's OSLog for the run (stdout is not captured: attaching a
          console would mean relaunching the app the run just launched)
        - `network.jsonl` — the app-emitted HTTP/gRPC events, each with `mocked` and the
          rule id that answered it
        - `state.jsonl` — `@SimToolDebugState` snapshots, when the state logger is linked
        - `mocks.json` — what each declared rule actually did, including `hits: 0`
        - `failure-step-<n>.png` / `-ax.txt` — screen and visible elements at the failure

        Step entries carry the log-cursor range and the start/end timestamps of their
        step, so the logs and requests belonging to one step can be sliced out of those
        files. `--evidence full` also captures a screenshot after every step.

        #### Handing the test to whoever comes next

        The point of a verifying test is that someone else re-runs it: the agent that
        fixes the bug, a reviewer, whoever tests the fix. `simtool test export` packs the
        test, the verdict, and the evidence into one `*.simflow.zip`:

        ```bash
        simtool test export .simtool/tests/tab-order.yml            # newest run of that test
        simtool test export --session <id> -o PROJ-42.simflow.zip   # a specific run
        simtool test export --no-video --no-evidence                # KBs instead of MBs
        simtool test show PROJ-42.simflow.zip                       # claim, verdict, what it carries
        simtool test show PROJ-42.simflow.zip --report              # the report written for a person
        simtool test show PROJ-42.simflow.zip --import              # replay it in this project's viewer
        simtool test run  PROJ-42.simflow.zip                       # run it here
        ```

        Inside: `manifest.json` (claim, verdict, criteria, provenance, `requires`),
        `test.yml` with `${VAR}` unexpanded, `report.md`, and `runs/<session>/` with
        `session.json`, the evidence files and `video.mp4`.

        - **The test says which account it runs as.** Write it under `variables:` and
          the archive travels ready-to-run — `requires.carries` lists what it brought,
          and the receiver needs no setup. Anything the test refers to but does not
          define stays a requirement (`requires.env`), checked *before* the simulator is
          touched; the receiver supplies it by exporting it or with `--var NAME=value`,
          which also overrides a value the test does define.
        - **The archive is self-contained about the launch.** When the receiver's
          `.simtool/config.yml` has no `profiles:` entry by that name, the launch the
          sender recorded stands in for it, and the run says so.
        - **Evidence is real account data.** `logs.jsonl` and `network.jsonl` hold the
          traffic and log output of the account the run used — team-internal; use
          `--no-evidence` for anywhere else. Both the export summary and `report.md` say
          this, so nobody has to remember it.
        - **Which build produced the verdict is part of the answer.** `test run` on an
          archive prints the installed app version/build next to the recorded one: a
          repro re-run against different code and pronounced fixed is the mistake this
          prevents.
        - The app binary never travels — `requires.app` names the bundle id and the
          receiver installs their own build, which is the point when verifying a fix.

        Commands: `simtool test run <test.yml|archive.simflow.zip>` (`--json` for the
        machine-readable report, `--repeat N` to check an intermittent claim,
        `--evidence none|failure|full`, `--no-session` to skip recording), `simtool test
        list` (recorded sessions with their verdicts), `simtool test export`,
        `simtool test show`. The viewer's Tests tab has two subtabs:
        **Tests** lists the YAML tests with Run buttons, live progress and results
        (`GET /api/v1/tests/definitions`, `GET/POST /api/v1/tests/run`); **History**
        shows recorded sessions with the video-synced timeline. One test runs at a time.

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
          test and its session are machine-local: `simtool test export` is how one leaves
          the machine, and `simtool test show --import` is how it arrives on another.
        - With a generated project (Tuist, XcodeGen, …), switching git branches can
          desync it; if a build fails with a missing input file, regenerate the project
          before rebuilding.

        """#
}
