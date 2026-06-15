# Resizable viewer card width

## Problem

The viewer card is fixed at `min(720px, 100vw - 32px)`, so the inspector column
(AX tree, logs, network) is stuck at 400px. Wide content — deep AX trees, long
log lines, network URLs — gets clipped with no way to see more of it.

## Design

**Drag either card edge to resize the whole card.**

- Two invisible 6px hit strips (`#cardResizeLeft`, `#cardResizeRight`) sit on
  the card edges with `cursor: ew-resize`; they highlight on hover and while
  dragging.
- The card stays horizontally centered, so a drag changes the width by 2× the
  pointer delta — the dragged edge tracks the pointer.
- Width is applied through the `--card-w` CSS variable; the stylesheet clamps
  it with `min(var(--card-w, 720px), calc(100vw - 32px))`. JS enforces only the
  480px floor.
- The chosen width persists in `localStorage` (`simtool.cardWidth`) and is
  restored on load, mirroring the drawer-height behavior.

**Inside the card, the screen pane grows first, then the inspector.**

- In side-by-side layout the screen pane (`.screen-wrap`) takes extra width
  first (`flex: 9999 1 0%`) but caps at `max-width: 600px` while the inspector
  is open (`.stage.layout-side.inspector-open`).
- Past that cap the inspector absorbs all remaining width
  (`flex: 1 0 400px`), which is the point: more room for the AX tree, logs,
  and network panes.
- With the inspector closed there is no cap — the screen pane uses the full
  card.

**Narrow screens are unchanged.** At ≤720px the card is full-bleed and the
resize handles are hidden.

## Testing

`testViewerCardIsHorizontallyResizable` pins the handles, the CSS variable,
the 600px screen cap, the inspector flex rule, and the localStorage key.
