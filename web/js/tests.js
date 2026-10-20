// Tests: the YAML tests of the project, their runs, and recorded sessions.
// A recording plays in the screen's place — Replay is a mode of the whole
// viewer, so looking at Network or Logs does not stop it.

const tests = {
  view: stored("tests.view", "tests"),      // tests | history
  definitions: [],
  sessions: [],
  run: null,                                // /api/v1/tests/run
  selectedFile: stored("tests.selected", null),
  selectedSession: null,
  watchedSession: null,                     // a running session whose end switches to its recording
  recordVideo: stored("tests.video", true),
  replay: null,                             // the session playing
  sessionsPath: ""
};

const testsFilter = createFilter("tests", { placeholder: "Filter name, file, reference, verdict", onChange: () => renderTests() });
const testsModes = segmented("Tests view", [["tests", "Tests"], ["history", "History"]], () => tests.view, (view) => { tests.view = view; store("tests.view", view); renderTests(); });
testsModes.classList.add("keep");
const testsWhere = el("span", { class: "muted small mono ptool-note", text: ".simtool/tests" });
const testsView = buildListPanel("tests", { listLabel: "Tests", toolbar: [testsModes, testsFilter.field, el("span", { class: "ptool-spacer" }), testsWhere] });

// The outcome in words with its mark; `markOnly` for the narrow first column, which names it in a tooltip.
function sessionOutcomeHTML(session, markOnly) {
  const outcome = outcomeOf(session);
  const glyph = { satisfied: "check", passed: "check", unsatisfied: "x", failed: "x", inconclusive: "warn", infra: "offline", interrupted: "stop", stopped: "stop" }[outcome.tone] || "more";
  if (session.status === "running") return '<span class="verdict v-running"><span class="spinner" aria-hidden="true"></span>' + (markOnly ? "" : "Running") + "</span>";
  return '<span class="verdict v-' + escapeHTML(outcome.tone) + '"' + (markOnly ? ' title="' + escapeHTML(outcome.text) + '"' : "") + ">" + icon(glyph) + (markOnly ? "" : escapeHTML(outcome.text)) + "</span>";
}

// ---- Tests view ----

const definitionList = createList(testsView.list, {
  key: (test) => test.file,
  // runActive() too: every row's Run button turns off while any test runs.
  version: (test) => JSON.stringify([test.name, test.stepCount, test.parseError, test.reference, test.kind, runActive(), runStateOf(test), lastRunOf(test) && lastRunOf(test).id, lastRunOf(test) && lastRunOf(test).verdict]),
  rowClass: () => "test-grid",
  render: renderDefinitionRow,
  empty: () => el("div", { class: "empty", html: tests.definitions.length ? "<b>No test matches</b>Clear the filter to see all " + formatCount(tests.definitions.length) + "." :
    "<b>No tests yet</b>Add a YAML test to <code>.simtool/tests/</code> in the project this server runs for — <code>simtool test run --help</code> shows the format. Tests appear here with a Run button." }),
  onSelect: (file) => { tests.selectedFile = file; store("tests.selected", file); renderTestsDetail(); },
  // Enter opens the test's actions; running it takes ⌘↩ or the Run button, so browsing never starts a run.
  onActivate: () => { const action = testsView.detail.querySelector('[data-act="run"], [data-act="stop"]'); if (action) action.focus(); },
  onMenu: (file, test, x, y, row) => openMenu(x, y, [
    { icon: "play", label: "Run", kbd: "⌘↩", disabled: !!test.parseError || runActive(), run: () => runTest(file) },
    { icon: "copy", label: "Copy the run command", run: () => copyText("simtool test run .simtool/tests/" + file, "Command copied") }
  ], row)
});

function runActive() { return !!(tests.run && tests.run.active); }
function runStateOf(test) { return tests.run && tests.run.file === test.file ? [tests.run.active, tests.run.completedSteps, tests.run.status].join(":") : ""; }
function lastRunOf(test) { return tests.lastRuns ? tests.lastRuns[test.file] : null; }

