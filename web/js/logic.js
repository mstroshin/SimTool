// Pure viewer logic: no DOM, no network, no timers. Everything here is
// exercised on its own in JavaScriptCore (WebViewerLogicTests), so the page
// can only disagree with the tests where it touches the browser.

// ---- Time, sizes, counts ----

function pad2(value) { return String(value).padStart(2, "0"); }

// One clock for the whole viewer: local time, HH:MM:SS, milliseconds when asked.
// Anything unparseable shows as it came, so a bad timestamp is visible rather than hidden.
function formatClock(value, withMilliseconds) {
  if (value == null || value === "") return "";
  const date = value instanceof Date ? value : new Date(typeof value === "number" ? value * 1000 : value);
  if (isNaN(date.getTime())) return String(value);
  const clock = pad2(date.getHours()) + ":" + pad2(date.getMinutes()) + ":" + pad2(date.getSeconds());
  return withMilliseconds ? clock + "." + String(date.getMilliseconds()).padStart(3, "0") : clock;
}

// "20 Oct 12:31" — a day no reader can take for a month.
function formatDayTime(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (isNaN(date.getTime())) return "";
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return date.getDate() + " " + months[date.getMonth()] + " " + pad2(date.getHours()) + ":" + pad2(date.getMinutes());
}

function formatAgo(value, now) {
  const date = value instanceof Date ? value : new Date(value);
  if (isNaN(date.getTime())) return "";
  const seconds = Math.max(0, Math.round(((now == null ? Date.now() : now) - date.getTime()) / 1000));
  if (seconds < 45) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return minutes + " min ago";
  const hours = Math.round(minutes / 60);
  if (hours < 24) return hours + " h ago";
  return formatDayTime(date);
}

function formatDuration(milliseconds) {
  if (milliseconds == null || !isFinite(milliseconds)) return "—";
  if (milliseconds < 1000) return Math.round(milliseconds) + " ms";
  const seconds = milliseconds / 1000;
  return (seconds < 10 ? seconds.toFixed(2) : seconds < 100 ? seconds.toFixed(1) : Math.round(seconds)) + " s";
}

function formatBytes(bytes) {
  if (bytes == null || !isFinite(bytes)) return "—";
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " kB";
  return (bytes / 1024 / 1024).toFixed(1) + " MB";
}

// Seconds as m:ss for recordings.
function formatOffset(seconds) {
  if (!isFinite(seconds) || seconds < 0) seconds = 0;
  return Math.floor(seconds / 60) + ":" + pad2(Math.floor(seconds % 60));
}

function formatCount(value) {
  return Number(value || 0).toLocaleString("en-US");
}

function plural(count, one, many) {
  return formatCount(count) + " " + (count === 1 ? one : many);
}

// "com.apple.CoreSimulator.SimRuntime.iOS-26-4" → "iOS 26.4"
function runtimeName(identifier) {
  if (!identifier) return "";
  const match = /SimRuntime\.([A-Za-z]+)-(\d+(?:-\d+)*)$/.exec(identifier);
  if (!match) return identifier;
  return match[1] + " " + match[2].replace(/-/g, ".");
}

// ---- Network ----

const GRPC_CODES = ["OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND", "ALREADY_EXISTS",
  "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED",
  "INTERNAL", "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED"];
// Codes that say the caller asked for something the server would not do — the
// app's own problem, not the server's.
const GRPC_CLIENT_CODES = [1, 3, 5, 6, 7, 9, 10, 11, 16];

function grpcCodeName(code) {
  const number = Number(code);
  return Number.isInteger(number) && GRPC_CODES[number] ? GRPC_CODES[number] : String(code);
}

