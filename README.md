# SimTool

Swift CLI/server for streaming and automating Apple Simulators.

The MVP focuses on a local browser viewer with JPEG and H.264/AVCC streams and a
machine-readable CLI for agents.

## Build

The repository is two SwiftPM packages: the root package vends the embeddable
logger libraries (`SimToolNetworkLogger`, `SimToolStateLogger`), and the `Tool/`
package builds the `simtool` CLI. Build the CLI from `Tool/`:

```sh
swift build --package-path Tool
```

## Install

Recommended Homebrew install after the public tap is published:

```sh
brew tap mstroshin/simtool
brew trust mstroshin/simtool   # recent Homebrew requires trusting a third-party tap before install
brew install simtool
simtool doctor
```

Upgrade or remove:

```sh
brew update
brew upgrade simtool
brew uninstall simtool
```

Runtime prerequisites:

- macOS 14 or newer.
- Xcode or Command Line Tools with installed simulator runtimes.
- `xcode-select` pointing at the selected developer directory.
- AXe for accessibility automation commands such as `ax` and accessibility-based `input` actions.

Source fallback for development:

```sh
swift build --package-path Tool
swift run --package-path Tool simtool doctor
```

## Basic Usage

The `swift run simtool …` examples below run against the CLI package in `Tool/`.
Either `cd Tool` first and use them verbatim, or keep them as `swift run
--package-path Tool simtool …` from the repo root.

```sh
swift run simtool devices --json
swift run simtool serve --device <udid-or-name> --port 3200
```

Open `http://127.0.0.1:3200` after starting `serve` (the URL is printed on start),
or pass `--web` to open the browser viewer automatically.

The viewer is one window: the device on the left, the inspector on the right
(**Network**, **Logs**, **State**, **Accessibility**, **Device**, **Tests**, **Activity**), with a splitter
between them that remembers where you leave it; in a narrow pane the inspector
moves under the device instead of covering it. Under the device are its size in
points, the frame rate and the pointer's position in points; the status bar at
the bottom holds the session's facts — connection, device and runtime, UDID
(click to copy), server, attached app, where the keys go, the simtool version.
The viewer follows the system's light or dark appearance; the sun / moon button
in the toolbar pins the other theme for this browser.
⇧⌘P opens a command palette with every action and test; the shortcuts follow
Simulator.app and Xcode — ⇧⌘H Home (a double-click on the Home button or ⌃⇧⌘H opens the
app switcher), ⌘S screenshot, ⌘R record video, ⌃⌘Z shake, ⌥⌘0 show or hide
the inspector — and ⌥1–7 switch inspector tabs, `/` filters the current list,
↑/↓ move through it and Shift-F10 opens a row's menu. When the server goes away
the viewer greys the last frame, says so, stops sending touches and reconnects
by itself; a restarted server is noticed and its lists are reloaded.

The toolbar saves a screenshot (⌘S) and records the screen (⌘R): recording, the
button turns into a red REC mark with the running time, and a click or ⌘R again
stops it and downloads the video (H.264 `.mp4`). The caret beside them picks the
frame for both — **Screen only**, or **With the device bezel**: the device drawn
around the screen as Simulator draws it, side buttons, rounded corners and the
Dynamic Island included, from the DeviceKit chrome Xcode installed on the Mac
(SimTool ships no Apple artwork; a device without one gets a plain drawn frame).
A screenshot with the bezel is a PNG with a clear background, a video one has a
white background. The recording runs on the server, so a reload keeps it and
every viewer shows it; the server keeps only the newest video. The caret's menu
also copies the screenshot and downloads the last video again.

An iPhone Duo adds a bar under the device — Closed, Book and Open, and a **3D**
switch — and the fold beside its size (`book · 130° · inner`). 3D shows the
device itself, folded as it is and animated as it folds, filling the stage
whatever its pose, its lit panel live on it, rendered on
the server with RealityKit from the device model Device Hub draws it with
(`V68.usdz`, read from the selected Xcode at run time — SimTool ships no Apple
asset) and streamed like the screen. Clicks and drags on its screen land on
that panel. Without the model — or with RealityKit's offscreen renderer
missing (macOS 14) or failing — the button says why and the viewer stays on
the flat screen; `simtool doctor` reports it as "iPhone Duo 3D preview".

What an agent or a test run does to the device shows as it happens. Every touch
from `simtool input`, the HTTP API or a YAML step is drawn on the screen in
course ink — a ring where the finger went down, a stroke to where it lifted, a
caption naming it (`Tap “General”`, `Scroll up 300 pt`) — and launches, typing,
mocks armed and test steps caption the top of the screen. The toolbar says who
is driving: **Test running · step 3 of 7**, or **Agent driving** for half a
minute after an agent's last action. The last action and how long ago it was
stay under the device, and **Activity** (⌥6) lists every action with who did it,
how long it took and whether it failed; a touch's row shows its path in points,
draws it again on the screen and copies as the `simtool input` command that
repeats it. A touch, key or button from the page while a test or an agent drives
the device asks first — **Take over** lets the person act until the next run or
agent starts — and a touch by hand during a run is itself in the feed.

On the viewer's screen the mouse is a finger: it goes down on press, follows the
pointer and lifts on release, so holding is a long press, holding and moving
drags (icons, list reordering), and the release decides between a scroll that
stops where the finger did and a fling. A dot marks the finger at once, ahead of
the video; a ring around it says it has been held long enough for a long press.
The wheel or trackpad scrolls by dragging a finger too. Hold Option to add a
second finger mirrored through the screen center — spreading or circling the
pointer pinches or rotates — and Option-Shift to move both fingers together.

The keyboard works as in Simulator.app, from one keyboard button in the toolbar.
Its menu shows or hides the software keyboard (Toggle Software Keyboard) and
connects the Mac keyboard — a switch beside it says whether it is connected.
Connected, or with ⇧⌘K, the Mac keyboard types into the simulator and its
hardware keyboard is connected (Connect Hardware Keyboard), so iOS keeps the
software keyboard out of the way until the menu or ⌘K brings it back; the
button turns course ink while it lasts. Keys travel as physical keys — the simulator's own layout
decides the character — with modifiers, arrows, ⌫, ⏎, Tab and Esc, which iOS
uses; ⇧⌘K leaves the mode, and ⌘V pastes the Mac clipboard as text. A ring
around the screen shows the keys go to the device, and the status bar says so;
the ring turns dashed while they go elsewhere — to a SimTool field such as the
inspector filter, which keeps its keys, or to another window. Off, the keyboard belongs to the page and the
browser. Keys reach the simulator in a few milliseconds over the same helper as
the finger; ⌘W, ⌘T and ⌘Q stay with the browser. Agents show and hide the
software keyboard with `simtool input keyboard show|hide` and YAML tests with a
`keyboard: show|hide` step; both confirm the keyboard on screen (or off it)
through the accessibility tree, and `show` fails when no text field is focused.

`serve` runs fully headless: when `--device`, `--host`, or `--port` are omitted
it falls back to `simulator:` and `server:` from `.simtool/config.yml` (when one
is discovered, or passed via `--config`), and boots the target simulator via
`simctl` if it is not running yet — no Simulator.app window is ever opened; watch
the device in the web viewer instead. With `--detach --json` the started session
is printed as JSON whose `url` field is the viewer address, ready to feed into a
browser or another tool.

Run `simtool` with no subcommand (or `simtool interactive`) in a terminal to
pick and open configured deeplinks in a loop. Requires a `deeplinks:` list in
`.simtool/config.yml`; select `Exit` or press Ctrl+C to leave. Non-interactive
callers should keep using explicit subcommands such as `simtool devices` —
bare `simtool` no longer defaults to `devices`.

