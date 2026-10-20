# Product

<!-- impeccable:product-schema 1 -->

> Written by `impeccable init` without a live interview: the owner asked for an
> autonomous run. Facts come from README.md and the redesign brief; lines marked
> *(assumption)* are inferences awaiting the owner's confirmation.

## Platform

web

## Users

- **iOS developers** working on their own app in the simulator: they watch and
  drive the device from a browser tab next to their editor, and read what the
  app does (network, logs, model state, accessibility tree) while it runs.
- **Coding agents** (Claude Code, Codex) that drive the simulator through the
  CLI/HTTP API and open the viewer in an embedded browser (e.g. Orca) so a
  person can watch the run and review the recorded evidence afterwards.
- **Reviewers** (developers, QA) who open a recorded test session to answer
  "did the claim hold?" from the timeline, video and evidence.

## Product Purpose

SimTool is a project-agnostic Swift CLI/server that streams and automates Apple
Simulators. The web viewer is its human surface: a live, interactive device
screen (mouse is a finger, Mac keyboard is a hardware keyboard) plus an
inspector for the app under test — Network (HTTP + gRPC, mocks), Logs (OSLog +
stdout, per app launch), State (`@SimToolDebugState` snapshots and diffs), AX
(accessibility tree with on-screen picking) and Tests (YAML tests, runs,
recorded sessions with verdicts and video).

Success: a developer keeps the viewer open all day instead of Simulator.app +
Proxyman + Console.app, and a reviewer can judge a recorded run without opening
`session.json`.

## Positioning

One local page that is at once the device, its debugger and its test recorder,
fed by the same server agents automate — what an agent did and what the app did
are visible side by side, on the same timeline, in a browser tab.

## Operating Context

- Runs on `127.0.0.1` from `simtool serve` / `simtool run` / `simtool test run`;
  usually one viewer per simulator, several in parallel on one Mac (parallel
  checkouts, ports 3200+).
- Opened in desktop Chrome/Safari and in embedded browsers (Orca), often in a
  narrow side pane next to an editor or terminal *(assumption: narrow panes are
  as common as full windows)*.
- Long sessions: the tab stays open for hours; the server may restart under it.
- Evidence (logs, network, state) contains real traffic of a test account and
  must not leave the team.

## Capabilities and Constraints

- Delivered as one Swift string (`Tool/Sources/SimToolWeb/WebViewer.swift`):
  inline HTML/CSS/JS, no build step, no external CDN at runtime, works offline.
- Video is H.264 over WebCodecs only; no JPEG fallback.
- Live touch and keys go over one WebSocket; inspector data arrives over one
  Server-Sent Events stream per page, and polling JSON endpoints is the fallback.
- Must stay project-agnostic: no product-, company- or app-specific content,
  names or styling in the repository.
- Dark ("graphite") is the shipped theme; a light theme is specified in
  DESIGN.md's tokens but deferred. Undecided: localisation (UI is English).

## Brand Commitments

- Name: **SimTool** (CLI binary `simtool`). No logo or brand palette exists;
  the current navy + cyan look is incidental, not a commitment.
- Owner's bar: feels like a mature professional dev tool (Proxyman, RocketSim,
  Chrome DevTools), not an alpha/beta prototype. The owner approved the
  "drafting sheet" direction recorded in DESIGN.md.

## Evidence on Hand

- The running viewer and its API (README.md "Basic Usage", "Automation",
  "Tests and sessions").
- No screenshots, testimonials or usage metrics are in the repo; none may be
  invented.

## Product Principles

1. **The device is the hero; the inspector serves it.** Never hide or shrink the
   screen to make room for chrome the user did not ask for.
2. **Truth over decoration.** Every colour, badge and highlight encodes a real
   state (error, mocked, running, selected); nothing is ornamental.
3. **Keyboard-first, agent-aware.** Everything a person does with the mouse has
   a shortcut; everything an agent did is legible after the fact.
4. **Zero setup.** One binary, one page, offline, no build — the viewer must
   keep working anywhere `simtool` runs.
5. **Project-agnostic.** The tool looks the same for every app it inspects.

## Accessibility & Inclusion

WCAG 2.2 AA for the viewer chrome (contrast, focus, keyboard operation,
reduced motion). The device stream itself is pixels from the simulator and is
out of scope.
