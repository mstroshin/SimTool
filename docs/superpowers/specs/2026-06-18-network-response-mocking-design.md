# Network Response Mocking via Interceptor — Design

Date: 2026-06-18
Status: Approved (design)

## Problem

SimTool's interceptors today only *observe* network traffic for logging. We want
an agent to be able to **substitute backend responses** so it can exercise
corner cases (errors, slow responses, specific payloads) without touching a real
backend.

The motivating consumer is a gRPC/Connect iOS app whose traffic does **not** go
through `URLSession` — it runs over a NIO-based gRPC/Connect transport, observed
by an in-app typed interceptor (`SimToolNetworkInterceptor`,
`ClientInterceptor<Request, Response>`). The existing `URLProtocol`-based logger
cannot see this traffic, so mocking must happen at the gRPC/Connect interceptor
level.

Key enabler: SwiftProtobuf supports JSON round-tripping
(`Message(jsonUTF8Data:)`). The interceptor is generic over `Response`, so it can
decode a JSON mock body into the *typed* protobuf response and short-circuit the
call — without SimTool ever knowing the concrete protobuf type. This keeps the
core app-agnostic.

## Scope

In scope (MVP):
- Mock **unary** gRPC/Connect responses.
- Success responses (JSON → protobuf), gRPC error statuses, artificial delays,
  and conditional matching (by method, headers, request-body subset, call
  ordering).
- **Live** control: the agent sets/clears rules on the already-running SimTool
  server (`:3200`); the app picks them up without relaunch.
- Mark mocked requests in the Web Network tab.

Out of scope (MVP):
- Streaming RPCs (server/client/bidi). Noted as a future extension.
- Plain HTTP / `URLProtocol` response substitution. The architecture leaves room
  for it (the same `MockStore`/registry), but it is not built here.

## Architecture

```
Agent ──CLI/HTTP──▶ SimTool server (:3200)          [MockRuleRegistry, generation]
                         │  GET /api/v1/mocks
                         ▼
App: SimToolNetworkLogger.MockStore  ◀── poll ───┘   [generic: match, counters, MockDecision]
                         ▲ asks
App: SimToolNetworkInterceptor (gRPC/Connect)        [typed: JSON→protobuf, short-circuit]
                         │  recordGRPC(..., mocked: true)
                         ▼  POST /api/v1/network/events
                   SimTool server ──▶ Web Network tab [🎭 badge]
```

The seam: everything app-agnostic (rule model, matching, registry, delivery,
event flag, web rendering) lives in the **SimTool** repo. Only the short-circuit
with the typed protobuf lives in the **app** repo (`SimToolNetworkInterceptor`
plus the Connect variant), gated by `#if !RELEASE`.

App-agnostic discipline: spec and tests use placeholder method paths such as
`/example.v1.FooService/GetBar` — no real consumer identifiers in code, fixtures,
or docs.

## Components

### 1. `MockRule` model (`SimToolNetworkLogger`, `Codable`)

- `id: String` — assigned by the server.
- **match:**
  - `method: String` — gRPC full-method (e.g. `/example.v1.FooService/GetBar`)
    or HTTP path; exact or glob (`*`).
  - `headerMatch: [String: String]?` — all pairs must match (metadata/headers).
  - `bodyMatch: JSON?` — partial (subset) match against the request JSON.
  - `skip: Int = 0`, `times: Int? = nil` — skip the first N matches, then apply at
    most M times. Combined with rule ordering this expresses "N-th call returns a
    different response".
- **response** (exactly one of):
  - `success`: `bodyJSON: String` (JSON of the typed protobuf response),
    `trailers: [String: String]?`.
  - `error`: `grpcStatus: String` (e.g. `unavailable`, `deadlineExceeded`),
    `message: String?`, `trailers: [String: String]?`.
- `delayMs: Int = 0`.

Evaluation: first matching rule wins (after `skip`/`times` accounting).
`MockStore.decision(fullMethod:headers:requestJSON:) -> MockDecision?` is pure
matching plus per-rule counters. Counters live in the app's `MockStore` instance
→ deterministic within a launch.

