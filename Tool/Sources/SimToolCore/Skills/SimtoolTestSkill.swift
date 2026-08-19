extension AgentSkill {
    public static let simtoolTest = AgentSkill(name: "simtool-test", markdown: simtoolTestMarkdown)

    /// The document `simtool init` installs as `skills/simtool-test/SKILL.md`.
    /// This literal is the only copy — edit it here.
    static let simtoolTestMarkdown = #"""
        ---
        name: simtool-test
        description: Write a declarative YAML UI test for an iOS app and drive the red→green loop with it — encode a reported bug or an unbuilt feature as a test that asserts the *expected* behaviour, run it with `simtool test run` (whose exit code is the verdict: 0 satisfied, 1 unsatisfied, 2 inconclusive, 3 infra), change the product, and re-run the same file as the regression guard. Covers the test file format (launch profiles, state reset, in-test backend mocks, criteria), finding element ids, reading the evidence a run leaves behind, and handing a test to another developer or agent. Use when asked to reproduce a bug on the simulator, prove a bug exists before fixing it, write a repro test, write a test for acceptance criteria before the feature exists, verify a fix, or share a test — "напиши тест на баг", "напиши тест для экрана", "воспроизведи баг тестом", "докажи что баг есть", "тест на ожидаемое поведение фичи", "сделай по TDD", "проверь что починилось", "передай тест другому разработчику".
        argument-hint: [a bug report, acceptance criteria, or a path to an existing test]
        allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
        ---

        # Verifying tests for an iOS app (via simtool)

        A verifying test is one YAML file that stages a scenario on an iOS simulator and
        asserts a claim about it — what *should* happen. `simtool test run <file>` drives
        the app through the accessibility tree, decides whether the claim holds, and
        exits with the verdict: `0` satisfied, `1` unsatisfied, `2` inconclusive, `3`
        infra. Every run is recorded as a session under `.simtool/test-sessions/<id>/`
        with a screen recording, a `report.md` written for a person, and the logs and
        network traffic that explain what happened. The same file also runs from the
        browser viewer's Tests tab.

        Everything here runs through the **`simtool`** CLI (on `PATH`, from Homebrew):

        ```bash
        brew tap mstroshin/simtool
        brew trust mstroshin/simtool   # recent Homebrew requires this for third-party taps
        brew install simtool           # already installed → brew upgrade simtool
        ```

        Building the app, launching it, driving it by hand, mocking a response from the
        command line and reading logs belong to the sibling **`simtool` skill**. This
        document is about tests.

        ## The rule that governs both loops

        **Assert the expected behaviour, never the current broken one.**

        A repro written that way fails today, and that failure *is* the reproduction.
        When the defect is fixed, the same file starts passing — so it becomes the
        regression guard, and nobody has to write a second test.

        A test that asserts the broken state ("the badge is still there") has to be
        inverted the moment the product is fixed. Inverted tests get deleted, and the
        guard goes with them.

        ## A reported bug

        1. **Read the report, then ask about what it does not say.** Which account,
           which environment, which build, which screen. If any of that is unstated, ask
           with `AskUserQuestion` — do not guess. A scenario staged against the wrong
           account or environment reproduces nothing, and reads as "the bug is not
           there".
        2. **Drive the app by hand first.** Launch it (see the `simtool` skill), walk the
           path the reporter walked with `simtool input`, and collect the element ids as
           you go (see [Finding the ids](#finding-the-ids)). Two things come out of this:
           the ids the test needs, and your own confirmation that the defect is visible.
        3. **Write the test.** `kind: bug`, and one `criterion:` on the assertion that
           states what *should* have happened. Every other step merely stages the
           scenario.
        4. **Run it.**

           ```bash
           simtool test run .simtool/tests/badge-not-cleared.yml
           ```
        5. **Expect `unsatisfied` (exit 1).** That is the reproduction; report it as one.
           `satisfied` (exit 0) here is not good news — it means one of three things, and
           you have to work out which before telling anyone the bug is not real: the
           report is wrong, your scenario is not staged the way the report describes, or
           the build installed on the simulator is not the one the report is about.
           `inconclusive` (2) and `infra` (3) mean the test is broken, not the product —
           see [Verdicts](#verdicts).
        6. **Fix the product.** A different job, which your test now defines.
        7. **Re-run the same file, unchanged.** `satisfied` is the fix.
        8. **Keep the file.** It is now the regression guard for that defect, and the
           next person to break it finds out from a red run instead of a report.

        ```yaml
        # .simtool/tests/badge-not-cleared.yml
        name: opening the second tab clears its badge
        kind: bug
        reference: "PROJ-42"          # free-form; stored and displayed, never parsed
        description: >
          Reported: the badge on the second tab stays after the tab is opened. It
          should disappear as soon as the tab is shown.
        app: com.example.myapp.debug
        variables:
          ACCOUNT: "+34600000000"     # the account this test runs as
        launch:
          arguments: [-UITesting, -Environment, staging, -AutoLogin, "${ACCOUNT}"]
        reset:
          defaults: true
          permissions: { att: deny }
        steps:
          - waitFor: { id: MainScreenView, timeout: 45 }
          - waitFor: { id: tabbar_second_badge }   # staging: the badge has to be there first
          - tap: { id: tabbar_second }
          - assertHidden:
              id: tabbar_second_badge
              criterion: badge clears when the tab is opened
        ```

        ## A feature that does not exist yet

        The same loop, with `kind: feature` and one `criterion:` label per acceptance
        item. Write it before the code: the test is the acceptance criteria in a form
        that can be run, and it is red for the honest reason — the feature is not there.

        ```yaml
        kind: feature
        steps:
          - tap: { id: settingsButton }
          - waitFor: { text: "Preferences", criterion: AC-1 }
          - tap: { id: optionToggle }
          - waitFor: { label: "Saved", criterion: AC-2 }
          - assertHidden: { id: errorBanner, criterion: AC-3 }
        ```

        A `feature` run checks **every** criterion and reports all of them, so a
        half-built feature comes back as "AC-1 ✓, AC-2 ✓, AC-3 unmet" from one run
        instead of three. (A `bug` run stops at the first unmet criterion: the
        reproduction is complete there.)

        Labels are free-form. Use `AC-2` when the work arrived with numbered acceptance
        criteria, and a short sentence when it arrived as prose. `reference:` is where
        the origin goes — an issue key, a URL, "reported in chat"; simtool stores and
        displays it and never parses it, because it assumes no issue tracker.

        ## Before the first run

        Three things, and no more:

        - **A booted simulator.** `xcrun simctl boot <udid>`, or open Simulator.app;
          `simtool devices --json` lists them. (If `simulator:` in `.simtool/config.yml`
          names one, a server started for the run boots that one. With nothing named,
          simtool drives whichever simulator is booted, and refuses to guess when
          several are.)
        - **The build you intend to judge.** When `.simtool/config.yml` says how to build
          the app (`build:`), the run rebuilds and reinstalls it first — only when the
          sources changed, since the checksum cache decides — and does so *before* the
          recorder starts, so no video is minutes of an Xcode build. `--no-build` skips
          that and judges whatever is installed. A verdict is only meaningful next to the
          build that produced it, which is why a repro re-run against different code and
          pronounced fixed is the classic mistake.
        - **`.simtool/config.yml`** — `simtool init` scaffolds one. It supplies the
          simulator, the default bundle id, the launch profiles a test may name, and the
          server address the app posts its network and state events to (which is what
          makes mocks and network evidence work at all).

        **No `serve` step is needed.** With no server running, `simtool test run` starts
        one on a free port and **leaves it running** — that server is what serves the
        viewer, and the run it just recorded is what you open the viewer to read. The run
        prints its address and how to stop it (`simtool kill <id>`); `--stop-server` stops
        it automatically instead, which is what a CI job wants. A server already running
        *for this project* is reused and left alone either way. One belonging to another
        checkout is not reused — the run says so and starts its own, because driving
        another checkout's simulator is worse than a second server.

        A run started this way is visible in the viewer while it happens: the Tests tab
        follows it, shows its steps live, and offers no Run button for a test already
        running.

        ## The file

        Tests live in `.simtool/tests/*.yml` — create that directory if it is not there
        yet. `simtool test run` accepts any path, but the viewer's Tests tab only lists
        what it finds in that one. `simtool test run --help` is the source of truth for
        flags and for the current key list; flags move between versions, so confirm them
        there rather than trusting this document.

        ```yaml
        name: settings flow            # optional; the session title
        kind: feature                  # optional; bug | feature — makes this a verifying test
        reference: "PROJ-42"           # optional; free-form origin, stored, never parsed
        description: >                 # optional; what is tested and the expected result
          Opening Settings shows the preferences screen and lets the user enable
          an option.
        app: com.example.myapp.debug   # relaunched before the steps; defaults to bundleId: from the config
        variables:                     # values for the ${VAR} below
          ACCOUNT: "+34600000000"      #   the account this test runs as
        launch:                        # how to launch it
          profile: staging-account1    #   a `profiles:` entry from .simtool/config.yml
          arguments: [-UITesting]      #   appended after the profile's arguments
          env: { SOME_FLAG: "1" }      #   exported to the app as SIMCTL_CHILD_*
          deeplink: myapp://settings   #   opened once the app is running
        reset:                         # simulator state, before launch
          defaults: true               #   clear the app's UserDefaults
          container: false             #   empty the app's data container (keeps it installed)
          permissions: { att: deny, location: grant }   # grant | deny | reset
          locale: es_ES                #   applied as -AppleLocale
          language: es                 #   applied as -AppleLanguages (es)
        mocks:                         # backend answers, applied before launch
          - method: "*/GetSettings"    #   gRPC full-method or HTTP path, `*` globs
            body: { items: [] }        #   YAML or a JSON string (or `error: unavailable`)
            strict: true               #   must fire, or the run is reported as infra
        setup:                         # escape hatch: shell before launch
          - xcrun simctl spawn {udid} defaults delete …  # {udid} {app} {server} substituted; exits recorded, never fatal
        timeout: 10                    # default per-step wait, seconds
        steps:
          - waitFor: { id: settingsButton, timeout: 20 }
          - tap: { id: settingsButton }
          - longPress: { id: optionToggle, duration: 1.5 }
          - type: "hello"              # into the focused field
          - swipe: up
          - assertVisible: { text: "Welcome", criterion: AC-1 }   # alias of waitFor
          - assertHidden: { label: "Loading" }
          - wait: 2                    # escape hatch; prefer waitFor / assertHidden
        ```

        **Targets.** `id` matches the accessibilityIdentifier exactly, `label` matches
        the label or title exactly, `text` is a case-insensitive substring across
        identifier, label, title and value. A bare string is a `text` target:
        `- tap: "Continue"`.

        **Every step that has a target polls** the accessibility tree until the target
        appears — or disappears, for `assertHidden` — up to its own `timeout:`, else the
        file's. `tap` and `longPress` wait for their target before touching it. So tests
        need no sleeps, and a `wait:` in a file is almost always a `waitFor:` someone did
        not write.

        **Only assertions may carry `criterion:`** (`assertVisible`, `waitFor`,
        `assertHidden`). On a `tap:` it is a parse error. Two more the parser refuses,
        both for the same reason — a claim nobody can report is worse than no claim:
        `criterion:` without a `kind:`, and a `kind:` with no criterion anywhere.

        ## Staging the scenario

        Environment, account, country, feature toggles, the screen to open at launch —
        those are the **app's own** launch arguments. simtool knows nothing about them
        and must not; it forwards argv to the app and that is the whole contract. The
        `simtool` skill's launch-argument catalog is where a project writes down its own.

        **Inline in `launch.arguments` is the simple option, and the right default.**

        ```yaml
        launch:
          arguments: [-UITesting, -Environment, staging, -AutoLogin, "+34600000000"]
        ```

        argv reaches `simctl` as separate elements, so a value with spaces needs no
        escaping or quoting beyond YAML's own.

        **A named profile plus `variables:` is for the two cases inline cannot cover:** a
        recipe several tests share (it lives in `profiles:` in `.simtool/config.yml` and
        must not carry one test's account), and a value needed twice — typically a
        `setup:` launch and the run's own — without keeping two copies in sync.

        ```yaml
        variables: { ACCOUNT: "+34600000000" }
        launch: { profile: staging-account1 }   # its arguments refer to ${ACCOUNT}
        setup:
          # the app's own arguments go after `--`; without the terminator `app launch`
          # rejects them as unknown options and the command exits non-zero
          - simtool app launch --workspace MyApp.xcworkspace --scheme MyApp -- -AutoLogin "$ACCOUNT"
        ```

        **A real credential stays in the shell.** Refer to it as `${VAR}` and define it
        nowhere in the file; whoever runs the test exports it. A reference nothing
        defines at all — not `variables:`, not `--var`, not the environment — fails the
        run *before* the simulator is touched and names what to export. So an undefined
        variable is a stated requirement, not a test that quietly logs in as nobody.

        Resolution order: `--var NAME=value` → the test's `variables:` → the process
        environment. The file beating the environment is deliberate: a stale `export` in
        someone's shell must not silently redirect the test to another account. Values
        in `variables:` also reach `setup:` commands as shell environment.

        **`reset:` replaces hand-written state-clearing shell** and travels with the
        test. `permissions:` pre-answers the system alerts that would otherwise block
        the drive: `simtool input` cannot reach a system alert, and while one is up the
        accessibility tree is unreadable — which reads exactly like a broken app. Note
        that the notification prompt has no `simctl` backdoor; answer it by hand once
        and it stays answered for that install. A `reset:` that cannot be applied makes
        the run `infra`, never a failing claim.

        **`setup:` is the escape hatch for what `reset:` cannot express.** Non-zero
        exits are recorded in the session and never fail the test, because these commands
        mostly delete state that may not exist yet. The cost of that is on you: a command
        that fails for a reason you did not intend — a mistyped flag, a missing `--` —
        stages nothing, and the run carries on against state nobody set up. Read the
        `Setup n/n (ok)` lines in the run's timeline before trusting a verdict that used
        `setup:`. An absolute path or a personal account in there is what stops a test
        from travelling — keep it to `{udid}`, `{app}` and `{server}`.

        **Staging happens off camera.** The build, `reset:` and `setup:` all run before
        the recorder starts, so the video holds the run and nothing else. Their timeline
        entries are kept — `Setup n/n (exit 1)` is still there to read before trusting a
        verdict — and their logs are still captured; only the footage begins later.

        **A `setup:` command knows where this run's server is.** `{server}` is
        substituted with it, and the commands run with `SIMTOOL_SERVER` (the address for
        `--server`) and `SIMTOOL_SERVER_URL` (the address the app posts to) exported. That
        is what lets a scenario needing **two launches** travel: the run may start its own
        server on a port it picked, so a port written into the file would be a guess.

        ```yaml
        setup:
          # launch 1 stages the state the run's own launch then changes
          - >-
            simtool app launch --device {udid} --workspace MyApp.xcworkspace --scheme MyApp
            --env SIMTOOL_SERVER_URL={server} --env SIMTOOL_NETWORK_LOGGER=1
            -- -AutoLogin "${ACCOUNT}"
        ```

        Prefer to need neither: `mocks:` are installed **after** `setup:` and before the
        run's own launch, so a setup launch can warm state against the real backend and
        the mocked answer can still belong to the run under test.

        ## Finding the ids

        While driving the app by hand:

        ```bash
        simtool ax find "Continue"           # tree lines containing the text: path, role, label
        simtool ax tree --flat --labeled     # every node that carries an id, label, value or title
        simtool input tap --id settingsButton
        simtool input type "hello"
        ```

        Prefer `id` — it survives translation and copy changes. Then `label`. Use `text`
        last: it is a substring match, so it is the one that quietly matches the wrong
        node. If a screen has no identifiers worth matching, adding them to the app is
        the better fix.

        ## Mocks belong in the test

        A scenario that needs a particular backend answer should carry it. Rules
        declared in `mocks:` are installed before launch, the run waits until the app
        confirms it holds them (so the first call of the run cannot still reach the real
        backend), and the scenario then reproduces on someone else's machine. Rules
        typed into `simtool mock set` live outside the test and reproduce nowhere.

        Use `simtool mock set` while exploring — to find out which answer produces the
        state you want — then move what worked into the file.

        - **`strict: true` on the rule that matters.** A rule that never fired makes the
          run `infra` instead of a quiet pass against the real backend. Without it, a
          wrong method path is indistinguishable from a working mock.
        - **Find the method path** by triggering the call once and reading
          `simtool network events --protocol grpc`.
        - **The bundled interceptor answers unary gRPC.** Whether plain HTTP or a
          streaming RPC gets intercepted depends on the consuming app's own
          interceptor, not this repository — check `simtool network events` to see
          what it actually saw.
        - **A `body:` that does not decode** into the method's typed response is
          ignored, and the real backend answers — a malformed mock never breaks the app,
          it just silently stops being a mock. `strict: true` is what turns that into a
          reported `infra`. `error: unavailable` (any canonical gRPC status name) is the
          cheaper way to test a corner case.
        - **Rules from earlier are cleared** before the test installs its own, so a
          leftover manual rule cannot answer a call this test never accounted for. They
          are *not* cleared at the end: with the server the run started for itself they
          die with it, but against a `simtool serve` you started, the test's rules stay
          until the next test with `mocks:` clears them or you run `simtool mock clear`.
        - The app must be linked against the SimTool network logger, and the run arms it
          itself from `.simtool/config.yml`. If the app never picks up its rules, the run
          says so and reports `infra`.

        ## Verdicts

        The exit code is the answer, so an agent can branch without parsing output:

        | Verdict | Exit | `kind: bug` | `kind: feature` |
        |---|---|---|---|
        | `satisfied` | 0 | not reproduced / fixed | feature confirmed |
        | `unsatisfied` | 1 | **bug reproduced** | feature not confirmed |
        | `inconclusive` | 2 | the run never reached a criterion | same |
        | `infra` | 3 | the run cannot be trusted | same |

        - **`inconclusive` and `infra` mean fix the test, not the product.** A step
          without a `criterion:` only stages the scenario, so when a staging step fails
          the run never reached what it checks and proves nothing in either direction.
          Reporting that as "the bug reproduces" sends someone to fix the wrong thing.
        - **`infra`** is a run whose staging silently did not happen: a `strict:` mock
          that never intercepted a call, an app that never picked up its mock rules, a
          `reset:` that failed. It is never reported as a pass — that is the direction
          that would tell a fixing agent the bug is gone.
        - **A run that never started uses the same scale, never `1`.** A test that cannot
          run as written — unreadable file, parse error, unknown profile, a `${VAR}`
          nothing defines — exits `2`, and an environment with nowhere to run it exits
          `3`. So exit `1` always means a criterion did not hold, and a broken test is
          never reported as a reproduced bug.
        - **`--repeat N` for an intermittent claim.** The report says how many runs held
          it, and flags a split as intermittent. A defect that passes once looks fixed,
          which is the whole reason the flag exists.
        - **`--json`** prints the machine-readable report: verdict, per-criterion status
          with the step that decided it, failures, mock outcomes, session ids and the
          evidence files.
        - A test with no `kind:` makes no claim and keeps plain pass (0) / fail (1).

        ## What the run leaves behind

        `.simtool/test-sessions/<id>/`, one directory per run:

        | File | What it holds |
        |---|---|
        | `report.md` | the run written for a person: verdict, the claim, timeline, evidence, how to re-run it |
        | `video.mp4` | screen recording; the report's timeline is in video time |
        | `session.json` | the run itself — timeline, criteria, verdict, and provenance (test copy, bundle id and version, device, runtime, simtool version, commit) |
        | `logs.jsonl` | every log line the app emitted during the run |
        | `network.jsonl` | every HTTP/gRPC call the app reported, with `mocked` and the rule id that answered it |
        | `state.jsonl` | `@SimToolDebugState` snapshots, when the app links the state logger |
        | `mocks.json` | each declared rule and how many calls it answered, including `hits: 0` |
        | `failure-step-<n>.png`, `failure-step-<n>-ax.txt` | the screen and the visible elements at the step that failed |

        `report.md` is written for **every** recorded run, whatever `--evidence` says:
        the flag is a statement about captures, not about the one artifact meant for a
        person. `--evidence none` leaves only the steps and the video, `full` adds a
        `step-<n>.png` after every step, and `--no-session` skips the recording entirely
        — the verdict and nothing else, so no report and no video.

        Each step entry in `session.json` carries its start and end timestamps and the
        log-cursor range covering it, which is how the logs, requests and state changes
        belonging to **one** step get sliced out of those files instead of read whole.

        `simtool test list` prints the recorded sessions with their verdicts. Unlike
        `run` it does not start a server: it needs one running **for this project**, or
        `--server <url>`. A server belonging to another checkout is not read — its
        sessions are that project's history, and reading them here would answer "did my
        test pass?" with somebody else's run.

        The viewer (`simtool serve --web`) has a **Tests** tab with two subtabs: *Tests*
        lists the YAML tests with Run buttons and live progress, *History* lists the
        recorded sessions with the timeline synced to the video — clicking a step seeks
        the recording to that moment. One test runs at a time.

        ## Handing it on

        The point of a verifying test is that someone else re-runs it: the agent that
        fixes the bug, a reviewer, whoever tests the fix.

        **Send the YAML file.** Attach `report.md` and `video.mp4` from the session when
        they help — the report says what was claimed, what happened and what the receiver
        has to supply; the video is what makes a UI bug obvious without a re-run.

        The receiver needs `simtool`, a booted simulator, **their own build** of the app,
        and any `${VAR}` the test does not define itself (the report names them). They
        can run it as a different account with `--var NAME=value` without editing the
        file. Their run against their build is the run that matters to them — a verdict
        recorded on your machine says nothing about their code.

        **Do not send the evidence files outside the team.** `logs.jsonl`,
        `network.jsonl` and `state.jsonl` hold the real traffic and log output of the
        account the run used — identifiers, tokens, whatever the app printed. That is
        what makes them worth reading and what makes them team-internal. The test file
        itself carries none of it, unless you wrote a real credential into `variables:`
        — in which case move it to the environment first.

        `.simtool/` is gitignored, so a test is machine-local until you send it. There is
        no archive format and no export command — the file is the artifact.

        ## Anti-patterns

        | Instead of | Do this |
        |---|---|
        | `wait: 5` to let a screen settle | `waitFor:` the element that means it settled; every step already polls |
        | a `criterion:` on a `tap:` or a `type:` | put it on the assertion that checks the claim — the parser rejects it anywhere else, and a staging failure is `inconclusive` on purpose |
        | asserting the state the bug produces | assert the behaviour that *should* hold, so the same file becomes the regression guard |
        | `simtool mock set` before running the test | declare the rules in `mocks:`, with `strict: true` on the one that matters |
        | no `kind:`, so the run is a bare pass/fail | `kind: bug` or `kind: feature` plus one `criterion:`; that is what turns a run into a verdict |
        | an absolute path or your own account in `setup:` | `{udid}` / `{app}` substitutions, `reset:` where it can express the same thing, and the account in `variables:` or `${VAR}` |
        | a `satisfied` repro reported as "not a bug" | check the three causes first: wrong scenario, wrong account/environment, or a build that is not the one reported |

        """#
}