function renderDefinitionRow(test, row) {
  const running = tests.run && tests.run.active && tests.run.file === test.file;
  const last = lastRunOf(test);
  const lead = test.parseError ? '<span class="st st-err" title="Cannot run">' + icon("warn") + "</span>"
    : running ? '<span class="spinner" aria-label="Running"></span>'
    : last ? sessionOutcomeHTML(last, true)
    : '<span class="dot dot-idle dot-lead" title="Never run"></span>';
  const action = test.parseError ? "" : running
    ? (tests.run.stoppable === false ? '<span class="muted small">Running…</span>' : '<button class="btn btn-sm btn-danger" type="button" data-act="stop">' + icon("stop", "ic-sm") + "Stop</button>")
    : '<button class="btn btn-sm" type="button" data-act="run"' + (runActive() ? " disabled" : "") + ">" + icon("play", "ic-sm") + "Run</button>";
  row.innerHTML =
    '<span class="cell">' + lead + "</span>" +
    '<span class="cell t-name"><b translate="no">' + escapeHTML(test.name || test.file) + "</b>" +
      (test.parseError ? '<span class="perr">Cannot run · ' + escapeHTML(test.parseError) + "</span>" : '<span translate="no">' + escapeHTML(test.file) + (test.reference ? " · " + escapeHTML(test.reference) : "") + "</span>") + "</span>" +
    '<span class="cell kind c-kind">' + escapeHTML(test.kind || "—") + "</span>" +
    '<span class="cell num c-steps">' + (test.parseError ? "—" : formatCount(test.stepCount)) + "</span>" +
    '<span class="cell c-last">' + (running ? '<span class="verdict v-running">Step ' + Math.min(tests.run.completedSteps + 1, tests.run.totalSteps || test.stepCount) + " of " + (tests.run.totalSteps || test.stepCount) + "</span>"
      : test.parseError ? '<span class="muted">Cannot run</span>'
      : last ? sessionOutcomeHTML(last) + ' <span class="muted small" title="' + escapeHTML(new Date(last.startedAt).toString()) + '">· ' + escapeHTML(formatAgo(last.startedAt)) + "</span>"
      : '<span class="muted">Never run</span>') + "</span>" +
    '<span class="cell">' + action + "</span>";
}

testsView.list.addEventListener("click", (event) => {
  const action = event.target.closest("[data-act]");
  if (!action) return;
  const row = action.closest(".row");
  if (action.dataset.act === "run") runTest(row.dataset.key);
  if (action.dataset.act === "stop") stopTest();
});

// ---- History view ----

function sessionMenu(session) {
  return [
    { icon: "film", label: "Play the recording", disabled: session.status === "running" || !!session.videoError, run: () => enterReplay(session) },
    { icon: "copy", label: "Copy session id", run: () => copyText(session.id, "Session id copied") },
    { icon: "copy", label: "Copy report path", disabled: !tests.sessionsPath, run: () => copyText(tests.sessionsPath + "/" + session.id + "/report.md", "Report path copied") },
    "-",
    { icon: "trash", label: "Delete session…", tone: "danger", disabled: session.status === "running", run: () => deleteSession(session) }
  ];
}

async function deleteSession(session) {
  if (!(await confirmDestructive("Delete this run?", "“" + session.title + "” (" + formatDayTime(session.startedAt) + ") and its recording and evidence are deleted from the project's test sessions.", "Delete run"))) return;
  try {
    await api("/api/v1/tests/" + encodeURIComponent(session.id), { method: "DELETE" });
    if (tests.replay && tests.replay.id === session.id) exitReplay();
    tests.sessions = tests.sessions.filter((candidate) => candidate.id !== session.id);
    testsLastSessions = "";
    renderTests();
    toast("Run deleted", { icon: "trash" });
  } catch (error) {
    fail("Delete failed", error);
  }
}

// ---- Rendering ----

function testsVisibleDefinitions() {
  const query = testsFilter.text, chips = testsFilter.chips;
  return tests.definitions.filter((test) => {
    const last = lastRunOf(test);
    const hay = [test.name, test.file, test.reference, test.kind, test.description, last ? outcomeOf(last).text : "never run"].filter(Boolean).join(" ").toLowerCase();
    return matchesFilters(hay, chips, query);
  });
}

