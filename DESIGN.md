---
name: SimTool viewer
description: A drafting sheet of the device under test — one line-weight system, measured in points, where every mark is a fact.
colors:
  g0-stage: "#0e0f11"
  g1-panel: "#17191c"
  g2-chrome: "#1d2024"
  g3-hover: "#25292e"
  g4-pressed: "#2e3339"
  ink1: "#e8eaed"
  ink2: "#a9aeb5"
  ink3: "#8d939b"
  accent: "#6aa4ff"
  on-accent: "#08142a"
  course: "#b48fff"
  ok: "#45c08a"
  warn: "#e7a93f"
  err: "#f26b76"
  line-hair: "rgba(255, 255, 255, .06)"
  line-thin: "rgba(255, 255, 255, .11)"
  line-thick: "rgba(255, 255, 255, .22)"
typography:
  ui:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Segoe UI, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.4
  ui-strong:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Segoe UI, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  data:
    fontFamily: "ui-monospace, SF Mono, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "12px"
    fontWeight: 400
  meta:
    fontFamily: "ui-monospace, SF Mono, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "11px"
    fontWeight: 400
rounded:
  sm: "4px"
  md: "6px"
  lg: "8px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
components:
  button:
    backgroundColor: "{colors.g2-chrome}"
    textColor: "{colors.ink1}"
    rounded: "{rounded.md}"
    height: "26px"
    padding: "0 10px"
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.md}"
    height: "26px"
  toolbar-button:
    textColor: "{colors.ink2}"
    rounded: "{rounded.md}"
    size: "28px"
  row:
    height: "26px"
    padding: "0 12px 0 10px"
  tab:
    textColor: "{colors.ink2}"
    height: "36px"
---

# Design System: SimTool viewer

## Overview

The viewer is the human surface of a developer tool: the simulator's screen, the
app's network, logs, state and accessibility tree, and the tests that drive it —
open all day next to an editor. It is an **Operate** surface: someone who uses
Proxyman, Chrome DevTools or Xcode should know where everything is before they
notice a style.

The direction is a **drafting sheet**: hierarchy comes from line weight, not from
glow, glass or shadow; the device is measured in points; colour appears only
where the data carries a state. Its one signature move is the **redline** — in
the Accessibility tab the picked element is drawn with its distances to the
screen edges and to the element under the pointer, next to rulers, in the same
points a YAML step or `simtool input tap` uses.

The source of truth for every value is `web/viewer.css` (`:root`); this file
explains them.

## Colors

A ground in four steps, three ink levels, and four inks that each mean exactly
one thing — in two themes: **graphite sheet** (dark) and **drafting film**
(light). The values below are graphite's; film's are in the table under Themes.

### Neutral
- **g0 stage** `#0e0f11` — behind the device; the darkest plane.
- **g1 panel** `#17191c` — the inspector and detail panes.
- **g2 chrome** `#1d2024` — toolbar, tabs, headers, menus, status bar.
- **g3 hover / g4 pressed** — interaction states only.
- **ink1** for content, **ink2** for secondary text, **ink3** for meta — every
  text pair passes WCAG AA in both themes.

### Primary — accent `#6aa4ff`
Selection, focus, the primary action, redlines. Nothing decorative.

### Secondary — course `#b48fff`
What SimTool did to the app: the finger on the screen, test steps and their
marks on the scrubber, mocked calls, the keyboard routed into the device. The
app's own data never uses it.

### States
- **ok** `#45c08a`, **warn** `#e7a93f`, **err** `#f26b76` — only when the data
  says so: HTTP 2xx / 4xx / 5xx and transport failures, gRPC codes by class,
  log level Error and Fault, verdicts.
- **Recording** is the one red that is not a failure: the REC mark of a screen
  recording in progress, in err ink — every recorder marks recording so, and it
  must not be missed.

### Named Rules
- **Colour is a fact.** A colour must trace to a field: status class, log level,
  verdict, mock, selection. Words in a message never colour a line.
- **Earlier launches read quieter.** Rows from a previous app launch use ink2;
  their failures keep their colour.
- **Every colour is a token.** Literal colours live only on `:root`, each as
  `light-dark(<film>, <graphite>)`; rules only name tokens. The device's screen
  is the app's, so `--screen-black` and `--screen-ink` (words on the screen) are
  the same in both themes.
- **Meta steps up on a tint.** On a selected row, ink3 reads as ink2; a
  destructive menu item lights up in err-bg, not the accent tint; the Error badge
  on an error row is outlined, not filled — tints on tints fall under 4.5:1.

### Themes
The viewer follows the system's appearance (`color-scheme: light dark`). The
sun / moon button in the toolbar (and "Use the light / dark theme" in the
palette) pins the other theme for this browser; a pin that matches the system
is dropped, so two clicks always lead back to following it. A pin is applied in
`<head>`, before anything is drawn.