For detached agent usage:

```sh
swift run simtool serve --detach --json --port 3200
swift run simtool status --json
swift run simtool kill <session-id> --json
```

## Automation

```sh
swift run simtool input button home --json
swift run simtool input button app-switcher --json   # Home pressed twice
swift run simtool input keyboard hide --json   # show | hide | toggle the software keyboard
swift run simtool ax tree --json
swift run simtool ax tree --flat --labeled
swift run simtool ax find Continue --json
swift run simtool logs tail --lines 20 --seconds 2 --json
swift run simtool logs tail --app com.example.MyApp --lines 20 --seconds 2 --json
swift run simtool logs tail --app com.example.MyApp --stdout --seconds 4 --json
swift run simtool network snapshot --seconds 2 --limit 50 --json
```

The simulator's settings and Simulator.app's Debug menu, which Device Hub
(Xcode 27) left out — each prints the setting without a value, changes it with
one, and reports the change to the viewers watching the device:

```sh
swift run simtool settings --json                 # all of them, as the device reports them
swift run simtool ui appearance dark              # light | dark
swift run simtool ui text-size ax2                # simctl's sizes, xs…xxxl, ax1…ax5, bigger, smaller
swift run simtool ui contrast on                  # Increase Contrast
swift run simtool debug color-blended on          # slow-animations, color-blended, color-copies, color-misaligned, color-offscreen
swift run simtool debug memory-warning
swift run simtool biometrics enroll               # enroll | unenroll | match | nomatch
swift run simtool push --alert "Your order shipped" --app com.example.MyApp
swift run simtool status-bar clean                # 9:41, full Wi-Fi, charged; or --time, --battery-level…; clear
swift run simtool location route 37.3349,-122.0090 37.3318,-122.0312 --speed 15   # set <point> | clear
swift run simtool ui reduce-motion on             # reduce-transparency, button-shapes, voiceover
swift run simtool ui color-filter grayscale       # none, grayscale, protanopia, deuteranopia, tritanopia
swift run simtool ui liquid-glass tinted          # clear | tinted, iOS 26 and later
swift run simtool input rotate left               # right, portrait, landscape-left, landscape-right, upside-down
swift run simtool permissions --app com.example.MyApp            # every permission, as the device has it
swift run simtool permissions deny notifications --app com.example.MyApp   # grant | deny | reset | always (location)
swift run simtool keychain add-root-cert ~/Downloads/proxy-ca.pem   # add-cert | reset
swift run simtool app info --app com.example.MyApp --reveal data     # the card; --reveal bundle|data opens Finder
swift run simtool app install Build/MyApp.ipa     # an .app, an .ipa, or a tar of an .app
swift run simtool camera fixtures/code.png        # the camera shows an image; a .mov/.mp4 loops
swift run simtool camera webcam                   # the Mac's camera (--camera <name>); off; env
```

The colours are the guest render server's own debug options, which CoreSimulator
forwards (`-[SimDevice setCADebugOption:enabled:]`, by number); slow animations
is the darwin notification UIKit reads; a memory warning reaches every process as
memory pressure, which UIKit turns into `didReceiveMemoryWarning`. `match` and
`nomatch` answer a Face ID or Touch ID prompt the app already shows. simctl
cannot read a location back, so `simtool location` and the viewer show the one
SimTool last set. Naming any cellular field of the status bar makes simctl fill
in the rest — 5G, full bars, "Carrier" — so `clean` leaves them out.

The accessibility settings go through a helper SimTool builds and runs inside the
simulator, which calls the guest's own libAccessibility setters — the ones
Settings calls — so running apps follow at once; Liquid Glass is UIKit's
`UIViewGlassLegibilitySetting`. A rotation is the device-orientation event
Simulator.app sends; the picture is then read back from CoreDevice whenever the
guest says it turned, whoever turned it, so touches land where they point.
Permissions go through `simctl privacy` where it has them (camera and pasteboard
included), through the device's TCC database for Face ID, speech recognition and
tracking, and through SpringBoard's own record for notifications: SpringBoard
reads that only as it starts, so a notifications change resprings the simulator —
backboardd restarts and takes SpringBoard with it (restarting SpringBoard alone
would leave it unable to turn its interface until the simulator reboots).

Touches are played by SimTool's own HID helper as timed paths, in screen points
(the space `ax tree` reports frames in) — the same helper the viewer's live
finger uses:

```sh
swift run simtool input tap --label Continue
swift run simtool input long-press --id photo --duration 1.2
swift run simtool input scroll up --distance 300     # content moves 300 pt and stays
swift run simtool input fling up --speed fast        # lifted in motion, keeps going
swift run simtool input swipe --start-x 200 --start-y 700 --end-x 200 --end-y 300 --hold 0
swift run simtool input drag --start-x 200 --start-y 140 --end-x 200 --end-y 290
```

On an iPhone Duo every touch — the CLI's, the API's, a test's and the viewer's
live finger — lands on the panel that is lit, in points of its picture as a
screenshot and `ax tree` show it: the open inner panel reads 951 × 669 pt
(landscape) although its framebuffer is portrait, and SimTool turns each point
onto it. The viewer shows the lit panel upright, with its own corners, and
follows it as the device folds. The inner panel takes SimTool's own Indigo touches (target
`0x40000003`); the cover is touched through the simulator's HID daemon,
dtuhidd, as Device Hub does — while dtuhidd runs, SimulatorHID keeps the cover's
own touch screen stood down, and an Indigo event sent into it would abort
backboardd.

An iPhone Duo folds from the CLI, the API, a test and the viewer's toolbar:

```sh
swift run simtool input pose book      # closed | book | open | a hinge angle 0–180
swift run simtool input pose           # the fold now: open · 180°, inner panel lit
```

Closed (0°) lights the cover; book (130°) and open (180°) the inner panel. The
hinge is swept there as a hand would fold it — SpringBoard folds with
hysteresis, and a jump can leave the panel that was lit — by a helper SimTool
runs inside the simulator, which posts the hinge the way Device Hub's slider
does. A pose returns once the device reports it: the hinge as the guest's
motion service took it and the panel CoreDevice says is lit; one the device does
not take is an error naming what it reports instead. The fold is read back
continuously too — Device Hub's own slider included: `/config` and the event
stream's `device` topic carry it as `fold` (`hingeDegrees`, `pose`, SpringBoard's
`posture`, the lit `panel`), the toolbar shows it next to its Closed / Book /
Open buttons, and the activity feed has a pose's result, or a fold made
elsewhere, as an entry. YAML tests take a `pose:` step.