function testsVisibleSessions() {
  const query = testsFilter.text, chips = testsFilter.chips;
  return tests.sessions.filter((session) => {
    const hay = [session.title, session.file, session.reference, session.kind, session.status, outcomeOf(session).text, session.deviceName].filter(Boolean).join(" ").toLowerCase();
    return matchesFilters(hay, chips, query);
  });
}

const sessionContainer = el("div", { class: "list", role: "listbox", "aria-label": "Runs", hidden: true });
// The history list renders into its own container next to the tests list.
testsView.listWrap.append(sessionContainer);
const historyList = createList(sessionContainer, {
  key: (session) => session.id,
  version: (session) => [session.status, session.verdict, session.endedAt, session.title, formatAgo(session.startedAt)].join("|"),
  rowClass: () => "hist-grid",
  render: (session, row) => {
    row.innerHTML =
      '<span class="cell">' + sessionOutcomeHTML(session) + "</span>" +
      '<span class="cell t-name"><b translate="no">' + escapeHTML(session.title) + '</b><span translate="no">' + escapeHTML([session.reference, session.file || session.id].filter(Boolean).join(" · ")) + "</span></span>" +
      '<span class="cell kind c-kind">' + escapeHTML(session.kind || "—") + "</span>" +
      '<span class="cell num c-len">' + (session.endedAt ? formatOffset(sessionDurationSeconds(session)) : "—") + "</span>" +
      '<span class="cell num" title="' + escapeHTML(new Date(session.startedAt).toString()) + '">' + escapeHTML(formatAgo(session.startedAt)) + "</span>";
  },
  header: el("div", { class: "thead hist-grid", role: "row", html: '<span class="cell">Outcome</span><span class="cell">Run</span><span class="cell c-kind">Kind</span><span class="cell num c-len">Length</span><span class="cell num">Started</span>' }),
  empty: () => el("div", { class: "empty", html: tests.sessions.length ? "<b>No run matches</b>Clear the filter to see all " + formatCount(tests.sessions.length) + "." :
    "<b>No runs yet</b>Every <code>simtool test run</code> — from here or from a terminal — records its steps, video and evidence as a session you can replay here." }),
  onSelect: (id) => { tests.selectedSession = id; renderTestsDetail(); },
  onActivate: (id) => { const session = tests.sessions.find((candidate) => candidate.id === id); if (session) enterReplay(session); },
  onMenu: (id, session, x, y, row) => openMenu(x, y, sessionMenu(session), row)
});

function renderTests() {
  tests.lastRuns = lastRunByFile(tests.sessions);
  const history = tests.view === "history";
  testsView.list.hidden = history;
  sessionContainer.hidden = !history;
  for (const button of testsModes.children) button.setAttribute("aria-pressed", String((button.textContent === "History") === history));
  if (history) historyList.update(testsVisibleSessions());
  else definitionList.update(testsVisibleDefinitions());
  if (!history && tests.selectedFile && definitionList.selectedKey !== tests.selectedFile && tests.definitions.some((test) => test.file === tests.selectedFile)) definitionList.select(tests.selectedFile, { quiet: true, scroll: false });
  if (history && tests.selectedSession && historyList.selectedKey !== tests.selectedSession && tests.sessions.some((session) => session.id === tests.selectedSession)) historyList.select(tests.selectedSession, { quiet: true, scroll: false });
  const failing = tests.definitions.filter((test) => { const last = lastRunOf(test); return last && ["unsatisfied", "failed", "infra"].includes(last.verdict || last.status); }).length;
  setCount("tests", tests.definitions.length, failing);
  const running = tests.run && tests.run.active;
  testsView.guide.innerHTML = guideHTML([
    history ? plural(tests.sessions.length, "run", "runs") : plural(tests.definitions.length, "test", "tests"),
    running ? '<span class="verdict v-running"><span class="spinner" aria-hidden="true"></span>Running ' + escapeHTML(tests.run.name || tests.run.file || "") + " · step " + Math.min(tests.run.completedSteps + 1, tests.run.totalSteps) + " of " + tests.run.totalSteps + "</span>" : "",
    failing && !history ? '<span class="st-err">' + plural(failing, "test failed", "tests failed") + " on the last run</span>" : ""
  ], "");
  renderTestsDetail();
}

