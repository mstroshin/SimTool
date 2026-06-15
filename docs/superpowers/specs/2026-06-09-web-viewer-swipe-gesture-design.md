# Web Viewer Swipe Gesture — Design

Date: 2026-06-09

## Goal

Let a user drag on the web viewer canvas to send a swipe to the simulator,
while a plain tap continues to tap. This is a front-end-only change: the
backend already accepts `action: "swipe"` through `POST /api/v1/input` with the
same pixel coordinate plumbing that `tap` uses.

## Scope

- **Changed file:** `Sources/SimToolWeb/WebViewer.swift` (the embedded JS and
  the canvas CSS).
- **Unchanged:** the server (`StreamServer.handleInput`), the input client
  (`SimulatorDirectInputClient.swipe`), and `APIModels` — they already support
  swipe end to end.

## Behavior

1. Replace `canvas.addEventListener("click", tap)` with pointer-event handlers:
   `pointerdown` / `pointermove` / `pointerup` / `pointercancel`.
2. **`pointerdown`:** record the start point in simulator pixels (via the
   existing `eventToSimulatorPoint`), record the start timestamp, and call
   `canvas.setPointerCapture(event.pointerId)` so the gesture keeps tracking
   even if the pointer leaves the canvas.
3. **`pointerup`:** measure pointer movement in CSS pixels from the start.
   - **Movement < 8px** → treat as a **tap**: send the existing `tap` action at
     the start point. The 8px threshold tolerates finger/mouse jitter so normal
     taps still tap.
   - **Movement ≥ 8px** → send a **swipe**:
     `{ action: "swipe", startX, startY, endX, endY, duration,
     coordinateSpace: "pixels", sourceWidth: streamWidth,
     sourceHeight: streamHeight }`. `duration` is the elapsed wall-clock time
     between `pointerdown` and `pointerup`, expressed in **seconds** (a
     fractional `Double`), **clamped to the range 0.05s–2.0s**. The clamp keeps
     a fast flick usable and caps an absurdly slow drag.
4. **`pointercancel`:** abort the in-progress gesture; send nothing.

Duration unit is seconds because `SimulatorDirectInputClient.swipe` converts the
incoming `duration` with `Int(duration * 1000)` to milliseconds, and the CLI
documents `--duration` as seconds.

## Supporting changes

- Add `touch-action: none` to the canvas element's CSS so a touch-device drag
  performs a swipe instead of scrolling the page.
- Reuse the existing helpers `api`, `setStatus`, `eventToSimulatorPoint`, and
  the `streamWidth` / `streamHeight` globals.
- Keep the standalone `tap(point)` path; the pointerup tap branch calls it.

## Explicitly out of scope (YAGNI)

- No on-canvas visual trail or overlay while dragging.
- No fixed/normalized duration — duration tracks the real gesture timing.
- No multi-touch / pinch / two-finger gestures.
- No backend or API changes.

## Success criteria

- A short press-and-release on the canvas taps at that point (unchanged from
  today).
- A press, drag, and release sends a swipe from the start point to the release
  point, with a duration proportional to how long the drag took (clamped).
- A fast flick and a slow drag over the same distance produce visibly different
  scroll speeds in the simulator.
- On a touch device, dragging on the canvas swipes rather than scrolling the
  page.
