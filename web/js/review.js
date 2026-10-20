// Session review: while a recording plays, Network, Logs and State show that
// run — its own evidence files, or this server's memory when it kept none —
// cut to the step the playhead is in, or to the whole run. The window follows
// the playhead; each step of the timeline says what it caused and opens it.

const REVIEW_FILES = { network: "network.jsonl", logs: "logs.jsonl", state: "state.jsonl" };
const review = {
  scope: stored("review.scope", "step"),   // step | run
  evidence: new Map(),                     // session id → { network, logs, state, loading, error }
  window: null                             // the span the lists show: { from, to, step, text }
};

function reviewActive() {
  return app.dataset.mode === "replay" && !!tests.replay;
}

// A session's evidence, fetched once. Kinds it kept no file for stay null and
// read from this server's memory instead.
function loadEvidence(session) {
  const known = review.evidence.get(session.id);
  if (known) return known.ready;
  const record = { network: null, logs: null, state: null, loading: true, error: "" };
  record.ready = Promise.all(Object.entries(REVIEW_FILES).map(async ([kind, name]) => {
    if (!(session.evidence || []).includes(name)) return;
    try {
      const text = await (await api("/api/v1/tests/" + encodeURIComponent(session.id) + "/evidence/" + encodeURIComponent(name))).text();
      record[kind] = text.split("\n").filter(Boolean).map((line) => { try { return JSON.parse(line); } catch (_) { return null; } }).filter(Boolean);
    } catch (error) {
      record.error = error.message;
    }
  })).then(() => {
    record.loading = false;
    if (reviewActive() && tests.replay.id === session.id) refreshReview();
    if (tests.selectedSession === session.id && inspector.tab === "tests") renderTestsDetail();
  });
  review.evidence.set(session.id, record);
  return record.ready;
}

function reviewRecord(session) {
  return session ? review.evidence.get(session.id) || null : null;
}

// The whole run's items of one kind: its file, else what this server still holds.
function reviewSource(kind, live) {
  const record = reviewRecord(tests.replay);
  return record && record[kind] ? record[kind] : live;
}

function fromEvidenceFile(kind) {
  const record = reviewRecord(tests.replay);
  return !!(record && record[kind]);
}

// What a list shows: the live items, or the reviewed run's items in the window.
function reviewRows(kind, live) {
  if (!reviewActive() || !review.window) return live;
  return reviewSource(kind, live).filter((item) => inWindow(kind, item, review.window));
}

// The State tab's models at the end of the window and its changes inside it.
// Only from the run's state.jsonl: the live tab keeps folded models, not the
// events a past moment could be rebuilt from.
function reviewStateView(live) {
  if (!reviewActive() || !review.window) return live;
  const record = reviewRecord(tests.replay);
  return foldStateEvents(record && record.state ? record.state : [], review.window);
}

// ---- The bar over Network, Logs and State while a run is reviewed ----

const reviewBars = ["network", "logs", "state"].map((tab) => {
  const scope = segmented("Review span", [["step", "This step"], ["run", "Whole run"]], () => review.scope, (value) => {
    review.scope = value;
    store("review.scope", value);
    refreshReview();
  });
  scope.classList.add("keep");
  const text = el("span", { class: "rb-text" });
  const bar = el("div", { class: "review-bar", role: "status", hidden: true }, el("span", { html: icon("film") }), text, el("span", { class: "ptool-spacer" }), scope);
  $("panel-" + tab).prepend(bar);
  return { tab, bar, text, scope };
});