function stepRowsForDefinition(test) {
  const live = tests.run && tests.run.file === test.file ? tests.run : null;
  const last = lastRunOf(test);
  const fromSession = {};
  if (!live || !live.active) {
    // The last finished run of this test: which steps passed, when, and where it stopped.
    const session = live && live.sessionId ? tests.sessions.find((candidate) => candidate.id === live.sessionId) || last : last;
    if (session) for (const entry of session.entries || []) {
      if (entry.kind !== "step") continue;
      const step = parseStepText(entry.text);
      if (step.index) fromSession[step.index - 1] = { mark: step.mark, at: formatOffset(entryOffsetSeconds(session, entry)), detail: splitStep(step.text).tail };
    }
  }
  return (test.steps || []).map((text, index) => {
    let mark = "pending", at = "", detail = "";
    if (live && live.active) {
      if (index < live.completedSteps) mark = "passed";
      else if (index === live.completedSteps) mark = "running";
    } else if (fromSession[index]) {
      ({ mark, at, detail } = fromSession[index]);
    } else if (live && index === live.completedSteps && live.status === "failed") {
      mark = "failed"; detail = live.error || "";
    }
    return { text, mark, at, detail };
  });
}

function stepHTML(step, seekable, current, offset) {
  const glyph = { passed: '<span class="st-ok">' + icon("check") + "</span>", failed: '<span class="st-err">' + icon("x") + "</span>",
    running: '<span class="spinner" aria-label="Running"></span>', stopped: '<span class="muted">' + icon("stop") + "</span>",
    note: '<span class="muted">' + icon("chev-r") + "</span>", pending: '<span class="dot dot-idle"></span>' }[step.mark];
  return '<li class="step' + (step.mark === "pending" ? " pending" : "") + (seekable ? " seekable" : "") + (current ? " current" : "") + '"' + (offset != null ? ' data-offset="' + offset + '"' : "") + (seekable ? ' tabindex="0" role="button"' : "") + ">" +
    '<span class="st-ic">' + glyph + '</span><span class="s-t">' + escapeHTML(step.at || "") + '</span><span class="s-text" translate="no">' + escapeHTML(step.text) +
    (step.detail ? '<span class="s-sub">' + escapeHTML(step.detail) + "</span>" : "") + "</span></li>";
}

function renderTestsDetail() {
  if (tests.view === "history") return renderSessionDetail();
  const test = tests.definitions.find((candidate) => candidate.file === tests.selectedFile);
  showDetail(testsView.panel, !!test);
  if (!test) return;
  const node = testsView.detail;
  if (test.parseError) {
    patchPane(node, "test:" + test.file, '<div class="dhead"><span class="dtitle" translate="no">' + escapeHTML(test.file) + '</span></div><div class="dbody"><div class="callout err">' + icon("warn") +
      "<div><b>This test cannot run</b><br>" + escapeHTML(test.parseError) + '</div></div><p class="muted">Fix the YAML in <code>.simtool/tests/' + escapeHTML(test.file) + "</code>; the list picks the change up by itself.</p></div>");
    return;
  }
  const running = tests.run && tests.run.active && tests.run.file === test.file;
  const busy = runActive();
  const last = lastRunOf(test);
  const action = running
    ? (tests.run.stoppable === false ? '<span class="muted small">Running from a terminal</span>' : '<button class="btn btn-sm btn-danger" type="button" data-act="stop">' + icon("stop", "ic-sm") + "Stop</button>")
    : '<button class="btn btn-sm btn-primary" type="button" data-act="run" data-tip="Run the test" data-key="⌘↩"' + (busy ? " disabled" : "") + ">" + icon("play", "ic-sm") + "Run</button>";
  // Each step of a run re-renders this pane; patchPane keeps focus on Stop or Record video.
  patchPane(node, "test:" + test.file,
    '<div class="dhead"><span class="dtitle ui" translate="no">' + escapeHTML(test.name || test.file) + "</span>" +
      '<div class="dactions"><label class="check small muted"><input type="checkbox" data-act="video"' + (tests.recordVideo ? " checked" : "") + (busy ? " disabled" : "") + "> Record video</label>" + action + "</div></div>" +
    '<div class="dmeta"><span class="mono" translate="no">' + escapeHTML(test.file) + "</span>" + (test.kind ? "<span>" + escapeHTML(test.kind) + "</span>" : "") +
      (test.reference ? "<span>" + escapeHTML(test.reference) + "</span>" : "") + (last ? "<span>Last run " + escapeHTML(formatAgo(last.startedAt)) + " · " + sessionOutcomeHTML(last) + "</span>" : "<span>Never run</span>") + "</div>" +
    '<div class="dbody">' + (test.description ? '<p class="muted desc">' + escapeHTML(test.description) + "</p>" : "") +
      (running && tests.run.error ? '<div class="callout err">' + icon("warn") + "<div>" + escapeHTML(tests.run.error) + "</div></div>" : "") +
      '<ol class="steps">' + stepRowsForDefinition(test).map((step) => stepHTML(step, false, step.mark === "running")).join("") + "</ol></div>");
}