// Severity is "ok", "info" (neither good nor bad: redirects, not-modified),
// "warn" (the client's request was refused), "err" (the server or transport
// failed), or "pending" (no answer yet).
function networkStatus(event) {
  if (event.error) {
    return { text: "Failed", severity: "err", title: event.error.message || "The request failed" };
  }
  const response = event.response;
  if (event.protocol === "grpc") {
    if (!response || response.grpcStatusCode == null || response.grpcStatusCode === "") {
      return { text: "Pending", severity: "pending", title: "No status yet" };
    }
    const code = Number(response.grpcStatusCode);
    const name = grpcCodeName(response.grpcStatusCode);
    const severity = code === 0 ? "ok" : GRPC_CLIENT_CODES.indexOf(code) >= 0 ? "warn" : "err";
    const title = response.grpcStatusMessage ? name + " — " + response.grpcStatusMessage : name;
    return { text: code === 0 ? "OK" : name, severity, title, code };
  }
  if (!response || response.statusCode == null) {
    return { text: "Pending", severity: "pending", title: "No response yet" };
  }
  const status = response.statusCode;
  const severity = status >= 500 ? "err" : status >= 400 ? "warn" : status >= 300 ? "info" : "ok";
  return { text: String(status), severity, title: "HTTP " + status, code: status };
}

// 4xx, client gRPC codes and failed calls: what the Problems filter keeps.
function isNetworkProblem(event) {
  return ["err", "warn"].includes(networkStatus(event).severity);
}

// The marks a list of calls carries: failures in red, client-side problems
// (4xx, UNAUTHENTICATED…) in amber — the colours their rows use.
function networkMarks(events) {
  let failed = 0, problems = 0;
  for (const event of events) {
    const severity = networkStatus(event).severity;
    if (severity === "err") failed++;
    else if (severity === "warn") problems++;
  }
  return [{ count: failed, tone: "err", one: "failed", many: "failed" }, { count: problems, tone: "warn", one: "client error", many: "client errors" }];
}

function requestPath(event) {
  const request = event.request || {};
  if (event.protocol === "grpc") {
    return request.path || "/" + [request.grpcService, request.grpcMethod].filter(Boolean).join("/");
  }
  return request.url || request.path || "";
}