YAML tests change the device's settings with steps too — `appearance: dark`,
`textSize: ax2`, `contrast: on`, `biometrics: match`, `push: { aps: { alert: "…" } }`
(to the test's app), `location: "37.33,-122.01"` (or a `route:`), `statusBar:
clean`, `permission: { camera: deny }`, `rotate: landscape-left` — where the
scenario needs them, so a Face ID prompt is answered after the tap that raised
it. A permission step that ends the app, as iOS does, relaunches it the way the
run launched it. `reset.permissions` pre-answers notifications, camera, Face ID,
speech and tracking too.

Directions are the way the finger moves: `scroll up` drags the content up,
revealing what is below. A `scroll` (and a `swipe`, unless `--hold 0`) slows
down and rests a quarter second before lifting, which leaves the content where
the finger stopped; a `fling` lifts in motion. A `drag` presses 0.8 s until the
item lifts, carries it at 300 pt/s and rests 0.5 s before dropping it — list
reordering and moving items. A `long-press` shorter than ~0.6 s warns that it may
land as a tap. `POST /api/v1/input` takes the same gestures (`scroll`, `fling`,
`drag`, and `swipe` with `velocity`/`hold`), and YAML tests have `scroll:`,
`fling:` and `drag:` steps.

A touch fails rather than answering `ok` when iOS has dropped the touch screen
for the current boot. iOS 26.4 and 27 do that when the simulator's HID daemon
(dtuhidd) starts before anything has touched the screen; the helper claims the
screen as it starts, so only a tool that reached the device before SimTool can
cause it. The error gives the command to reboot the simulator, which brings
touches back.

`input type` reaches only characters on a US keyboard. For anything else —
Cyrillic, accents, emoji, several lines — use `input paste`: it puts the text on
the simulator clipboard and presses ⌘V in the focused field.

```sh
swift run simtool input paste "Привет, señor 🎉" --json
printf 'line one\nline two' | swift run simtool input paste --stdin
swift run simtool input paste --image screenshot.png
```

Paste grants the foreground app "Paste from Other Apps" (`simctl privacy …
grant pasteboard`), so iOS does not ask "Allow Paste?" each time; iOS still
shows its "… pasted from …" banner for a few seconds, over the top of the
screen. It fails when no text field changed and no keyboard is up — tap a text
field first. `--image` pastes an image the same way (Xcode 27 or newer); only
fields that take images react — a text view with attributed editing, notes or
chat composers — while a plain text field ignores it. From Xcode 27 on, the
simulator clipboard belongs to CoreDevice and `simctl pbcopy` is silently
ignored; SimTool writes through `devicectl device pasteboard copy` and falls
back to `simctl pbcopy` (text only) on older Xcode.

In the browser viewer, ⌘V anywhere on the page outside its own fields pastes
the Mac clipboard — text, or an image when it holds no text — into the
simulator. Right-clicking the device screen opens a menu with the same
**Paste** (it asks the browser for clipboard access), **Add clipboard image to
Photos** and **Add files to Photos…** (images and videos) — both put the media
in the simulator's Photos library (`simctl addmedia`), where a photo picker
offers it — **Save** or **Copy screenshot** and **Record video**. While the Accessibility tab
picks elements, a right-click opens the element's menu instead.

The **Device** tab (⌥7) — its sections start folded and stay as you leave them —
is what Simulator.app kept in its menus and Device Hub dropped, as the device
reports it: the appearance, the text size (Dynamic Type)
and Increase Contrast; the render server's debug colours — Color Blended
Layers, Copied Images, Misaligned Images, Off-screen Rendered — and Slow
Animations, each a switch, with Simulate memory warning beside them; Face ID or
Touch ID (whichever the device has): enrolled or not, and a matching or
non-matching face or finger for the prompt on screen; status bar overrides (a
9:41 preset for screenshots, or time, battery and network one by one); the
simulated location — a point or a route — and a push notification with its JSON
payload. It also holds the accessibility settings Simulator.app reached through
Settings — Reduce Motion, Reduce Transparency, Button Shapes, VoiceOver, Color
Filters (apps read the filter; the simulator's screen shows none) and Liquid
Glass clear or tinted —, the orientation, the app under test's card (version
and build, minimum iOS, its process, its bundle and data container with
Reveal in Finder and Copy), each of its privacy permissions as a choice —
notifications too —, and the keychain: trust a proxy's root certificate, or
reset it. Each change is an entry in Activity; the tab reads the device again
after it, every few seconds while it is open, and whenever an agent or a test
changes a setting. The command palette has them too. The toolbar's rotate button
turns the device left (⌘←; ⌘→ turns it right), and the stream, touches,
accessibility frames and screenshots follow the turned picture. Files dropped
on the screen go where Simulator.app sent them: images and videos to Photos, an
`.app` bundle or an `.ipa` installed on the device.

**The camera.** The simulator has none, so SimTool gives one to the apps it
launches — `simtool app launch`, `simtool run`, the viewer's Launch and
Relaunch, test runs: it loads a small library of its own into the app
(`DYLD_INSERT_LIBRARIES`, built for the simulator on first use) that answers
AVFoundation's camera with a back and a front camera whose picture is an image,
a video played in a loop, or the Mac's webcam. Previews
(`AVCaptureVideoPreviewLayer`), video frames (`AVCaptureVideoDataOutput`, in
the pixel format the app asks for), photos (`AVCapturePhotoOutput`), QR and
barcode scanning (`AVCaptureMetadataOutput`, read with Vision) and
`UIImagePickerController`'s camera all see it. A new picture reaches running
apps at once; an app launched while the camera was off gets it at its next
launch. The Device tab's Camera section takes an image or a video, or the
Mac's camera, and lists the apps that have it; the server runs the webcam
(macOS asks once, for the app that started simtool). An app run from Xcode
gets the camera with the variables `simtool camera env` prints, in its scheme's
environment.

The **Accessibility** tab shows the served accessibility tree, with anonymous
containers folded away, and picks elements on the screen: the picked element is
drawn with its distances to the screen edges and to the element under the
pointer, in points, next to rulers along the screen. Its details offer it as a
YAML step (`- tap: { id: About }`) and as a `simtool input tap` command.

### Tests and sessions

Declarative YAML tests in `<project>/.simtool/tests/` drive the simulator
through the served accessibility tree: every step polls until its target
appears, so tests need no sleeps. Each run is recorded as a reviewable test
session — timestamped steps, a screen recording and the run's evidence — shown
in the web viewer's **Tests** tab, which also lists the tests with Run buttons,
live progress and each test's last outcome in words (*Bug reproduced*,
*Confirmed*, …), and keeps the recorded runs under **History**. A finished run's
recording plays in the screen's place — Replay is a mode of the whole viewer,
so the inspector stays usable — with each step marked on its scrubber, and
clicking a step seeks the video to that moment. While it plays, **Network**,
**Logs** and **State** show that run — its own `network.jsonl`, `logs.jsonl`
and `state.jsonl`, so a run reads the same long after its server is gone — cut
to the step under the playhead: from the moment the step began acting to the
moment the next one did, so a tap's window holds the requests and lines it
caused while the next step waited for them; State shows the models as they
stood at the end of that window and what changed inside it. A bar over each
list names the step and its span and switches to the whole run. In the
timeline every step says what it caused — *1 request · 277 log lines · 1 state
update* — and each count opens that list, held at that step.

```bash
swift run simtool test run .simtool/tests/my-test.yml
swift run simtool test run .simtool/tests/my-test.yml --json --repeat 5
swift run simtool test list --json
```

A running server is not a prerequisite: when none is running, `test run` starts
one on a free port and leaves it running — it is what serves the viewer, and the
run just recorded is what the viewer is opened to read. The run prints its address
and how to stop it; `--stop-server` stops it automatically, which is what a CI job
wants. One already running for this project is reused and left alone; one
belonging to another checkout is not — the run says so and starts its own instead.
`test list` applies the same rule without the autostart: it reads a server started
for this project, or the one `--server` names, and never another checkout's
history.

A run started from the command line is visible in the viewer while it happens:
its session carries the test file, so the Tests tab follows the run, streams its
steps, and offers no Run button for a test that is already running.

`setup:` commands are told where the run's server is — `{server}` in the command,
`SIMTOOL_SERVER` and `SIMTOOL_SERVER_URL` in their environment — so a scenario
that needs a second launch does not have to write a port into the test file.

A test carries everything needed to stage its scenario, so it reproduces on
another machine: `launch:` (a named profile from `.simtool/config.yml` plus
inline argv/env), `reset:` (UserDefaults, data container, permission alerts,
locale) and `mocks:` (backend answers, applied before launch). See
`simtool test run --help` for the full file format.

When the project config says how to build the app, a run rebuilds it for the
run's simulator and reinstalls it first — only when the sources changed, since
the checksum cache decides — and before the recorder starts, together with
`reset:` and `setup:`. So the video
holds the run itself rather than minutes of an Xcode build, while the staging
still appears in the timeline and its logs are still captured. `--no-build`
judges whatever is already installed.

#### Verdicts

A test that declares `kind: bug` or `kind: feature` and marks the assertions
that check its claim with `criterion:` gets a verdict instead of a bare
pass/fail — and a distinct exit code, so an agent can branch without parsing
output:

| Verdict | Exit | `kind: bug` | `kind: feature` |
|---|---|---|---|
| `satisfied` | 0 | not reproduced / fixed | feature confirmed |
| `unsatisfied` | 1 | bug reproduced | feature not confirmed |
| `inconclusive` | 2 | the run never reached a criterion | same |
| `infra` | 3 | the run cannot be trusted | same |

The point of the split is that a run which fell over while staging the scenario
proves nothing: reporting it as "the bug reproduces" sends someone to fix the
wrong thing. `infra` covers a run whose staging silently did not happen — a
`strict:` mock that never intercepted a call, an app that never picked up its
mock rules, a `reset:` that failed — and is never reported as a pass.

A run that never started uses the same scale rather than a bare failure: a test
that cannot run as written (unreadable file, parse error, unknown profile, a
`${VAR}` nothing defines) exits `2`, and an environment with nowhere to run it
exits `3`. So exit `1` always means a criterion did not hold.

A `bug` run stops at the first unmet criterion; a `feature` run reports every
criterion from one run. Tests with no `kind:` keep the old behaviour (0 or 1).
`--repeat N` runs the test N times and reports how many runs held the claim,
because an intermittent defect that passes once looks fixed.

#### Evidence

Sessions persist under `<project>/.simtool/test-sessions/<session-id>/`
alongside the project the server was started for, and survive server restarts.
Besides `session.json` and `video.mp4`, a run writes what explains it — the
runner arms the log capture itself and scopes it to its own launches:
`logs.jsonl`, `network.jsonl` (with `mocked` and the rule id per event),
`state.jsonl`, `mocks.json` (what each declared rule actually did) and a
screenshot plus visible-element dump at the point of failure. `--evidence
none|failure|full` controls how much; `full` also captures every step.
`session.json` additionally records provenance: an inline copy of the test, the
app's bundle id and version, the device and runtime, the simtool version, and
the commit.

Every recorded run also writes `report.md` — the same run rendered for a person —
regardless of `--evidence`, which controls captures rather than that.

One session is active at a time; sessions can also be driven directly over HTTP
via `POST /api/v1/tests/start|entries|stop`.

#### Sharing a test

The test is the artifact. It carries everything needed to stage its scenario, so
sending the `.yml` file is the whole handoff — to the agent that will fix the
bug, to a reviewer, to whoever tests the fix:

```bash
swift run simtool test run .simtool/tests/my-test.yml     # on the receiving side
```

Attach the two files next to the run when they help: `report.md` — the run
written for a person, with the claim, the verdict, the timeline and what the
receiver has to supply — and `video.mp4`.

What the receiver needs: `simtool`, a booted simulator, their own build of the
app (which is the point when verifying a fix), and any `${VAR}` the test refers
to without defining. A test that defines its `variables:` travels ready-to-run;
anything it leaves to the shell is checked before the simulator is touched, so a
missing account fails in a second rather than mid-run. `--var NAME=value`
overrides a value the test does define.

Do not forward the evidence files outside the team: `logs.jsonl`,
`network.jsonl` and `state.jsonl` hold the real traffic and log output of the
account the run used. `report.md` says so too.

`ax tree` and `ax find` omit the bulky raw AXe payload by default; pass `--raw`
(or `?raw=1` on `/api/v1/ax/tree` and `/api/v1/ax/find`) to include it. For the
cheapest screen summary use `ax tree --flat` (`?format=flat`) — a depth-annotated
node list with identifiers, labels, and frames — and add `--labeled`
(`&labeled=1`) to keep only nodes an agent can address. JSON output is
pretty-printed at a terminal and compact when piped.

`logs tail --app` accepts a bundle identifier, subsystem prefix, or process name.
For dotted bundle identifiers, SimTool also matches the final component as a
process name so app `print` output can be found more reliably.

By default `logs tail` samples only unified logging (OSLog). Add `--stdout` (with
`--app <bundle-id>`) to also capture the app's `print`/stdout output via
`simctl launch --console-pty` — this **terminates and relaunches the app** to
attach its console. Each captured line is tagged with its `source` (`oslog` or
`stdout`).

## App Build and Launch

Build an iOS simulator app from an Xcode workspace or project:

```sh
swift run simtool app build --workspace MyApp.xcworkspace --scheme MyApp --json
swift run simtool app build --project MyApp.xcodeproj --scheme MyApp --configuration Debug --json
swift run simtool app build --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp
```

Inside a project with a `.simtool/config.yml`, `app build`, `app launch` and
`app test` need neither: without `--workspace` or `--project` they build the app
from the config's `build:` block — the one `run` builds, from the same cache —
and `--scheme`, `--configuration`, `--derived-data-path`, `--build-setting` and
`--builder` each override just their key:

```sh
swift run simtool app launch
swift run simtool app build --configuration Release --json
```

Without `--device` the build targets any iOS simulator, so xcodebuild compiles
every simulator architecture (arm64 and x86_64); with it, only that simulator's —
noticeably faster. `app launch`, `run` and `test run` always build for the
simulator they install on, resolved before the build (`--device`, then
`simulator:` from the config, then the booted one — `booted` becomes a UDID
too). The target is not part of the cache key: a build for one simulator, for
another or for any is reused by all of them.

A project that only builds with extra xcodebuild settings — say a deployment
target its generated dependencies miss — gets them from `build.settings` in
`.simtool/config.yml` (below) on every build of that workspace or project, or
per command with repeatable `--build-setting KEY=VALUE` on `app build`,
`app launch` and `app test`:

```sh
swift run simtool app build --workspace MyApp.xcworkspace --scheme MyApp \
  --build-setting MACOSX_DEPLOYMENT_TARGET=15.0
```

A flag wins over the config for the same key. Settings are part of the build
cache key, so a build with other settings never reuses a cached one.

### Building in Xcode over MCP

Xcode 27 offers its build to agents as MCP tools (`xcrun mcpbridge`), and SimTool
can build through them instead of running xcodebuild: set `builder: xcode-mcp`
in the config's `build:` block, or pass `--builder xcode-mcp` to `run`,
`app build` or `app launch` (`--builder xcodebuild` switches back for one
command). Xcode keeps the workspace loaded between builds and builds into the
DerivedData its own UI uses, so a build there is often far faster than a cold
xcodebuild.

```sh
swift run simtool run --builder xcode-mcp
swift run simtool app build --workspace MyApp.xcworkspace --scheme MyApp --builder xcode-mcp --json
```

SimTool opens the workspace or project in Xcode, makes the scheme active,
selects the simulator's run destination — Xcode lists simulators by name and
iOS version; without a device, "Any iOS Simulator Device" — builds, and asks
Xcode where the `.app` landed. The workspace stays open for the next build;
`xcrun mcp-server stop` closes Xcode's background service and everything it
opened.

Xcode decides the build itself: the scheme's Run configuration, the project's
own settings, its own DerivedData. So an Xcode build leaves the config's
`derivedDataPath` and `settings` out (they still apply to xcodebuild), refuses
`--derived-data-path` and `--build-setting`, and fails when the scheme's Run
configuration is not the `configuration` asked for. Its builds get a cache
entry of their own: switching builders builds once rather than reusing the
other builder's `.app`.

The first time, Xcode asks you to approve SimTool as an agent and to let it
open the project's folder — from the Xcode MCP menu bar icon, or with
`sudo xcrun mcp-server approve <id>` for a request `xcrun mcp-server status`
lists. A build left waiting fails after about a minute with that hint; approve
and run it again. Xcode ties the approval to the `simtool` binary: an unsigned
one, such as a Homebrew build, is trusted for 24 hours at a time and once more
after each upgrade.

Launch builds only when the build-input checksum changes. If the checksum matches
the last successful build, SimTool reuses the cached `.app`; if the selected
simulator does not have that build installed yet, SimTool installs it before
launching. Checksum metadata is stored in `.simtool/build/` inside the project;
build products (DerivedData) stay in `~/Library/Caches/SimTool`.

A cache hit also needs the `.app` to still be the one that build produced.
One bundle path is often written by more than one build — a build with other
`--build-setting`s into the same DerivedData, Xcode (with `xcode-mcp` or from
its UI) when its build location settings put products next to the workspace,
another checkout's identity sharing a configured `derivedDataPath` — so SimTool
records a stamp of the bundle (every file's size and modification time) with
each build and checks it before reusing one. A bundle rebuilt since by anything
else is a cache miss, and a device whose installed build is not that very
bundle gets it reinstalled.

```sh
swift run simtool app launch --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp --json
swift run simtool app launch --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp --json
```

Pass runtime flags to the launched app with repeatable `--env KEY=VALUE`
options. This is useful for enabling app-side SimTool diagnostics:

```sh
swift run simtool serve --detach --json --port 3311
swift run simtool app launch \
  --device <udid-or-name> \
  --workspace MyApp.xcworkspace \
  --scheme MyApp \
  --env SIMTOOL_NETWORK_LOGGER=1 \
  --env SIMTOOL_SERVER_URL=http://127.0.0.1:3311 \
  --json
swift run simtool network events --server http://127.0.0.1:3311 --json
```

Pass launch **arguments** (argv) to the app — as opposed to environment
variables — by listing them after a `--` terminator. They are forwarded verbatim
after the bundle id and reach the app through `CommandLine.arguments` (and the
`NSArgumentDomain` of `UserDefaults`), which is how most debug/test launch flags
are wired:

```sh
swift run simtool app launch \
  --device <udid-or-name> \
  --workspace MyApp.xcworkspace \
  --scheme MyApp \
  -- -DebugFlag 1234 -SomeDebugFlag YES
```

`app launch` always cold-launches with `--terminate-running-process`, so launch
arguments and `SIMCTL_CHILD_*` environment take effect even when the app is
already running.

`SimToolNetworkLogger.makeFromEnvironment()` reads `SIMTOOL_NETWORK_LOGGER` and
`SIMTOOL_SERVER_URL` for you, returning `nil` (no capture) unless the logger is
enabled. For simulator development prefer `SimToolNetworkLogger.resolved()`: it
behaves like `makeFromEnvironment()` but, **only in the iOS Simulator**, also
self-activates from an on-device marker it persists the first time SimTool arms
it. That keeps network events flowing after you fully kill and relaunch the app
outside SimTool — by tapping its icon or running from Xcode — where the
`SIMTOOL_*` environment is gone. It is hard-gated to the simulator, so device,
TestFlight, and App Store builds never auto-enable, and an explicit
`SIMTOOL_NETWORK_LOGGER=0` opts a run out. The bundled `URLProtocol` capture
covers `URLSession` traffic automatically. Apps whose network layer is gRPC (or
any non-`URLSession` transport) record from their own client interceptor by
calling the framework-agnostic API — `resolved()`/`makeFromEnvironment()` then
`recordGRPC`/`startGRPCCall` — passing bounded message previews that surface as
request/response bodies.

The viewer's **Network** tab is a Proxyman-style inspector beside the live
stream: requests in columns that sort on a click and that you arrange as in
Logs (below: drag a name to move, an edge to size, right-click the header to
show or hide), quick filters (HTTP or gRPC, problems —
failed calls in red, 4xx and client-side gRPC codes in amber — and mocked
calls), pause and clear, and a detail pane under the list. Its head says the
status (`404 Not Found`, gRPC codes by name), the duration, what was sent and
received and when; under it **Request** and **Response** — as tabs, or **Side
by side** — each in sections that fold and stay folded: the request's URL or
gRPC service and method, its query parameters, then the body, then the headers
or metadata; the response's errors first, then its body and headers. A body is
a tree that folds — JSON, or the protobuf text format gRPC loggers print — or
**Raw** text; a preview the app's logger cut short says so and reads as far as
it goes. **Copy as cURL** / **grpcurl** and **Copy as YAML mock** (a `mocks:`
entry that answers the call the same way in a test) sit beside it.

The search field reads URLs, methods, statuses, hosts, headers and bodies —
`url:`, `method:`, `status:`, `host:`, `header:` or `body:` narrows it to one —
marks what it found in the list and the detail, tags a call found only in its
headers or body with where (`response body`), opens the side it is on, and
steps through the marks with ↑ ↓. It updates live from the events endpoint.

The **Logs** tab is a live log inspector with level toggles, free text and
field filters (`subsystem:`, `category:`, `process:`), follow mode — scrolling
up to read turns it off, scrolling back to the end turns it on — and clear; a
line is red only when its level is Error or Fault. Its columns are yours: drag a
column's name to move it and its right edge to size it (double-click the edge
resets it; ⌥← ⌥→ and ←/→ on the edge do the same from the keyboard), and
right-click the header to show **Category** and **Process** or reset them —
the viewer keeps the layout for this browser. When scoped to an app it
captures both the app's OSLog and its `print`/stdout output (via
`--console-pty`), polling the capture endpoint incrementally by cursor; no app
instrumentation is required.

Both inspectors group entries by **app launch**: the server detects each launch
of the inspected app from the OSLog process id (and from network-logger
batches), and the logs and network lists draw an `App launch · <time> · pid <n>`
divider wherever the launch changes. So when you fully kill and relaunch the
app, its new logs and requests keep streaming below a fresh divider while earlier
launches stay visible above (for the life of the server). OSLog
(`os.Logger`/`NSLog`) and network events continue across such a relaunch;
`print`/stdout does **not** — it is only captured while SimTool itself launches
the app with `--console-pty`, so after an icon-tap or Xcode relaunch only OSLog
remains for that source.

Start the server with `--app <bundle-id>` to scope log capture to one app. The
server then captures that app's OSLog **and** `print`/stdout (instead of
flooding with system-wide OSLog), advertises the app via `/config`, and the
viewer's Logs tab captures it from the start. Capturing relaunches the app
once (to attach its console); after that, opening or closing the panel does
**not** restart it — the server-owned capture stays alive and reopening reuses
it:

```sh
swift run simtool serve --device <udid-or-name> --app com.example.MyApp
```

After editing source, resources, project metadata, or common app configuration
files, the checksum changes and the next launch performs a new simulator build:

```sh
swift run simtool app launch --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyApp --json
```

Run XCTest or UI test schemes on a resolved simulator with `app test`:

```sh
swift run simtool app test --device <udid-or-name> --workspace MyApp.xcworkspace --scheme MyAppUITests --json
swift run simtool app test --device <udid-or-name> --project MyApp.xcodeproj --scheme MyAppTests --configuration Debug --json
```

## Model state inspector (`@SimToolDebugState`)

Stream your `@Observable` models' state to the SimTool web UI in debug builds.
Annotate the model and register the instance once:

```swift
import SimToolStateLogger

@Observable                      // optional — see polling below
@SimToolDebugState
final class AppModel {
    var count = 0
    var coords = Coords()        // @SimToolDebugState struct → expands
}

@SimToolDebugState
struct Coords { var x = 0.0 }

// register once (name defaults to the type name):
SimToolState.track(model)
// or chain it where the instance is created — works from DI factories too:
let model = AppModel().simToolTracked()
// plain (non-@Observable) classes are polled (default 1 s); tune with poll:
SimToolState.track(legacy, poll: .milliseconds(250))
```

Add the package to your app (debug configurations only is fine):

```swift
.package(path: "path/to/SimTool/StateLogger"),
// target dependency:
.product(name: "SimToolStateLogger", package: "StateLogger"),
```

The logger is inert unless the app is launched with `SIMTOOL_STATE_LOGGER=1` and
`SIMTOOL_SERVER_URL` (SimTool's app-launch flow sets these). Every change — from
methods, SwiftUI bindings, or async tasks — is debounced (~100 ms) and pushed to
the **State** tab: latest snapshot per model as an expandable tree, plus a diff
history. Notes:

- Requires iOS 17+ for the tracker. `@Observable` classes stream per-transition
  diffs via observation tracking; plain classes auto-fall back to polling
  (1 s default; pass `poll:` to tune — transitions shorter than the interval
  are not captured). Structs cannot be tracked top-level; annotate them to
  expand inside a tracked model. `track` is idempotent per instance and
  `name:` defaults to the type name.
- Snapshots include stored properties only, and only **scalars and collections of
  scalars** (Bool/numbers/String/Date/URL). Nested structs and classes render as a
  `"<TypeName>"` placeholder — annotate the nested class with `@SimToolDebugState`
  too if you want its contents. `@ObservationIgnored` properties appear in
  snapshots (as scalars or placeholders) but do not trigger updates.
- If a tracked model is also nested inside another tracked model (e.g.
  `ScreenModel.counter` where both are tracked), the change history shows
  only the parent's entry (`counter.state.filling: …`) — the child's standalone
  entries would duplicate it, so they are hidden while the parent is alive. The
  child still gets its own card in the model list.
- No method attribution: events tell you *what* changed, not *which method* changed it.
- Snapshots over 256 KB are replaced with a truncation marker.

## Project Config, `run`, and `open`

For a checked-out project you can record the simulator, app, build selection, and
deeplinks once in `.simtool/config.yml` at the project root, then drive everything
with one command. SimTool discovers the config by searching the working directory
and walking up to parent directories. The `.simtool` folder is automatically
git-ignored via its own auto-created `.gitignore`. Pass `--config <path>` to point
at a specific file; its directory then plays the `.simtool` role, so relative paths
in the config resolve against that directory's parent.

Run `simtool init` from the project root to scaffold a starter `.simtool/config.yml`:
it detects the `.xcworkspace`/`.xcodeproj` and scheme where it can, defaults
`simulator` to `booted`, creates the self-ignoring `.gitignore`, and leaves `# TODO`
fields (such as `bundleId`) for you to fill in. It refuses to clobber an existing
config unless you pass `--force`.

`init` also offers to install the two bundled **agent skills** — `simtool`
(build, launch, drive, mock, inspect) and `simtool-test` (write a verifying test
and drive it red to green) — Markdown briefs that teach a coding agent how to
work with your app through this CLI. Run interactively it asks where to put
them; pass `--skill local|global|none` to choose the tree up front and
`--skill-agent claude|codex|both` to choose the layout (`.claude/skills` or
`.codex/skills`):

| Scope | Destination | Applies to |
|---|---|---|
| `--skill local` | `<project>/.claude/skills/` (or `.codex/skills/`) | this checkout (commit it to share with the team) |
| `--skill global` | `~/.claude/skills/` (or `~/.codex/skills/`) | every project on this machine |
| `--skill none` | — | nothing installed |

Non-interactive runs (`--json`, or no TTY) default to `none`, so scripted `init`
never writes outside the project. Re-running `init` leaves an installed skill
alone once you have edited it — `--force` replaces it with the bundled version,
because the `simtool` skill has two placeholder sections, *Project options* and
*Launch argument catalog*, that you are expected to fill in with your
workspace/scheme and with the debug launch arguments your own app reads.

```sh
swift run simtool init --skill local                        # config + both skills for this project
swift run simtool init --skill global --skill-agent both    # …skills for both agents, everywhere
swift run simtool init --skill local --force                 # refresh config and skills from the bundled versions
```

```yaml
# .simtool/config.yml
simulator: "iPhone 16 Pro"          # UDID, name, or `booted` for the first booted simulator
bundleId: com.example.MyApp
build:
  workspace: MyApp.xcworkspace      # or `project: MyApp.xcodeproj`
  scheme: MyApp
  configuration: Debug              # optional, defaults to Debug
  # derivedDataPath: ./DerivedData  # optional
  # settings:                       # optional xcodebuild build settings for every build
  #   MACOSX_DEPLOYMENT_TARGET: "15.0"
  # builder: xcode-mcp              # optional: build in Xcode over MCP, not xcodebuild
server:                             # optional viewer settings
  host: 127.0.0.1                   # the address it listens on; 0.0.0.0 opens it to the network
  port: 3200
deeplinks:
  - name: Details
    url: myapp://items/42
  - name: Settings
    url: myapp://settings?section=general
profiles:                           # optional named launch recipes for tests
  staging-account1:
    arguments: [-UITesting, -Environment, staging, -AutoLogin, "${ACCOUNT1}"]
    env: { SOME_FLAG: "1" }         # exported to the app as SIMCTL_CHILD_*
    # deeplink: myapp://home        # opened once the app is running
```

A test refers to a profile by name (`launch: { profile: staging-account1 }`), so
the app-specific arguments — environment switches, a UI-testing master switch,
the shape of the login arguments — stay in the project config and out of every
test file.

A test that carries its own arguments can simply write the account into them
(`arguments: [-Environment, stable, -FastLoginPhone, "+52 971 624 9725"]`) — argv
reaches `simctl` as separate elements, so spaces need no escaping, and that is
the simplest form. `variables:` covers what inline argv cannot: parameterising a
*shared* profile, and stating a value once when both a `setup:` command and the
run's own launch need it.

```yaml
variables: { ACCOUNT: "+52 971 624 9725" }
launch: { profile: staging-account1 }     # whose argv refers to ${ACCOUNT}
```

`${VAR}` is resolved from `variables:` first, then from the process environment,
and `--var NAME=value` overrides both. The file beats the environment on purpose:
a stale `export` must not silently redirect a test to a different account. Keep a
value out of `variables:` when it must stay in the shell — a real credential,
anything for a production account. Either way an unresolved `${VAR}` fails the
run rather than expanding to nothing, because an empty account argument logs in
as nobody and the test then tests nothing.

`simulator:` is also the default device for **every** command, not just
`run`/`serve`/`open`. With several simulators booted and neither `--device` nor a
config to go by, commands fail instead of picking one: on a machine running
parallel checkouts, guessing means driving another one's simulator, where taps
land elsewhere and the accessibility tree merely looks stale.

Relative `workspace`/`project`/`derivedDataPath` paths resolve against the config
file's directory.

`simtool run` reads the config, boots the configured simulator if needed, builds
for that simulator only (reusing the checksum cache), installs, and launches the
app, then starts the viewer server and prints its URL (`Open http://…`, or the
`url` field with `--json`) — handy for scripts that open the page themselves.
Pass `--web` to also open the browser viewer. It runs in the foreground like
`serve` (Ctrl-C stops it), or pass `--detach` to leave the viewer server running
in the background once the app is launched — build and launch still report in
the foreground, and the printed session (`url` with `--json`) is ready to open.

```sh
swift run simtool run            # server only; open the printed URL yourself
swift run simtool run --web      # …and open the browser viewer
swift run simtool run --detach   # build, launch, leave the server in the background
swift run simtool run --device booted        # run on the first booted simulator
swift run simtool run --device "iPhone 16"   # …or a specific UDID/name, overriding the config
swift run simtool run --config path/to/.simtool/config.yml
```

`run` enables the app-side SimTool network and state loggers by default so the
viewer's Network and State panels work out of the box — it exports
`SIMTOOL_NETWORK_LOGGER`, `SIMTOOL_STATE_LOGGER`, and `SIMTOOL_SERVER_URL` to the
app (via the `SIMCTL_CHILD_` prefix, so they also survive the server's
stdout-capture relaunch). Both are inert for apps that do not link the
corresponding logger package and are compiled out of Release builds. Turn them
off with `--no-network` / `--no-state` or `networkLogger: false` /
`stateLogger: false` in the config.

`serve --app <bundle-id>` arms the same loggers, pointed at itself, for the app
it launches — its stdout-capture relaunch and the viewer's Launch / Relaunch —
with the same `--no-network` / `--no-state` and config switches. An installed
build served this way fills the Network and State panels without `run`.

The source fingerprint hashes only git-tracked (and untracked-but-not-ignored)
files when the project is in a git work tree, falling back to a filesystem walk
otherwise. This keeps gitignored, generated artifacts — a Tuist-managed
`.xcodeproj`/`Derived/` that xcodebuild rewrites on every build, DerivedData,
SPM checkouts — out of the checksum, so they don't spuriously invalidate the
cache.

`run --force` skips the checksum cache: it always builds (xcodebuild, or Xcode
with `xcode-mcp`) and reinstalls the app. Use it when a dependency the fingerprint cannot see
changed — e.g. a local package outside the project root, or a Tuist binary
cache that went stale (then regenerate with `tuist generate` first).

`simtool checksum` records the source checksum for an app you built outside
SimTool — typically from an Xcode post-build phase — so the next `simtool run`
sees a cache hit and reuses that `.app` instead of re-running xcodebuild. It
reads the same `.simtool/config.yml` as `run` (so the recorded checksum and its
cache key match what `run` looks up) and writes the metadata against the built
bundle. The bundle path defaults to `$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME`
(set inside Xcode build phases); pass `--app-path` to override.

```sh
# As an Xcode "Run Script" post-build phase, from $SRCROOT:
simtool checksum --config "$SRCROOT/.simtool/config.yml"

# Or standalone, pointing at a built bundle:
swift run simtool checksum --app-path /path/to/MyApp.app --json
```

`simtool open` opens a configured deeplink on the configured simulator via
`xcrun simctl openurl`. Pass a deeplink `name` to open it directly, or omit it to
choose interactively. `--json` prints a structured result.

```sh
swift run simtool open                 # interactive picker
swift run simtool open Details         # open by name
swift run simtool open Settings --json
```

## HTTP API

Local endpoints:

```text
GET /health
GET /config
GET /api/v1/status
GET /api/v1/devices
GET /api/v1/metrics
GET /api/v1/events (Server-Sent Events)
GET /stream.avcc
GET /stream.avcc?view=3d&theme=dark&bg=1b1d20&aspect=0.8
GET /stream.jpeg
GET /stream.mjpeg
POST /api/v1/input
GET /api/v1/input/stream (WebSocket)
GET /api/v1/device
POST /api/v1/device
GET /api/v1/app?bundleId=<id>
POST /api/v1/app/reveal
POST /api/v1/app/install
POST /api/v1/input/paste-image
POST /api/v1/photos
GET /api/v1/ax/tree?raw=1&format=flat&labeled=1
GET /api/v1/ax/raw
GET /api/v1/ax/find?q=<text>&raw=1
GET /api/v1/logs?lines=200&seconds=2
POST /api/v1/logs/capture
GET /api/v1/logs/capture?since=<cursor>&limit=500
POST /api/v1/logs/capture/stop
GET /api/v1/network?seconds=2&limit=200
GET /api/v1/mocks
GET /api/v1/mocks/ack
GET /api/v1/activity?since=<revision>&limit=200
POST /api/v1/activity
GET /api/v1/tests/<session-id>/evidence/<file>
GET /api/v1/screenshot?maxDim=800&display=<screen>&bezel=1
GET /api/v1/recording
POST /api/v1/recording
POST /api/v1/recording/stop
GET /api/v1/recording/<id>/video
```

The API answers the viewer's own page and clients that are not browsers — the
CLI, `curl`, the app-side loggers posting from the simulator. A page on any
other origin is refused with 403 on every route: it reads no answer (there are
no CORS headers), cannot tap, mock or delete through a plain form-style POST,
cannot open the input socket, and cannot frame the viewer — a link elsewhere
opens it in a tab, nothing more. A `Host` other than an IP address, localhost
or `server.host` is refused too, so a DNS-rebinding page whose name resolves to
127.0.0.1 is not this server either. The viewer runs under a Content Security
Policy that allows only its own files from `/assets/`; nothing under `web/` may
be inline script or `<style>`.

`tests/<session-id>/evidence/<file>` serves a recorded run's evidence — only
the files its session lists (`network.jsonl`, `logs.jsonl`, `state.jsonl`,
failure screenshots…). Step times in a session carry milliseconds.

`activity` is what was done to the device and by whom — `agent` (the CLI, the
HTTP API), `test` (a YAML run) or `viewer` (a person at a SimTool page): every
input with the path its finger took in screen points, mocks armed and removed,
test runs and their steps. Each entry carries a `revision` that moves whenever
it changes (a tap opens, learns where it lands, finishes), so `since` the last
`revision` returns what changed, once per change — the same entries the event
stream's `activity` topic pushes; `run` is the test run driving
the device, while one is. `simtool input …`, `app launch` and `open` act on the
simulator in their own process and report themselves to every live server
streaming that device with `POST /api/v1/activity` — `{"kind", "title",
"detail", "gesture"}` opens an entry, `{"id", "status"}` finishes it — best
effort, never failing the command. A request that sends `X-SimTool-Source:
viewer` is the viewer's own; an input that names a `target` (a test step's
element) is called by it in the feed, never aimed by it.