function renderSessionDetail() {
  const session = tests.sessions.find((candidate) => candidate.id === tests.selectedSession);
  showDetail(testsView.panel, !!session);
  if (!session) return;
  const node = testsView.detail;
  const criteria = session.criteria || [];
  const mocks = session.mocks || [];
  const claim = session.verdict || criteria.length || mocks.length ? '<div class="claim"><div class="claim-head">' + sessionOutcomeHTML(session) +
      (criteria.length ? '<span class="muted small">' + criteria.filter((criterion) => criterion.status === "met").length + " of " + criteria.length + " criteria met</span>" : "") + "</div>" +
    criteria.map((criterion) => {
      const state = criterion.status === "met" ? "met" : criterion.status === "unmet" ? "unmet" : "unchecked";
      return '<div class="claim-line"><span class="' + (state === "met" ? "st-ok" : state === "unmet" ? "st-err" : "muted") + '">' + icon(state === "met" ? "check" : state === "unmet" ? "x" : "more") + "</span><span><b class=\"mono small\">" +
        escapeHTML(criterion.label) + (criterion.step ? " · step " + criterion.step : "") + "</b> " + escapeHTML(criterion.detail || (state === "met" ? "held" : state === "unmet" ? "did not hold" : "not reached")) + "</span></div>";
    }).join("") +
    mocks.map((mock) => '<div class="claim-line"><span class="' + (mock.strict && !mock.hits ? "st-err" : "muted") + '">' + icon("mock") + '</span><span translate="no">mock ' + escapeHTML(mock.method) + " — " + plural(mock.hits, "call", "calls") + (mock.strict ? ", strict" : "") + "</span></div>").join("") +
    "</div>" : "";
  const seekable = session.status !== "running" && !session.videoError;
  const current = tests.replay && tests.replay.id === session.id ? replayCurrentIndex : -1;
  const entries = (session.entries || []).map((entry, index) => {
    const offset = entryOffsetSeconds(session, entry);
    if (entry.kind === "step") {
      const step = parseStepText(entry.text);
      const parts = splitStep(step.text);
      return stepHTML({ text: parts.head, detail: parts.tail, mark: step.mark, at: formatOffset(offset) }, seekable, index === current, offset.toFixed(2));
    }
    const lines = entry.logs || [];
    if (!lines.length) return "";
    // A failure entry carries the error first and a long screen dump after it.
    const title = lines[0] === "On screen:" ? "Screen at the failure — " + plural(lines.length - 1, "element", "elements") : lines[0];
    return '<li><details class="step-logs"><summary>' + escapeHTML(title) + '</summary><pre class="code" translate="no">' + escapeHTML(lines.slice(lines[0] === "On screen:" ? 1 : 0).join("\n")) + "</pre></details></li>";
  }).join("");
  const evidence = (session.evidence || []).length ? '<div class="sec">Evidence</div><ul class="evidence" translate="no">' +
    (session.evidence || []).map((file) => {
      const path = (tests.sessionsPath ? tests.sessionsPath + "/" : "") + session.id + "/" + file;
      return '<li><span class="mono small">' + escapeHTML(path) + '</span><button class="tb-btn" type="button" data-act="copy-path" data-path="' + escapeHTML(path) + '" aria-label="Copy the path" data-tip="Copy the path">' + icon("copy", "ic-sm") + "</button></li>";
    }).join("") + "</ul>" : "";
  patchPane(node, "session:" + session.id,
    '<div class="dhead"><span class="dtitle ui" translate="no">' + escapeHTML(session.title) + "</span>" +
      '<div class="dactions">' + (seekable ? '<button class="btn btn-sm btn-primary" type="button" data-act="play">' + icon("film", "ic-sm") + (tests.replay && tests.replay.id === session.id ? "Playing" : "Play recording") + "</button>" : "") +
      '<button class="tb-btn" type="button" data-act="more" aria-label="More actions" aria-haspopup="menu">' + icon("more") + "</button></div></div>" +
    '<div class="dmeta">' + (session.kind ? "<span>" + escapeHTML(session.kind) + "</span>" : "") + (session.reference ? "<span>" + escapeHTML(session.reference) + "</span>" : "") +
      "<span>" + escapeHTML(formatDayTime(session.startedAt)) + "</span>" + (session.endedAt ? "<span>" + formatOffset(sessionDurationSeconds(session)) + "</span>" : "") +
      "<span>" + escapeHTML(session.deviceName || "") + "</span>" + (session.videoError ? '<span class="st-warn">no recording: ' + escapeHTML(session.videoError) + "</span>" : "") + "</div>" +
    '<div class="dbody">' + claim + '<div class="sec">Timeline' + (seekable ? " · click a step to see that moment" : "") + '</div><ol class="steps">' + entries + "</ol>" + evidence + "</div>");
}

