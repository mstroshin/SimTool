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