`mocks/ack` reports the server's mock-rule generation and the newest one an app
has confirmed applying (learned from its poll). A run that declares `mocks:`
waits for the two to meet before its first step — otherwise the app can still be
answering from the real backend while the test believes it is mocked.

`/stream.avcc?view=3d` is a foldable's 3D preview in the screen stream's
envelopes, `theme` choosing the shell's finish, `bg` the backdrop's colour and
`aspect` the frame's shape (width per unit of height — the viewer's stage; the
long side is 1280 px), the device framed to fill it in every pose; before each frame whose map moved it sends an envelope tagged 4 with JSON
`{"pieces", "panel", "hinge", "width", "height"}` — per leaf of the lit panel
the frame corners it lands on and the part of the panel's framebuffer it shows.
It answers 503 with the reason when there is no 3D to show; `/config` says so
ahead in `view3d` (`available`, `reason`).

`screenshot` returns the full-resolution PNG by default; `maxDim` scales it so
the longest edge fits the given pixel size — agents reading the screen pay for
image pixels, and an 800px screenshot is still perfectly legible.
`bezel=1` draws the device around the screen (`simctl … --mask=black` for the
glass, the device type's DeviceKit chrome for the body and buttons).

`recording` records the screen the stream shows, one recording at a time:
`POST` (`{"bezel": true}` for the device around it) starts `simctl io
recordVideo`, `recording/stop` finalizes it and answers once it is saved —
`state` `ready` with `durationSeconds` and `byteCount`, or `failed` with the
`error` — and `recording/<id>/video` serves the mp4 (byte ranges included).
`GET` answers `{"current", "last"}`, which the event stream's `recording` topic
pushes whenever it changes. Only the newest video is kept, in a temporary
folder the server removes when it stops.

A device with more than one screen — the iPhone Duo, a cover panel and an inner
one that opens like a book — streams, screenshots and records the screen that is
lit, and follows it as the device folds. `/config` lists the screens under
`displays` (`id` as simctl names it — `primary`, `primary-1` —, `role` `cover` or
`inner`, the framebuffer `width`/`height`, the picture's `rotation` and its size
in `points`, `active`) and names the lit one in `activeDisplay`; the event
stream's `device` topic sends them again whenever they change. `screenshot`
takes `display=` (an `id`, a `role` or the screen number) for the screen that is
not lit — which reads black. The inner panel's framebuffer is portrait while it
shows a landscape picture: `rotation` 90, `points` 951 × 669.

The `logs/capture` routes drive a continuous capture (OSLog plus optional
stdout/`print`) into a bounded buffer that clients poll incrementally by cursor;
`GET /api/v1/logs` remains the one-shot bounded snapshot.

`/api/v1/events` pushes what the viewer's inspector shows as it changes — one
Server-Sent Events stream per page, with the topics `network`, `logs`, `state`,
`tests`, `launches`, `activity` (an entry of `/api/v1/activity` each time it
changes, with the log's `revision`) and `device` (the device's screens, as
`/config` lists them). It opens with a `snapshot` event holding all of them,
then sends each change once, with `id: <server instance>:<sequence>`. A client
that reconnects with `Last-Event-ID` (or `?lastEventId=`) gets the events it
missed; one whose id is too old, or from a previous run of the server, gets a
fresh snapshot instead. It is same-origin only: the stream sends no CORS headers.
The JSON routes above stay, and the viewer falls back to polling them while the
stream is down.

`POST /api/v1/input` takes an `action` — `tap`, `longPress`, `type`, `paste`,
`swipe`, `scroll`, `fling`, `drag`, `button`, `shake`, `terminate`, `launch`,
`software-keyboard`, `hardware-keyboard`, `pose`, `rotate` — plus that action's fields: `x`/`y` or
`id`/`label` for `tap` and `longPress` (`duration` for the press),
`startX`/`startY`/`endX`/`endY` with `velocity`, `duration`, `hold` (and `press`
for `drag`), `direction` with `distance` or `velocity` and an optional start
`x`/`y` for `scroll` and `fling`, `text` for `type` and `paste`, `enabled` for
`hardware-keyboard` (connect or disconnect it), `visible` for
`software-keyboard` (show or hide it and confirm it on screen; without it, a
toggle), `name` (`closed`, `book`, `open`) or `angle` (0–180) for `pose`,
`name` (`portrait`, `landscape-left`, `landscape-right`, `upside-down`, or
`left` / `right` for a quarter turn) for `rotate`.
Coordinates are screen points. Images go as the raw request body instead:
`POST /api/v1/input/paste-image` pastes one into the focused field, and
`POST /api/v1/photos` adds an image or a video to Photos. Both read the type from
`Content-Type` and an optional percent-encoded `X-SimTool-Filename` header.

`POST /api/v1/device` changes a setting of the device or acts on it, as one
activity entry, and answers with what the device reports afterwards in
`stdout`: `{"action": "appearance", "value": "light"|"dark"}`, `content-size`
(`value`: a size, `increment`, `decrement`), `increase-contrast` (`enabled`),
`debug` (`option`, `enabled`), `memory-warning`, `biometrics` (`value`:
`enroll`, `unenroll`, `match`, `nomatch`), `push` (`payload` with `aps`,
`bundleId` — the server's app by default), `status-bar` (`statusBar` with
`time`, `dataNetwork`, `wifiMode`, `wifiBars`, `cellularMode`, `cellularBars`,
`operatorName`, `batteryState`, `batteryLevel`; or `value: "clear"`) and
`location` (`location` with `waypoints` of `latitude`/`longitude` and, for a
route, `speed`, `interval` or `distance`; or `value: "clear"`). `GET
/api/v1/device` reads them all back — `appearance`, `contentSize`,
`increaseContrast`, `debug`, `biometrics` (`kind` face or touch, `enrolled`),
`statusBar` (the overrides in force), `location` (the one SimTool last set),
`accessibility` (`reduceMotion`, `reduceTransparency`, `buttonShapes`,
`voiceOver`, `colorFilter`, `liquidGlass`), `orientation` — and names in
`unavailable` whatever the device would not say, and why. More actions:
`accessibility` (`option`: `reduce-motion`, `reduce-transparency`,
`button-shapes`, `voiceover` with `enabled`, or `color-filter`, `liquid-glass`
with `value`), `permission` (`option`: a permission, `value`: `grant`, `deny`,
`reset`, `always` for location, `bundleId` — the server's app by default) and
`keychain` (`value`: `reset`, `add-root-cert`, `add-cert`; `certificate`: the
file's bytes in base64). `GET /api/v1/app` is the app's card — `installed`,
`name`, `version`, `build`, `minimumOS`, `pid`, `bundlePath`, `dataContainer`,
`permissions` — for `bundleId` or the server's app; `POST /api/v1/app/reveal`
(`{"bundleId", "what": "bundle"|"data"}`) shows one in the Finder of the Mac the
server runs on; `POST /api/v1/app/install` installs the build in the body — an
`.ipa`, or a tar of an `.app` — and answers its `bundleId` and `name`.

`GET /api/v1/camera` is the simulator's camera: `source` (`none`, `image`,
`video`, `webcam`), `name` (the file's, or the Mac camera's), `apps` (each with
`bundleId`, `pid`, `running` — whether it captures now) and `macCameras` (`id`,
`name`). `POST /api/v1/camera` takes an image or a video as the raw body, typed
by `Content-Type` or `X-SimTool-Filename`; `POST /api/v1/camera/webcam`
(`{"camera": id or a part of the name}`, optional) captures the Mac's camera
until another source or `DELETE /api/v1/camera`, which turns it off. Each
answers the new state.

`/api/v1/input/stream` is the viewer's live finger and keyboard: a WebSocket
taking one JSON frame per touch event, `{"t": "down"|"move"|"up", "x": 0.5,
"y": 0.7}` with coordinates as fractions of the screen, plus `x2`/`y2` for a
second finger and, on a foldable, `"d"` — the screen shown (`primary-1`) — and
one per key, `{"t": "keydown"|"keyup", "code": "KeyA"}` with
the browser's `KeyboardEvent.code`. Frames are never answered; moves are
coalesced, downs, ups and keys never dropped, and when the socket closes a
finger still down is lifted where it was and held keys are released.

`SimToolClient` exposes these routes as typed async Swift calls.