function lastPathSegment(rawPath) {
  if (!rawPath) return "";
  let path = String(rawPath);
  const cut = path.search(/[?#]/);
  if (cut >= 0) path = path.slice(0, cut);
  const segments = path.replace(/\/+$/, "").split("/").filter(Boolean);
  return segments.length ? segments[segments.length - 1] : path;
}

// What a row calls a request: the method name for gRPC, the last path segment for HTTP.
function requestName(event) {
  const request = event.request || {};
  if (event.protocol === "grpc") return request.grpcMethod || lastPathSegment(requestPath(event)) || "call";
  return lastPathSegment(requestPath(event)) || request.host || "request";
}

// Where it went: the service for gRPC, host + path for HTTP.
function requestWhere(event) {
  const request = event.request || {};
  if (event.protocol === "grpc") return request.grpcService || request.grpcAuthority || "";
  const raw = requestPath(event);
  try {
    const url = new URL(raw, "http://localhost");
    return (request.host || url.host) + url.pathname + url.search;
  } catch (_) {
    return raw;
  }
}

// The path a filter chip keeps: no host, no query; gRPC keeps service/method.
function chipPathForEvent(event) {
  const raw = requestPath(event);
  if (!raw || event.protocol === "grpc") return raw;
  try { return new URL(raw, "http://localhost").pathname; } catch (_) { return raw; }
}

function networkSize(event) {
  const response = event.response || {};
  const size = event.protocol === "grpc" ? response.messageByteCount : response.bodyByteCount;
  return size == null ? null : size;
}

function networkHaystack(event) {
  const request = event.request || {};
  const status = networkStatus(event);
  return [requestPath(event), request.method, request.host, status.text, status.title, event.protocol,
    event.mocked ? "mocked " + (event.mockRuleId || "") : ""].filter(Boolean).join(" ").toLowerCase();
}

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

function curlCommand(event) {
  const request = event.request || {};
  const parts = ["curl"];
  const method = (request.method || "GET").toUpperCase();
  if (method !== "GET") parts.push("-X " + method);
  parts.push(shellQuote(request.url || ("https://" + (request.host || "") + (request.path || ""))));
  for (const [name, value] of Object.entries(request.headers || {})) parts.push("-H " + shellQuote(name + ": " + value));
  if (request.bodyPreview) parts.push("--data-raw " + shellQuote(request.bodyPreview));
  return parts.join(" \\\n  ");
}

function grpcurlCommand(event) {
  const request = event.request || {};
  const parts = ["grpcurl"];
  for (const [name, value] of Object.entries(request.metadata || {})) parts.push("-H " + shellQuote(name + ": " + value));
  if (request.bodyPreview) parts.push("-d " + shellQuote(request.bodyPreview));
  parts.push(request.grpcAuthority || request.host || "<host:port>");
  parts.push((request.grpcService || "") + "/" + (request.grpcMethod || lastPathSegment(requestPath(event))));
  return parts.join(" \\\n  ");
}

// A `mocks:` entry for a YAML test that answers this request the way it was
// answered now — the fastest way from "this call misbehaved" to a test that stages it.
function mockYaml(event) {
  const target = event.protocol === "grpc"
    ? "*/" + (event.request && event.request.grpcMethod ? event.request.grpcMethod : lastPathSegment(requestPath(event)))
    : chipPathForEvent(event);
  const lines = ["mocks:", "  - method: " + JSON.stringify(target)];
  const status = networkStatus(event);
  const body = event.response && event.response.bodyPreview;
  if (event.protocol === "grpc" && status.severity !== "ok" && status.severity !== "pending") {
    lines.push("    error: " + grpcCodeName(event.response.grpcStatusCode).toLowerCase());
  } else if (body) {
    let compact = body;
    try { compact = JSON.stringify(JSON.parse(body)); } catch (_) { compact = JSON.stringify(body); }
    lines.push("    body: " + compact);
  } else {
    lines.push("    body: {}");
  }
  return lines.join("\n");
}

// ---- Filters: live text + include/exclude chips ----

// "field:text" scopes a term to one field instead of the whole haystack.
// Only fields from the allowed list count; anything else (say, an URL's
// "https:") stays a plain substring term.
function parseFieldTerm(text, allowedFields) {
  const colon = text.indexOf(":");
  if (colon > 0 && allowedFields) {
    const field = text.slice(0, colon).trim().toLowerCase();
    const term = text.slice(colon + 1).trim();
    if (term && allowedFields.indexOf(field) >= 0) return { field, term };
  }
  return { field: null, term: text };
}

function termMatches(term, field, hay, fields) {
  const needle = String(term).toLowerCase();
  if (field) return !!fields && (fields[field] || "").indexOf(needle) >= 0;
  return hay.indexOf(needle) >= 0;
}

// Exclude chips win over include chips; include chips are OR'd ("show only
// these"); the live input text is an extra substring filter on top.
function matchesFilters(hay, chips, query, fields, queryField) {
  for (const chip of chips) {
    if (chip.kind === "exclude" && termMatches(chip.term, chip.field, hay, fields)) return false;
  }
  const includes = chips.filter((chip) => chip.kind === "include");
  if (includes.length && !includes.some((chip) => termMatches(chip.term, chip.field, hay, fields))) return false;
  return !query || termMatches(query, queryField, hay, fields);
}

// Adding a chip replaces any chip with the same field+term (either kind),
// so an exclude flips an identical include instead of stacking next to it.
function chipKey(field, term) {
  return (field || "") + ":" + String(term).toLowerCase();
}

function withChip(chips, kind, term, field) {
  const trimmed = String(term).trim();
  if (!trimmed) return chips;
  const key = chipKey(field, trimmed);
  const next = chips.filter((chip) => chipKey(chip.field, chip.term) !== key);
  next.push(field ? { kind, term: trimmed, field } : { kind, term: trimmed });
  return next;
}

// ---- Logs ----

const LOG_LEVELS = ["Debug", "Info", "Default", "Error", "Fault"];

// Severity comes from the level the log carries — never from words in the
// message: "error:0" in an Info line is not an error.
function logLevel(entry) {
  const level = String(entry.level || "").toLowerCase();
  for (const known of LOG_LEVELS) if (known.toLowerCase() === level) return known;
  return "Default";
}

function isLogError(entry) {
  const level = logLevel(entry);
  return level === "Error" || level === "Fault";
}

function logFields(entry) {
  return {
    message: String(entry.message || "").toLowerCase(),
    subsystem: String(entry.subsystem || "").toLowerCase(),
    category: String(entry.category || "").toLowerCase(),
    process: String(entry.process || "").toLowerCase(),
    level: logLevel(entry).toLowerCase()
  };
}

function logLine(entry) {
  const head = [formatClock(entry.timestamp, true), logLevel(entry), entry.subsystem].filter(Boolean).join(" ");
  return head + ": " + (entry.message || "");
}

// ---- State ----

// Nested models that are themselves tracked carry this marker in their
// snapshot object; the viewer folds their standalone history into the
// parent's diff and never renders the key itself.
const MODEL_ID_KEY = "$modelId";

function diffStateValues(prev, next, path, out) {
  if (JSON.stringify(prev) === JSON.stringify(next)) return out;
  const isPlainObject = (value) => value && typeof value === "object" && !Array.isArray(value);
  if (isPlainObject(prev) && isPlainObject(next)) {
    const keys = Object.keys(prev).concat(Object.keys(next).filter((key) => !(key in prev)));
    for (const key of keys) {
      if (key === MODEL_ID_KEY) continue;
      diffStateValues(prev[key], next[key], path ? path + "." + key : key, out);
    }
    return out;
  }
  out.push({ path, before: prev, after: next });
  return out;
}

function collectEmbedded(value, ownerId, out) {
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) { for (const item of value) collectEmbedded(item, ownerId, out); return; }
  const marker = value[MODEL_ID_KEY];
  if (typeof marker === "string" && marker !== ownerId) out[marker] = ownerId;
  for (const key of Object.keys(value)) if (key !== MODEL_ID_KEY) collectEmbedded(value[key], ownerId, out);
}

// childId → parentId for models embedded (expanded) inside another live
// tracked model's snapshot, from { modelId: latestEvent }. A child resurfaces
// on its own once its parent deallocates.
function embeddedModelIds(latestByModel) {
  const embedded = {};
  for (const id of Object.keys(latestByModel)) {
    const event = latestByModel[id];
    if (event.deallocated) continue;
    collectEmbedded(event.snapshot, id, embedded);
  }
  return embedded;
}

function stateValueText(value) {
  return value === undefined ? "—" : JSON.stringify(value);
}

// ---- Tests ----

const VERDICT_WORDS = {
  satisfied: { bug: "Bug not reproduced", feature: "Confirmed", none: "Claim holds" },
  unsatisfied: { bug: "Bug reproduced", feature: "Not confirmed", none: "Claim does not hold" },
  inconclusive: { bug: "Inconclusive", feature: "Inconclusive", none: "Inconclusive" },
  infra: { bug: "Infra — cannot be trusted", feature: "Infra — cannot be trusted", none: "Infra — cannot be trusted" }
};
const STATUS_WORDS = { running: "Running", passed: "Passed", failed: "Failed", interrupted: "Interrupted", stopped: "Stopped" };

// What a run means, in words: the verdict for kind-aware tests, the bare status otherwise.
function outcomeOf(session) {
  if (session.verdict && VERDICT_WORDS[session.verdict]) {
    const words = VERDICT_WORDS[session.verdict];
    return { tone: session.verdict, text: words[session.kind] || words.none };
  }
  return { tone: session.status, text: STATUS_WORDS[session.status] || String(session.status || "") };
}

// "✓ 2/5 Wait for label …" → { mark: "passed", index: 2, total: 5, text: "Wait for label …" }
function parseStepText(text) {
  const match = /^([✓✗◼●])\s*(\d+)\/(\d+)\s+(.*)$/.exec(String(text || ""));
  if (!match) return { mark: "note", text: String(text || "") };
  const marks = { "✓": "passed", "✗": "failed", "◼": "stopped", "●": "running" };
  return { mark: marks[match[1]], index: Number(match[2]), total: Number(match[3]), text: match[4] };
}

// Split a step's text into its short heading and the detail after " — ".
function splitStep(text) {
  const t = String(text || "").trim();
  const dash = t.indexOf(" — ");
  if (dash < 0) return { head: t, tail: "" };
  return { head: t.slice(0, dash).trim(), tail: t.slice(dash + 3).trim() };
}

// Video offset of an entry. The raw offset is the wall-clock span since the
// recorder started (at − recordingStartedAt, falling back to startedAt), but
// simctl's footage runs shorter than wall-clock — recorder startup/stop
// latency plus frame-rate drift under load — so a fixed anchor drifts ahead
// of the video and late steps can land past its end. When the real video
// length is known, scale the wall-clock span onto it; a no-op when the
// clocks agree.
function entryOffsetSeconds(session, entry) {
  const base = Date.parse(session.recordingStartedAt || session.startedAt);
  const at = Date.parse(entry.at);
  if (!isFinite(base) || !isFinite(at)) return 0;
  const raw = Math.max(0, (at - base) / 1000);
  const duration = session.videoDurationSeconds;
  const end = Date.parse(session.endedAt || "");
  if (isFinite(duration) && duration > 0 && isFinite(end)) {
    const span = (end - base) / 1000;
    if (span > 0) return Math.min(duration, (raw / span) * duration);
  }
  return raw;
}

function sessionDurationSeconds(session) {
  const duration = session.videoDurationSeconds;
  if (isFinite(duration) && duration > 0) return duration;
  const base = Date.parse(session.recordingStartedAt || session.startedAt);
  const end = Date.parse(session.endedAt || "");
  return isFinite(base) && isFinite(end) ? Math.max(0, (end - base) / 1000) : 0;
}

// The newest finished session of each test file.
function lastRunByFile(sessions) {
  const runs = {};
  for (const session of sessions) {
    if (!session.file || session.status === "running") continue;
    const known = runs[session.file];
    if (!known || Date.parse(session.startedAt) > Date.parse(known.startedAt)) runs[session.file] = session;
  }
  return runs;
}

// ---- Accessibility ----

function axHasFrame(node) {
  const frame = node.frame;
  return !!(frame && frame.width > 0 && frame.height > 0);
}

// An element with nothing to say: no identifier, label, value or title — the
// anonymous containers that make AX trees deep without making them informative.
function axIsAnonymous(node) {
  return !node.accessibilityIdentifier && !(node.label && node.label.trim()) && !node.value && !node.title;
}

function axRoleName(node) {
  const role = String(node.role || node.type || "Element");
  return role.indexOf("AX") === 0 ? role.slice(2) : role;
}

function axTitle(node) {
  return node.accessibilityIdentifier || (node.label && node.label.trim()) || node.title || node.value || axRoleName(node);
}

// Test selectors in the order the YAML runner prefers them.
function axSelector(node) {
  if (node.accessibilityIdentifier) return { key: "id", value: node.accessibilityIdentifier };
  if (node.label && node.label.trim()) return { key: "label", value: node.label.trim() };
  return null;
}

function axYamlStep(node, action) {
  const selector = axSelector(node);
  const verb = action || "tap";
  if (!selector) {
    const frame = node.frame || {};
    return "- " + verb + ": { x: " + Math.round(frame.x + frame.width / 2) + ", y: " + Math.round(frame.y + frame.height / 2) + " }";
  }
  return "- " + verb + ": { " + selector.key + ": " + JSON.stringify(selector.value) + " }";
}

function axCliCommand(node) {
  const selector = axSelector(node);
  if (!selector) {
    const frame = node.frame || {};
    return "simtool input tap --x " + Math.round(frame.x + frame.width / 2) + " --y " + Math.round(frame.y + frame.height / 2);
  }
  return "simtool input tap --" + selector.key + " " + shellQuote(selector.value);
}

// Screen reference = the largest-area ROOT frame (the AXApplication, in points).
// Only roots are considered: some deep container groups report their frame in
// device pixels (e.g. 1206x2622 = 3x), which would otherwise hijack the reference.
function axScreenFrame(tree) {
  let best = null, bestArea = 0;
  for (const root of (tree && tree.roots) || []) {
    const frame = root.frame;
    if (!frame || !frame.width || !frame.height) continue;
    const area = frame.width * frame.height;
    if (area > bestArea) { bestArea = area; best = frame; }
  }
  return best;
}

// ---- Activity: what agents, test runs and viewers did to the device ----

// "3 s ago" — the feed's age, finer than formatAgo's "just now".
function formatSince(milliseconds) {
  if (!isFinite(milliseconds)) return "";
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  if (seconds < 1) return "now";
  if (seconds < 60) return seconds + " s ago";
  const minutes = Math.floor(seconds / 60);
  return minutes < 60 ? minutes + " min ago" : Math.floor(minutes / 60) + " h ago";
}

const ACTOR_NAMES = { agent: "Agent", test: "Test", viewer: "Viewer" };

// How long an agent counts as driving after its last action: long enough to
// cover it reading the screen between two taps.
const AGENT_DRIVING_MS = 30000;

// Who drives the device now: the test run the server reports, or an agent that
// acted within AGENT_DRIVING_MS, or nobody (null). `key` names one stretch of
// driving, so a person who took over is asked again only when a new one starts.
function deviceDriver(entries, run, now) {
  if (run && run.active) {
    let step = run.totalSteps ? { index: Math.min(run.completedSteps + 1, run.totalSteps), total: run.totalSteps } : null;
    for (let i = entries.length - 1; i >= 0 && !step; i--) {
      const parsed = entries[i].kind === "step" ? parseStepText(entries[i].title) : null;
      if (parsed && parsed.index) step = { index: Math.min(parsed.index + 1, parsed.total), total: parsed.total };
    }
    return { actor: "test", key: "test:" + (run.sessionId || run.file || run.name || ""), title: run.name || run.file || "a test", step };
  }
  let newest = null, first = null;
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry.actor !== "agent") continue;
    const end = Date.parse(entry.endedAt || entry.at);
    if (!newest) {
      if (entry.status !== "running" && !(now - end < AGENT_DRIVING_MS)) return null;
      newest = entry;
    } else if (Date.parse(first.at) - end >= AGENT_DRIVING_MS) {
      break;
    }
    first = entry;
  }
  return newest ? { actor: "agent", key: "agent:" + first.id, title: newest.title, lastAt: Date.parse(newest.endedAt || newest.at), entry: newest } : null;
}