| Token | Drafting film (light) | Graphite (dark) | Text contrast, min over g0–g3 (film / graphite) |
|---|---|---|---|
| g0 / g1 / g2 / g3 / g4 | `#e6e8eb` / `#f7f8f9` / `#ffffff` / `#eceef1` / `#e1e4e8` | `#0e0f11` / `#17191c` / `#1d2024` / `#25292e` / `#2e3339` | — |
| line hair / thin / thick | ink `rgb(16 20 26)` at 7 / 13 / 28 % | white at 6 / 11 / 22 % | — |
| ink1 / ink2 / ink3 | `#15171a` / `#4a5059` / `#5f6670` | `#e8eaed` / `#a9aeb5` / `#8d939b` | 14.6 / 6.6 / 4.7 — 12.1 / 6.6 / 4.7 |
| accent, on-accent | `#1f5fd6`, `#ffffff` (5.7:1) | `#6aa4ff`, `#08142a` (7.3:1) | 4.7 — 5.8 |
| course | `#7442d6` | `#b48fff` | 4.9 — 5.8 |
| ok / warn / err | `#18744b` / `#925600` / `#b82833` | `#45c08a` / `#e7a93f` / `#f26b76` | 4.7 / 4.8 / 5.0 — 6.4 / 7.1 / 5.0 |
| JSON string / number / literal | `#2b7236` / `#8a5a00` / `#1f5fd6` | `#9fd49b` / `#e7c27a` / `#8fb8ff` | 4.8 / 4.8 / 4.7 — 8.6 / 8.6 / 7.3 |
| overlay shadow | `rgba(16,20,26,.18)` | `rgba(0,0,0,.55)` | — |

Film keeps the redesign's proposal except two inks darkened to hold AA where
they really sit: **err** `#c42d39` → `#b82833` (the exclude chip on the filter
field and the Error badge on an error row were 4.2–4.4:1) and **JSON string**
`#2f7a3a` → `#2b7236` (4.3:1 on the code block's g0). `WebViewerPageTests`
checks every ink on g0–g3 in both themes.

## Typography

System faces only, nothing to download: SF Pro for the interface, SF Mono with
tabular figures for data, times, paths and numbers.

### Hierarchy
- 13 px / 600 — titles in detail panes and dialogs.
- 12 px / 400–500 — interface text, list rows, messages.
- 11 px — meta, timestamps, counts, column headers. Never smaller.
- Sentence case everywhere; no tracked capitals.

## Layout

- One full-bleed window in three rows: toolbar (44 px), workspace, status bar (26 px).
- The workspace is **stage | splitter | inspector**. The stage is as wide as the
  device needs at full height; the inspector takes the rest; the splitter is
  draggable and keyboard-resizable and remembers its place.
- Below 760 px of width the inspector stacks under the device — it never covers it.
- Lists put their detail **under** the list (split view), never instead of it.
- Under each list toolbar a guide line says what span is in view and whether the
  list is still moving.
- Spacing on a 4 px step: 4 / 8 / 12 / 16 / 24.

## Elevation & Depth

Flat by default. Depth is drawn with hairline (6 %), thin (11 %) and thick (22 %)
lines. Only overlays that float over content — menus, the command palette,
dialogs, toasts, the offline card — carry one shadow: `0 16px 40px rgba(0,0,0,.55)`
(film: ink at 18 %).

## Shapes

Radii 4 / 6 / 8 px: controls 6, popovers 8, chips 3–4. The device keeps its own
screen corner radius, scaled to its size.

## Components

### Buttons
Toolbar buttons are 28 px squares with a 16 px line icon (1.5 px stroke) and a
tooltip naming the action and its shortcut. Text buttons are 26 px (24 px small);
primary buttons fill with the accent; destructive actions are red text and
always confirm.

### Chips
Filter chips sit inside the filter field: include chips are outlined in ok,
exclude chips tinted in err with a leading minus; each has its own remove button.

### Menus
A toolbar button with a caret drops a menu under it and says whether it is open.
An item that is on or off carries a switch — in course ink while on, as the keys
it sends to the device are; one choice of several is ticked in accent. Groups
are named by a caption in ink3. The keyboard button turns course while the Mac
keyboard types into the device; the capture caret carries a small device while
screenshots and videos take the bezel.

### Inputs
The filter field is the only text input on most screens: 26 px, thick outline,
accent ring on focus, `/` to reach it.

### Navigation
Inspector tabs follow the WAI-ARIA tab pattern (arrows, Home/End, ⌥1–5) with a
2 px accent underline and counts in mono; failures get a red dot, and with none,
client-side problems (4xx, gRPC client codes) an amber one — the colours the rows use.

### Lists
Keyed rows that survive polling, 26 px high, roving focus, ↑/↓/Home/End,
Enter to open, Esc to clear, Shift-F10 for the row's menu; sticky column
headers that sort; app launches as collapsible groups. The columns of Network
and Logs are the person's: dragged into another order by their names (a click
still sorts), sized by the line at their right edge (accent while it is dragged
or focused), shown or hidden from the header's menu — remembered per browser,
per table; the flexible column (Name, Message) takes what is left. A request's body reads as a tree that folds, in
the code block's ground, with the JSON inks.

### Redlines (signature)
Faint outlines on every element a test can name; a dashed outline on the
element under the pointer — dark dashes on a light line, because it sits on the
app, which is light or dark whatever the viewer's theme; the picked element
filled in accent with dimension lines and labels in points; rulers every 50 pt,
labelled every 100 pt.

## Do's and Don'ts

### Do:
- Show the device first and keep it uncovered.
- Say the true state: offline is offline, a replay says Replay, an old
  timestamp says how old it is.
- Give every mouse action a keyboard path and every icon a spoken name.
- Ask before deleting anything another viewer or a reviewer relies on.

### Don't:
- Don't use emoji, glow, glass, gradients or decorative colour.
- Don't colour by guessing from text.
- Don't replace a list with its detail.
- Don't add a literal colour outside `:root`.
