# Web Viewer AX Inspector — Design

Date: 2026-06-09

## Goal

Turn the web viewer's stub "AX" tab into a working accessibility inspector,
modelled on element inspectors like browser DevTools / Appium Inspector. While
the AX tab is open the viewer:

1. Renders the simulator's accessibility tree (identifiers, labels, roles) as a
   collapsible tree.
2. Draws highlight overlays for every element over the live device screen, with
   the selected element highlighted strongly.
3. Lets the user select an element either by clicking a tree row or by clicking
   the element on the device screen — the two stay in sync.
4. Offers a **Copy** button that puts the fullest possible JSON description of
   the selected element on the clipboard, for handing to an agent.

## Scope

- **Changed file:** `Sources/SimToolWeb/WebViewer.swift` (the embedded HTML for
  `#axPane`, the CSS, and the embedded JS).
- **Unchanged backend:** `GET /api/v1/ax/tree` already returns the normalized
  tree (`AccessibilityTreePayload { roots: [AccessibilityNode], nodeCount }`).
  Each `AccessibilityNode` carries `id`, `accessibilityIdentifier`, `label`,
  `value`, `title`, `role`, `roleDescription`, `type`, `enabled`, `pid`,
  `frame {x,y,width,height}`, `children[]`, and `raw` (the original `axe`
  JSON). No Swift/server changes are required. `ancestorPath` is derived on the
  client from the tree structure.
- **Possible test-only addition:** a Swift smoke test asserting the generated
  HTML contains the new AX anchors.

## Decisions (confirmed)

- **Refresh model:** periodic polling of `/api/v1/ax/tree` (~2s), mirroring the
  Network/Logs tabs. Accepted trade-off: `axe describe-ui` is heavy and will
  load the simulator continuously while the AX tab is open.
- **Canvas tap while AX active:** clicking the screen **selects** the element
  under the point; it is **not** forwarded to the simulator as a tap/swipe.
- **Overlay density:** every node with a frame gets a thin outline; the selected
  (and tree-hovered) node is highlighted strongly.
- **Copy format:** full JSON only — normalized fields + `ancestorPath` + `frame`
  + `raw`.

## Coordinate mapping (the critical detail)

The canvas streams **device pixels** (`streamWidth × streamHeight`, downscaled
to ≤1280 on the long edge). The AX `frame` values from `axe describe-ui` are in
**points** (logical screen coordinates). The two spaces differ, so overlays are
normalized against the **root node's frame**, which equals the full-screen
bounds in points.

> **Verified gotcha (real device):** the tree mixes coordinate spaces. The root
> `AXApplication` frame is in points (e.g. 402×874), but a chain of ~24
> unlabeled container `AXGroup`s report their frame in **device pixels**
> (1206×2622 = 3×). Picking the *largest-area node overall* would therefore grab
> a pixel-space group and squash every real element into the top-left third.
> The reference must be the **largest-area root frame** (roots are the
> `AXApplication`s, always in points), and the overlay must **skip frames that
> overflow the point-space screen** (normalized width/height > 105%) so the
> pixel-scaled containers don't render as noise. Hit-testing is unaffected:
> those oversized frames never win the smallest-area contest.

```
rootFrame = largest-area root node frame          // {x, y, width, height} in points
ratioX = (node.x - rootFrame.x) / rootFrame.width  // 0..1
ratioY = (node.y - rootFrame.y) / rootFrame.height
left   = ratioX * surface.clientWidth              // CSS px inside .surface
top    = ratioY * surface.clientHeight
width  = (node.width  / rootFrame.width)  * surface.clientWidth
height = (node.height / rootFrame.height) * surface.clientHeight
```

`.surface` is already sized to the stream aspect ratio by `updateSurfaceSize()`,
and `<canvas>` fills it with `object-fit: contain` and no letterboxing, so the
surface box equals the displayed image. An overlay layer stretched over
`.surface` therefore aligns exactly, with no need to know the device pixel ratio
or the point↔pixel scale. Nodes with a missing or zero-area frame are skipped
for drawing and hit-testing (they still appear in the tree).

## Components

### Overlay layer + hit-testing

- Add `<div id="axOverlay">` inside `.surface`: absolutely positioned over the
  whole surface, `pointer-events: none`, hidden unless the AX tab is active.
  Drawing into the `<canvas>` itself is impossible — it is repainted on every
  video frame via `requestAnimationFrame` and would wipe the overlay.
- One thin-outline `div` per node with a frame. The selected node gets a bright
  box (strong border + faint fill); a tree-hovered node gets a medium box.