function reviewBarHTML(kind) {
  const window = review.window;
  if (!window) return "";
  const what = window.step == null ? "<b>Whole run</b>" : window.step === 0 ? "<b>Before the first step</b>" : "<b>Step " + window.step + "</b> " + escapeHTML(splitStep(parseStepText(window.text).text).head);
  const span = '<span class="mono">' + escapeHTML(formatClock(new Date(window.from), true)) + " → " + (isFinite(window.to) ? escapeHTML(formatClock(new Date(window.to), true)) : "end") + "</span>";
  const record = reviewRecord(tests.replay);
  const source = record && record.loading ? "loading the run's evidence…" : fromEvidenceFile(kind) ? "from the run's " + REVIEW_FILES[kind]
    : kind === "state" ? "the run kept no state.jsonl" : "from this server's memory — the run kept no " + REVIEW_FILES[kind];
  return what + span + '<span class="rb-source">' + escapeHTML(source) + "</span>";
}

function renderReviewBars() {
  for (const { tab, bar, text, scope } of reviewBars) {
    bar.hidden = !reviewActive();
    if (bar.hidden) continue;
    text.innerHTML = reviewBarHTML(tab);
    scope.sync();
  }
}

// The window moved — a new step under the playhead, the scope switched, the evidence arrived.
function refreshReview() {
  review.window = reviewActive() ? reviewWindow(tests.replay, replayCurrentIndex, review.scope) : null;
  renderReviewBars();
  networkList.invalidate();
  logsList.invalidate();
  renderNetwork();
  renderLogs();
  renderState();
}

function startReview(session) {
  loadEvidence(session);
  refreshReview();
}

function stopReview() {
  review.window = null;
  refreshReview();
}

// The note a list shows when the window holds nothing of its kind.
function reviewEmpty(kind) {
  const record = reviewRecord(tests.replay);
  if (record && record.loading) return el("div", { class: "empty", html: "<b>Loading the run's evidence</b>" });
  const noun = { network: "requests", logs: "log lines", state: "state changes" }[kind];
  const where = review.window && review.window.step != null ? "in this step" : "in this run";
  const missing = kind === "state" ? "The run kept no state.jsonl." : "The run kept no " + REVIEW_FILES[kind] + ", and this server holds none from then.";
  const node = el("div", { class: "empty", html: "<b>No " + noun + " " + where + "</b>" + (fromEvidenceFile(kind) ? "The run's evidence holds none between these times." : missing) });
  if (review.scope === "step") node.append(el("button", { class: "btn btn-sm", type: "button", text: "Show the whole run", onclick: () => { review.scope = "run"; store("review.scope", "run"); refreshReview(); } }));
  return node;
}

// ---- What each step of a timeline caused ----

// Counts of the requests, log lines and state changes in each step's window,
// once the session's evidence is in. Kinds the run kept no file for are left out.
function stepEvidenceCounts(session) {
  const record = reviewRecord(session);
  if (!record || record.loading) return null;
  const counts = new Map();
  for (const window of stepWindows(session)) {
    counts.set(window.index, {
      network: record.network ? record.network.filter((item) => inWindow("network", item, window)).length : null,
      logs: record.logs ? record.logs.filter((item) => inWindow("logs", item, window)).length : null,
      state: record.state ? record.state.filter((item) => inWindow("state", item, window)).length : null
    });
  }
  return counts;
}

// The row under a step that opens what it caused, in the tab that shows it.
function stepEvidenceHTML(counts, offset) {
  if (!counts) return "";
  const links = [["network", "request", "requests"], ["logs", "log line", "log lines"], ["state", "state update", "state updates"]]
    .filter(([kind]) => counts[kind] != null)
    .map(([kind, one, many]) => '<button class="ev-link" type="button" data-act="step-evidence" data-tab="' + kind + '" data-offset="' + offset + '"' + (counts[kind] ? "" : " disabled") + ">" + plural(counts[kind], one, many) + "</button>");
  return links.length ? '<li class="step-ev">' + links.join("") + "</li>" : "";
}

// Seek to the step and hold there, cut the lists to it, and show the one asked for.
function openStepEvidence(tab, offset) {
  review.scope = "step";
  store("review.scope", "step");
  seekToStep(offset, { hold: true });
  openTab(tab);
  refreshReview();
}