// A gesture's ends as fractions of the screen, from the points it was played
// in; the server's screen size wins, the page's own (AX) size is the fallback.
function gestureRatios(gesture, screenPoints) {
  const screen = gesture && (gesture.screen || screenPoints);
  if (!screen || !screen.width || !screen.height) return null;
  const ratio = (point) => ({ x: Math.min(1, Math.max(0, point.x / screen.width)), y: Math.min(1, Math.max(0, point.y / screen.height)) });
  const from = ratio(gesture.from), to = ratio(gesture.to);
  const moved = Math.hypot(gesture.to.x - gesture.from.x, gesture.to.y - gesture.from.y) >= 1;
  return { from, to, moved };
}

// The CLI command that does what an entry did, for touches with a known path.
function activityCommand(entry) {
  const gesture = entry && entry.gesture;
  if (!gesture) return "";
  const round = (value) => Math.round(value);
  const at = "--x " + round(gesture.from.x) + " --y " + round(gesture.from.y);
  const path = "--start-x " + round(gesture.from.x) + " --start-y " + round(gesture.from.y) + " --end-x " + round(gesture.to.x) + " --end-y " + round(gesture.to.y);
  switch (entry.kind) {
    case "tap": return "simtool input tap " + at;
    case "long-press": return "simtool input long-press " + at + " --duration " + Math.round(gesture.press * 100) / 100;
    case "drag": return "simtool input drag " + path;
    case "swipe": case "scroll": case "fling": return "simtool input swipe " + path + (entry.kind === "fling" ? " --hold 0" : "");
    default: return "";
  }
}