- **Hit-test:** convert the click point to a ratio of `.surface`, then pick the
  node with the **smallest area** whose frame contains the point (the deepest
  element under the finger).
- Overlays are repositioned on tree change and on resize (`updateSurfaceSize`,
  the existing `window resize` handler).

### AX tree panel (replaces the `#axPane` stub)

- Nested `ul`/`li` with disclosure chevrons (visually consistent with the
  existing `launch-divider` chevrons) and per-depth indentation.
- Row label: `accessibilityIdentifier` → else `label` → else `role`/`type`;
  with a muted secondary showing `role`/`type`.
- Clicking a row selects the node. Hovering a row highlights it on screen.
- Enable the inspector filter input for AX (currently `disabled` for the `ax`
  tab): a client-side filter over id/label/value/role/type that keeps matches
  plus their ancestors and auto-expands to matches.
- A compact status line: node count + "updated Ns ago" + a manual **Refresh**
  button (polling already refreshes; the button is for an immediate pull).

### Selection sync (two-way)

- A single `axSelectedKey` holds `node.id` (already stable:
  `accessibilityIdentifier|label|role|path`).
- **Tree → screen:** mark the row selected and redraw the bright overlay box.
- **Screen → tree:** hit-test → set `axSelectedKey`, expand the node's
  ancestors, scroll its row into view, redraw the overlay.

### Canvas select mode

- `axSelectMode = inspectorOpen && activeTab === "ax"`.
- In the canvas `pointerup` handler, when `axSelectMode` is true, treat the
  gesture as a **selection** (hit-test at the release point) and return without
  calling `sendTap`/`sendSwipe`. The canvas cursor switches from `crosshair` to
  the default arrow in this mode. To interact with the app again the user
  switches tabs or closes Inspect; polling then picks up the new screen state.

### Copy

- When a node is selected, a sticky header in the AX panel shows a short summary
  and a **Copy JSON** button.
- The clipboard payload is pretty-printed JSON:

  ```json
  {
    "accessibilityIdentifier": "...",
    "label": "...",
    "value": null,
    "title": null,
    "role": "AXButton",
    "roleDescription": "...",
    "type": "Button",
    "enabled": true,
    "pid": 1234,
    "frame": { "x": 24, "y": 640, "width": 345, "height": 48 },
    "ancestorPath": ["Window", "ScrollView", "Log In"],
    "raw": { "...": "full axe JSON for this node" }
  }
  ```

- Use `navigator.clipboard.writeText` with a `document.execCommand("copy")`
  fallback, plus transient "Copied ✓" feedback on the button.
- **Right-click (contextmenu)** on a tree row or on an element on the device
  screen selects the element under the cursor and opens a small context menu
  with a **Copy element** button; clicking it copies that node's JSON (shared
  `copyAxNode` helper). The menu dismisses on outside click, Escape, or scroll.

## Polling & state

- Follows the `startNetworkPolling` / `stopNetworkPolling` pattern, wired into
  `setActiveTab` and `setInspectorOpen`: poll `/api/v1/ax/tree` every ~2s **only**
  while the AX tab is active and the inspector is open; stop otherwise.
- Guard against overlapping requests — `describe-ui` itself can take ~1–2s, so do
  not start a new fetch until the previous one resolves. On error, keep the last
  good tree and surface the error in the status line.
- Preserve across refreshes: the set of expanded node keys, `axSelectedKey`, and
  scroll position. The selected node and expansion are matched by `node.id`.

## Edge cases

- `axe` unavailable / `describe-ui` fails → error state in the AX panel (same
  spirit as `logsStatus`).
- Empty tree → an empty-state line.
- Nodes without a frame → present in the tree, not drawn or hit-tested.
- Large trees (hundreds of nodes) → MVP draws all overlay boxes; if rendering
  lags, cap or virtualize later. Noted as a risk.

## Testing

The JS lives inside a Swift string literal, so JS unit tests are not practical.

- **Automated:** a Swift smoke test asserting `WebViewer.html()` contains the new
  AX anchors (the tree container, overlay layer, and copy button ids).
- **Manual:** `swift run simtool serve --device <udid>` against a booted
  simulator, then verify: tree renders and refreshes; overlays align with UI;
  selection syncs both directions; canvas clicks select (do not tap through);
  Copy puts the expected JSON on the clipboard; polling starts/stops with the
  tab and inspector.

## Non-goals

- No backend changes to `axe`/`describe-ui` plumbing.
- No editing/automation of elements from the inspector (tap-by-id etc.) in this
  iteration — selection and copy only.
- No overlay virtualization for very large trees in this iteration.
