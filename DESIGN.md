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

A graphite ground in four steps, three ink levels, and four inks that each mean
exactly one thing.

### Neutral
- **g0 stage** `#0e0f11` — behind the device; the darkest plane.
- **g1 panel** `#17191c` — the inspector and detail panes.
- **g2 chrome** `#1d2024` — toolbar, tabs, headers, menus, status bar.
- **g3 hover / g4 pressed** — interaction states only.
- **ink1** (14.6:1 on g1) for content, **ink2** (7.9:1) for secondary text,
  **ink3** (5.2:1) for meta — every text pair passes WCAG AA.

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

### Named Rules
- **Colour is a fact.** A colour must trace to a field: status class, log level,
  verdict, mock, selection. Words in a message never colour a line.
- **Earlier launches read quieter.** Rows from a previous app launch use ink2;
  their failures keep their colour.
- **Every colour is a token.** Literal colours live only on `:root`, so a theme
  restates tokens and nothing else (a light "drafting film" theme is specified
  but not shipped).

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
dialogs, toasts, the offline card — carry one shadow: `0 16px 40px rgba(0,0,0,.55)`.

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
headers that sort; app launches as collapsible groups.

### Redlines (signature)
Faint outlines on every element a test can name; a dashed outline on the
element under the pointer; the picked element filled in accent with dimension
lines and labels in points; rulers every 50 pt, labelled every 100 pt.

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