testsView.detail.addEventListener("click", (event) => {
  const action = event.target.closest("[data-act]");
  if (action) {
    if (action.dataset.act === "run") runTest(tests.selectedFile);
    if (action.dataset.act === "stop") stopTest();
    if (action.dataset.act === "play") { const session = tests.sessions.find((candidate) => candidate.id === tests.selectedSession); if (session) enterReplay(session); }
    if (action.dataset.act === "more") { const session = tests.sessions.find((candidate) => candidate.id === tests.selectedSession); if (session) openMenuAt(action, sessionMenu(session)); }
    if (action.dataset.act === "copy-path") copyText(action.dataset.path, "Path copied");
    return;
  }
  const step = event.target.closest(".step.seekable");
  if (step) seekToStep(Number(step.dataset.offset));
});
testsView.detail.addEventListener("change", (event) => {
  if (event.target.dataset.act === "video") { tests.recordVideo = event.target.checked; store("tests.video", tests.recordVideo); }
});
testsView.detail.addEventListener("keydown", (event) => {
  const step = event.target.closest(".step.seekable");
  if (step && (event.key === "Enter" || event.key === " ")) { event.preventDefault(); seekToStep(Number(step.dataset.offset)); }
});

// ---- Running ----

async function runTest(file) {
  const test = tests.definitions.find((candidate) => candidate.file === file);
  if (!test || test.parseError || runActive()) return;
  try {
    const status = await apiJSON("/api/v1/tests/run", { method: "POST", body: JSON.stringify({ file, video: tests.recordVideo }) });
    tests.run = status;
    tests.watchedSession = status.sessionId || null;
    exitReplay();
    toast("Running “" + (test.name || file) + "”" + (tests.recordVideo ? " — recording" : ""), { icon: "play" });
    renderTests();
    poller.poke("tests");
  } catch (error) {
    fail("Could not start the test", error);
  }
}

async function stopTest() {
  try {
    tests.run = await apiJSON("/api/v1/tests/run/stop", { method: "POST" });
    toast("Stopping the run", { icon: "stop" });
    renderTests();
  } catch (error) {
    fail("Could not stop the test", error);
  }
}