// ---- Session review: the part of a run one step covers ----

// Milliseconds since the epoch from the times evidence carries: epoch seconds
// (state), ISO 8601 (network, steps) and OSLog's "2026-10-20 18:40:11.226211-0300"
// (logs), which not every browser parses. NaN when unreadable.
function parseInstant(value) {
  if (typeof value === "number") return value * 1000;
  if (value == null || value === "") return NaN;
  const text = String(value);
  const oslog = /^(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d:\d\d)(?:\.(\d+))?([+-]\d\d):?(\d\d)$/.exec(text);
  if (oslog) return Date.parse(oslog[1] + "T" + oslog[2] + oslog[4] + ":" + oslog[5]) + (oslog[3] ? Number("0." + oslog[3]) * 1000 : 0);
  return Date.parse(text);
}

// What each step of a session covers: from the moment it began acting (its
// first input, or its end for a step that only waited) to the moment the next
// step did; the last one to the end of the run. A tap's window therefore holds
// the requests and lines it caused while the next step waited for them.
// `index` is the step's position in session.entries.
function stepWindows(session) {
  const end = parseInstant(session.endedAt);
  const steps = (session.entries || []).map((entry, index) => ({ entry, index })).filter(({ entry }) => entry.kind === "step");
  return steps.map(({ entry, index }, position) => ({
    index,
    text: entry.text || "",
    from: parseInstant(entry.at),
    to: position + 1 < steps.length ? parseInstant(steps[position + 1].entry.at) : (isFinite(end) ? end : Infinity)
  }));
}