`MockDecision` (returned to the interceptor): `kind` (success/error), `bodyJSON?`,
`grpcStatus?`, `message?`, `trailers?`, `delayMs`, `ruleId`.

### 2. Server: `MockRuleRegistry` (`StreamServer`, in-memory)

- `POST /api/v1/mocks` — add a rule → `{ id, generation }`.
- `GET /api/v1/mocks?since=<gen>` — list + `generation`; if unchanged, a light
  "unchanged" response. This is the delivery channel for the app.
- `DELETE /api/v1/mocks/{id}` — remove one.
- `DELETE /api/v1/mocks` — clear all.

Every mutation increments `generation`. The registry only stores rule
definitions; matching and counters happen app-side.

### 3. Delivery to the app

`MockStore` fetches rules on launch and polls `GET /api/v1/mocks?since=<gen>` on
an interval (default ~2s) — cheap via `generation`. Best-effort: if the server is
unreachable, keep the last known rules; calls never block. Active only when the
network logger is active, plus an explicit `mocksEnabled` gate so traffic is never
mocked accidentally.

### 4. App interceptor contract (implemented in the app repo)

On an outgoing unary call, ask `MockStore.decision(...)`. On a match, wait
`delayMs`, then:
- **success:** `try Response(jsonUTF8Data:)` via SwiftProtobuf → emit
  `.metadata → .message(response) → .end(.ok, trailers)` upstream, **without
  hitting the transport**.
- **error:** emit `.end(status: <grpcStatus>, trailers)`.

Same shape for the Connect variant. In both cases call
`logger.recordGRPC(..., mocked: true, mockRuleId: id)`.

### 5. Mark mocked requests (Web)

- `NetworkLoggerModels.swift`: add `mocked: Bool = false` and
  `mockRuleId: String? = nil` to `NetworkLoggerEvent` (Codable defaults keep old
  events backward-compatible).
- `recordGRPC` / `recordHTTP` gain a `mocked` parameter (and `mockRuleId`).
- `WebViewer.swift` (`renderNetworkList`): add `" mocked"` to the row class and a
  🎭 badge next to the method; CSS `.network-row.mocked` shows a purple left
  border. Request detail shows a "Mocked by rule `<id>`" line.

### 6. CLI

```
simtool mock set --method <path>
                 [--match-header k=v ...] [--match-body '<json>']
                 (--body '<json>' | --error <status> [--message m])
                 [--delay ms] [--skip N] [--times M]
                 [--from-event <eventId>]
simtool mock list
simtool mock remove <id>
simtool mock clear
```

`mock set` prints the assigned `id`. `--from-event <eventId>` seeds the mock body
from a previously logged real response (record real → tweak → replay the corner
case).

## Error handling

- **JSON → protobuf decode fails:** the mock is **not** applied; the call goes to
  the real backend; a warning is recorded in the server `warnings` channel and a
  `mockError` annotation is attached to the event. The agent sees the mock was
  malformed and why. Never silently break the app.
- **Server unreachable for fetch:** keep the last known rules; best-effort, calls
  never block.
- **Release builds:** all mocking code is under `#if !RELEASE`; absent in
  production.

## Testing

- Unit (`SimToolNetworkLogger`, app-agnostic): method-glob/header/body-subset
  matching, `skip`/`times` counters, first-rule-wins selection.
- Server: registry set/list/remove + `generation` increment, `?since=` semantics.
- CLI: argument parsing, `--from-event`.
- App-side (separate task, app repo): JSON → protobuf → short-circuit round-trip
  on one known type.
- Web: manual check of the badge.

## Future extensions

- Streaming RPC mocking (fixed sequence of messages for server-streaming).
- Plain HTTP / `URLProtocol` response substitution reusing the same registry and
  `MockStore`.
- Push delivery (piggyback `mockGeneration` on the ingestion response) instead of
  polling.