// ---- Replay ----

const video = $("replayVideo");
let replayCurrentIndex = -1;

function enterReplay(session) {
  if (!session || session.status === "running") return;
  if (session.videoError) { toast("This run has no recording: " + session.videoError, { error: true }); return; }
  tests.replay = session;
  app.dataset.mode = "replay";
  $("replayTitle").textContent = session.title + " · " + formatDayTime(session.startedAt);
  renderConnectionLabel();
  $("replayNote").hidden = true;
  video.src = "/api/v1/tests/" + encodeURIComponent(session.id) + "/video";
  drawScrubTicks(session);
  updateDeviceButtons();
  updateAxMode();
  layoutWorkspace();
  if (tests.view !== "history") { tests.view = "history"; store("tests.view", "history"); }
  tests.selectedSession = session.id;
  if (inspector.tab === "tests") renderTests();
  video.play().catch(() => {});
}

function exitReplay() {
  if (app.dataset.mode !== "replay") return;
  tests.replay = null;
  replayCurrentIndex = -1;
  app.dataset.mode = "live";
  video.pause();
  video.removeAttribute("src");
  video.load();
  renderConnectionLabel();
  updateDeviceButtons();
  updateAxMode();
  layoutWorkspace();
  if (inspector.tab === "tests") renderTestsDetail();
}

function seekToStep(offset) {
  const session = tests.sessions.find((candidate) => candidate.id === tests.selectedSession);
  if (!session) return;
  if (!tests.replay || tests.replay.id !== session.id) enterReplay(session);
  const seek = () => { video.currentTime = offset; video.play().catch(() => {}); };
  if (video.readyState >= 1) seek(); else video.addEventListener("loadedmetadata", seek, { once: true });
}

function drawScrubTicks(session) {
  const duration = sessionDurationSeconds(session) || 1;
  $("scrubTicks").innerHTML = (session.entries || []).filter((entry) => entry.kind === "step").map((entry) => {
    const step = parseStepText(entry.text);
    const left = Math.min(100, entryOffsetSeconds(session, entry) / duration * 100);
    return '<span class="scrub-tick' + (step.mark === "failed" ? " fail" : "") + '" style="left:' + left + '%" title="' + escapeHTML(formatOffset(entryOffsetSeconds(session, entry)) + " " + step.text) + '"></span>';
  }).join("");
}

function updateTransport() {
  const duration = isFinite(video.duration) ? video.duration : 0;
  const position = video.currentTime || 0;
  $("playPause").innerHTML = icon(video.paused ? "play" : "pause");
  $("playPause").setAttribute("aria-label", video.paused ? "Play" : "Pause");
  $("replayTime").textContent = formatOffset(position) + " / " + formatOffset(duration);
  const percent = duration ? Math.min(100, position / duration * 100) : 0;
  $("scrubFill").style.width = percent + "%";
  $("scrubHead").style.left = percent + "%";
  const scrub = $("scrub");
  scrub.setAttribute("aria-valuemax", String(Math.round(duration)));
  scrub.setAttribute("aria-valuenow", String(Math.round(position)));
  scrub.setAttribute("aria-valuetext", formatOffset(position) + " of " + formatOffset(duration));
  // The current step follows the playhead.
  const session = tests.replay;
  if (!session) return;
  let current = -1;
  (session.entries || []).forEach((entry, index) => { if (entry.kind === "step" && entryOffsetSeconds(session, entry) <= position + 0.25) current = index; });
  if (current !== replayCurrentIndex) {
    replayCurrentIndex = current;
    if (inspector.tab === "tests" && tests.view === "history" && tests.selectedSession === session.id) {
      testsView.detail.querySelectorAll(".step").forEach((row) => row.classList.remove("current"));
      const steps = [...testsView.detail.querySelectorAll(".step[data-offset]")];
      const stepEntries = (session.entries || []).map((entry, index) => ({ entry, index })).filter(({ entry }) => entry.kind === "step");
      const position2 = stepEntries.findIndex(({ index }) => index === current);
      if (steps[position2]) steps[position2].classList.add("current");
    }
  }
}