// The window the playhead is in — the step at `entryIndex`, or what came
// before the first step — or the whole run.
function reviewWindow(session, entryIndex, scope) {
  const start = parseInstant(session.startedAt), end = parseInstant(session.endedAt);
  const run = { from: start, to: isFinite(end) ? end : Infinity, step: null, text: "" };
  if (scope === "run") return run;
  const windows = stepWindows(session);
  const position = windows.findIndex((window) => window.index === entryIndex);
  if (position < 0) return { from: start, to: windows.length ? windows[0].from : run.to, step: 0, text: "" };
  return { from: windows[position].from, to: windows[position].to, step: position + 1, text: windows[position].text };
}

// When an item of evidence happened: a request when it started (the logger
// stamps it when it finishes), a log line and a state change when they were written.
function evidenceInstant(kind, item) {
  if (kind === "network") return parseInstant(item.timestamp) - (item.durationMilliseconds || 0);
  return parseInstant(item.timestamp);
}

function inWindow(kind, item, window) {
  const at = evidenceInstant(kind, item);
  return at >= window.from && at < window.to;
}

// The tracked models as they stood at the end of a window, and what changed
// inside it — the State tab's latest/changes/lastChange for a moment of a run.
function foldStateEvents(events, window) {
  const latest = {}, changes = [], lastChange = {};
  const ordered = events.slice().sort((a, b) => (a.timestamp - b.timestamp) || ((a.cursor || 0) - (b.cursor || 0)));
  for (const event of ordered) {
    const at = event.timestamp * 1000;
    if (at >= window.to) break;
    const previous = latest[event.modelId];
    const diffs = diffStateValues(previous ? previous.snapshot : undefined, event.snapshot, "", []);
    if (at >= window.from) {
      if (previous || event.deallocated) changes.push({ event, diffs });
      lastChange[event.modelId] = event.deallocated ? [] : diffs.map((diff) => diff.path);
    }
    latest[event.modelId] = event.deallocated && previous ? { ...event, snapshot: previous.snapshot } : event;
  }
  return { latest, changes, lastChange };
}