for (const name of ["timeupdate", "play", "pause", "loadedmetadata", "ended", "seeked"]) video.addEventListener(name, updateTransport);
// An unfinished or missing mp4 (a hard-killed server): keep the timeline, say the video is gone.
video.addEventListener("error", () => { if (app.dataset.mode === "replay") $("replayNote").hidden = false; });
$("playPause").addEventListener("click", () => { if (video.paused) video.play().catch(() => {}); else video.pause(); });
$("backToLive").addEventListener("click", exitReplay);

function scrubTo(clientX) {
  const rect = $("scrub").getBoundingClientRect();
  const duration = isFinite(video.duration) ? video.duration : 0;
  if (!duration) return;
  video.currentTime = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width)) * duration;
}
let scrubbing = false;
$("scrub").addEventListener("pointerdown", (event) => { scrubbing = true; try { $("scrub").setPointerCapture(event.pointerId); } catch (_) {} scrubTo(event.clientX); });
$("scrub").addEventListener("pointermove", (event) => { if (scrubbing) scrubTo(event.clientX); });
$("scrub").addEventListener("pointerup", () => { scrubbing = false; });
$("scrub").addEventListener("keydown", (event) => {
  const step = { ArrowLeft: -5, ArrowRight: 5, PageDown: -15, PageUp: 15 }[event.key];
  if (step) { event.preventDefault(); video.currentTime = Math.max(0, Math.min(video.duration || 0, video.currentTime + step)); }
  if (event.key === "Home") { event.preventDefault(); video.currentTime = 0; }
  if (event.key === "End") { event.preventDefault(); video.currentTime = video.duration || 0; }
  if (event.key === " ") { event.preventDefault(); $("playPause").click(); }
});

// ---- Polling ----

let testsLastSessions = "";
let testsLastDefinitions = "";
async function loadTests() {
  const [sessions, definitions, run] = await Promise.all([apiJSON("/api/v1/tests"), apiJSON("/api/v1/tests/definitions"), apiJSON("/api/v1/tests/run")]);
  const sessionsKey = JSON.stringify(sessions.sessions || []);
  const definitionsKey = JSON.stringify([definitions.tests || [], run]);
  if (sessionsKey === testsLastSessions && definitionsKey === testsLastDefinitions) return;
  const previous = tests.sessions;
  testsLastSessions = sessionsKey;
  testsLastDefinitions = definitionsKey;
  tests.sessions = (sessions.sessions || []).slice().sort((a, b) => Date.parse(b.startedAt) - Date.parse(a.startedAt));
  tests.definitions = definitions.tests || [];
  const previousRun = tests.run;
  tests.run = run;
  // Follow a run that starts anywhere — here or from a terminal: select its test
  // so its steps stream in, and watch its session.
  if (run.active && run.sessionId && (!previousRun || previousRun.sessionId !== run.sessionId)) {
    tests.watchedSession = run.sessionId;
    if (run.file) { tests.selectedFile = run.file; store("tests.selected", run.file); }
    if (tests.view !== "tests") { tests.view = "tests"; store("tests.view", "tests"); }
  }
  // The moment the watched run ends, its recording takes the screen's place.
  if (tests.watchedSession) {
    const before = previous.find((session) => session.id === tests.watchedSession);
    const after = tests.sessions.find((session) => session.id === tests.watchedSession);
    if (after && after.status !== "running" && (!before || before.status === "running")) {
      tests.watchedSession = null;
      toast("“" + after.title + "” — " + outcomeOf(after).text, after.verdict === "satisfied" || after.status === "passed" ? { icon: "check" } : { error: true });
      if (inspector.open && inspector.tab === "tests" && !after.videoError) { tests.selectedSession = after.id; enterReplay(after); }
    }
  }
  if (tests.replay && !tests.sessions.some((session) => session.id === tests.replay.id)) exitReplay();
  renderTests();
}

tabHandlers.tests = { show() { renderTests(); poller.poke("tests"); } };
