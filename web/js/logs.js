// Logs: the attached app's OSLog (and stdout when SimTool launched it),
// captured by the server and drained incrementally by cursor.

const LOGS_MAX = 3000;
const LOGS_FILTER_FIELDS = ["message", "subsystem", "category", "process", "level"];
const logs = {
  entries: [],
  cursor: null,
  captureStarted: false,
  dropped: 0,
  levels: Object.assign({ Debug: true, Info: true, Default: true, Error: true, Fault: true }, stored("logs.levels", {})),
  follow: true,
  unseen: 0,
  cleared: 0,          // sequence below which lines are cleared from view
  selected: null,
  status: ""
};

const logsFilter = createFilter("logs", {
  placeholder: "Filter messages — subsystem:, category:, process:",
  fields: LOGS_FILTER_FIELDS,
  onChange: () => renderLogs()
});

const logsLevels = el("div", { class: "levels", role: "group", "aria-label": "Levels" });
const logsFollow = el("button", { class: "toggle toggle-sm", type: "button", "aria-pressed": "true", "data-tip": "Keep the newest line in view", html: icon("follow") + '<span class="toggle-label">Follow</span>' });
const logsClear = el("button", { class: "tb-btn", type: "button", "aria-label": "Clear the list", "data-tip": "Clear the list", html: icon("trash") });
const logsNew = el("button", { class: "newlines", type: "button", hidden: true });

const logsView = buildListPanel("logs", {
  listLabel: "Log lines",
  toolbar: [logsFilter.field, logsLevels, el("span", { class: "ptool-spacer" }), logsFilter.help, logsFollow, logsClear]
});
logsView.listWrap.append(logsNew);

const logsList = createList(logsView.list, {
  header: el("div", { class: "thead log-grid", role: "row", html: '<span class="cell" role="columnheader">Time</span><span class="cell" role="columnheader">Level</span><span class="cell c-ss" role="columnheader">Subsystem</span><span class="cell" role="columnheader">Message</span>' }),
  key: (entry) => String(entry.sequence),
  version: (entry) => (logsFilter.text || "") + "|" + (entry.launchId === newestLaunchId() ? 1 : 0),
  rowClass: (entry) => "log-grid" + (isLogError(entry) ? " lvl-err" : "") + (!reviewActive() && entry.launchId != null && entry.launchId !== newestLaunchId() ? " retired" : ""),
  group: (entry) => !reviewActive() && entry.launchId != null ? String(entry.launchId) : null,
  renderGroup: (id, items, collapsed) => launchGroupHTML(id, items, collapsed, "line", [{ count: items.filter(isLogError).length, tone: "err", one: "error", many: "errors" }]),
  render: renderLogRow,
  empty: () => logsEmpty(),
  onSelect: (key, entry) => { logs.selected = entry; renderLogDetail(); },
  exists: (key) => logRows().some((entry) => String(entry.sequence) === key),
  onMenu: (key, entry, x, y, row) => openMenu(x, y, logRowMenu(entry, row), row),
  onGroupMenu: (id, x, y, button) => openMenu(x, y, launchGroupMenu("logs", id), button),
  follow: () => logs.follow
});

function markMatches(text, query) {
  const escaped = escapeHTML(text);
  if (!query) return escaped;
  const needle = escapeHTML(query).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return escaped.replace(new RegExp(needle, "gi"), (match) => "<mark>" + match + "</mark>");
}

function renderLogRow(entry, row) {
  const level = logLevel(entry);
  const query = parseFieldTerm(logsFilter.text, LOGS_FILTER_FIELDS);
  const message = String(entry.message || "").replace(/\s*\n\s*/g, " ⏎ ");
  row.innerHTML =
    '<span class="cell time" title="' + escapeHTML(entry.timestamp || "") + '">' + escapeHTML(formatClock(entry.timestamp, true)) + "</span>" +
    '<span class="cell"><span class="lv lv-' + level.toLowerCase() + '">' + level + "</span></span>" +
    '<span class="cell ss c-ss" translate="no" title="' + escapeHTML([entry.subsystem, entry.category].filter(Boolean).join(" · ")) + '">' + escapeHTML(entry.subsystem || entry.process || (entry.source === "stdout" ? "stdout" : "—")) + "</span>" +
    '<span class="cell msg" translate="no">' + markMatches(message, query.field && query.field !== "message" ? "" : query.term) + "</span>";
}

function logsEmpty() {
  if (reviewActive()) return reviewEmpty("logs");
  if (!inspector.attachedApp && inspector.configKnown) return noAppPanel("logs");
  if (logs.entries.length && logs.entries.every((entry) => entry.sequence < logs.cleared)) return el("div", { class: "empty", html: "<b>Cleared</b>New lines appear here as the app logs them." });
  if (logs.entries.length) {
    const node = el("div", { class: "empty", html: "<b>No line matches</b>The levels and the filter above hide all " + formatCount(logs.entries.length) + ". " });
    node.append(el("button", { class: "btn btn-sm", type: "button", text: "Show all lines", onclick: () => {
      for (const level of LOG_LEVELS) logs.levels[level] = true;
      store("logs.levels", logs.levels);
      logsFilter.clear();
    } }));
    return node;
  }
  return el("div", { class: "empty", html: "<b>Waiting for log lines</b>" + escapeHTML(logs.status || "Capturing " + inspector.attachedApp + "'s OSLog.") });
}

// One button per level, made once: polling updates their counts in place, so
// focus stays on the one a person is about to press.
const logsLevelButtons = new Map();
for (const level of LOG_LEVELS) {
  const count = el("span", { class: "count" });
  const button = el("button", { type: "button", "data-level": level },
    level === "Error" || level === "Fault" ? el("span", { class: "dot dot-err" }) : null, level + " ", count);
  button.addEventListener("click", () => {
    logs.levels[level] = logs.levels[level] === false;
    store("logs.levels", logs.levels);
    renderLogs();
  });
  logsLevels.append(button);
  logsLevelButtons.set(level, { button, count });
}

function renderLevels() {
  const counts = {};
  for (const entry of logRows()) {
    const level = logLevel(entry);
    counts[level] = (counts[level] || 0) + 1;
  }
  for (const [level, { button, count }] of logsLevelButtons) {
    const shown = logs.levels[level] !== false;
    button.setAttribute("aria-pressed", String(shown));
    button.title = (shown ? "Hide " : "Show ") + level + " lines";
    count.textContent = formatCount(counts[level] || 0);
  }
}

// The lines the list is about: the live ones not cleared, or the reviewed run's in its window.
function logRows() {
  return reviewActive() ? reviewRows("logs", logs.entries) : logs.entries.filter((entry) => entry.sequence >= logs.cleared);
}

function logsVisible() {
  const parsed = parseFieldTerm(logsFilter.text, LOGS_FILTER_FIELDS);
  const chips = logsFilter.chips;
  return logRows().filter((entry) => {
    if (logs.levels[logLevel(entry)] === false) return false;
    if (!parsed.term && !chips.length) return true;
    const fields = logFields(entry);
    const hay = [fields.message, fields.subsystem, fields.category, fields.process, fields.level].join(" ");
    return matchesFilters(hay, chips, parsed.term, fields, parsed.field);
  });
}

let logsLastFilter = "";
function renderLogs() {
  const filterKey = logsFilter.text + "|" + JSON.stringify(logsFilter.chips) + "|" + JSON.stringify(logs.levels);
  if (filterKey !== logsLastFilter) { logsLastFilter = filterKey; logsList.invalidate(); }
  const rows = logsVisible();
  // Group by launch rather than arrival order: crash summaries are ingested
  // during the next launch and would otherwise split their launch in two.
  rows.sort((a, b) => ((a.launchId ?? -1) - (b.launchId ?? -1)) || (a.sequence - b.sequence));
  logsList.update(rows);
  renderLevels();
  const all = logRows();
  const errors = all.filter(isLogError).length;
  setCount("logs", all.length, errors);
  const times = rows.length ? [rows[0].timestamp, rows[rows.length - 1].timestamp] : null;
  logsView.guide.innerHTML = guideHTML([
    times ? "<b>" + escapeHTML(formatClock(times[0], true)) + " → " + escapeHTML(formatClock(times[1], true)) + "</b>" : "",
    formatCount(rows.length) + " shown",
    !reviewActive() && logs.entries.length >= LOGS_MAX ? "newest " + formatCount(LOGS_MAX) + " kept" : "",
    !reviewActive() && logs.dropped ? '<span title="The capture fell behind and skipped lines">' + plural(logs.dropped, "line dropped by the capture", "lines dropped by the capture") + "</span>" : "",
    inspector.attachedApp ? escapeHTML(inspector.attachedApp) : ""
  ], liveTag(logs.follow ? "following" : "capturing"));
}

// Follow keeps the newest line in view while the list sits at its end. Scrolling
// up to read turns it off — new lines then wait under a "N new lines" button —
// and scrolling back to the end turns it on again, as in Console.app.
function setLogsFollow(on) {
  if (logs.follow === on) return;
  logs.follow = on;
  logsFollow.setAttribute("aria-pressed", String(on));
  if (on) { logs.unseen = 0; logsNew.hidden = true; }
  renderLogs();
}
logsFollow.addEventListener("click", () => {
  setLogsFollow(!logs.follow);
  if (logs.follow) logsList.scrollToEnd();
});
logsView.list.addEventListener("scroll", () => {
  const atBottom = logsList.atBottom();
  if (atBottom) { logs.unseen = 0; logsNew.hidden = true; }
  // Only a person scrolls the list away from its end; renders keep the position.
  if (atBottom !== logs.follow && logsView.list.scrollHeight > logsView.list.clientHeight) setLogsFollow(atBottom);
}, { passive: true });
logsNew.addEventListener("click", () => { logsList.scrollToEnd(); setLogsFollow(true); });
logsClear.addEventListener("click", () => {
  const previous = logs.cleared;
  const last = logs.entries[logs.entries.length - 1];
  logs.cleared = last ? last.sequence + 1 : 0;
  logsList.select(null);
  renderLogs();
  toast("Log list cleared", { icon: "trash", duration: 5000, action: { label: "Undo", run: () => { logs.cleared = previous; renderLogs(); } } });
});

function logRowMenu(entry, row) {
  const selection = selectionInside(logsView.list).replace(/\s+/g, " ").trim();
  const items = [
    { icon: "copy", label: "Copy line", run: () => copyText(logLine(entry), "Line copied") },
    { icon: "copy", label: "Copy message", run: () => copyText(entry.message || "", "Message copied") }
  ];
  if (selection) {
    const short = selection.length > 40 ? selection.slice(0, 39) + "…" : selection;
    items.push("-",
      { icon: "copy", label: "Copy selection", run: () => copyText(selection, "Selection copied") },
      { icon: "filter", label: "Show only “" + short + "”", run: () => logsFilter.addChip("include", selection) },
      { icon: "close", label: "Hide “" + short + "”", run: () => logsFilter.addChip("exclude", selection) });
  } else if (entry.subsystem) {
    items.push("-",
      { icon: "filter", label: "Show only " + entry.subsystem, run: () => logsFilter.addChip("include", entry.subsystem.toLowerCase(), "subsystem") },
      { icon: "close", label: "Hide " + entry.subsystem, run: () => logsFilter.addChip("exclude", entry.subsystem.toLowerCase(), "subsystem") });
  }
  return items;
}

function renderLogDetail() {
  const entry = logs.selected;
  showDetail(logsView.panel, !!entry);
  if (!entry) return;
  const level = logLevel(entry);
  logsView.detail.innerHTML =
    '<div class="dhead"><span class="lv lv-' + level.toLowerCase() + '">' + level + "</span>" +
      '<span class="dtitle" translate="no">' + escapeHTML([entry.subsystem, entry.category].filter(Boolean).join(" · ") || entry.process || "(no subsystem)") + "</span>" +
      '<div class="dactions"><button class="btn btn-sm" type="button" data-act="copy">' + icon("copy", "ic-sm") + "Copy message</button>" +
      '<button class="tb-btn" type="button" data-act="close" aria-label="Close the details">' + icon("close") + "</button></div></div>" +
    '<div class="dmeta"><span>' + escapeHTML(formatClock(entry.timestamp, true)) + " local</span>" +
      (entry.process ? "<span>" + escapeHTML(entry.process) + "</span>" : "") +
      "<span>" + escapeHTML(entry.source === "stdout" ? "stdout" : "OSLog") + "</span>" +
      (entry.launchId != null && launchesById[entry.launchId] ? "<span>pid " + escapeHTML(launchesById[entry.launchId].pid) + "</span>" : "") + "</div>" +
    '<div class="dbody"><pre class="code" translate="no">' + escapeHTML(entry.message || "") + "</pre></div>";
}

logsView.detail.addEventListener("click", (event) => {
  const action = event.target.closest("[data-act]");
  if (!action || !logs.selected) return;
  if (action.dataset.act === "copy") copyText(logs.selected.message || "", "Message copied");
  if (action.dataset.act === "close") { logsList.select(null); logsList.focus(); }
});

// ---- Capture and polling ----

async function startLogsCapture() {
  const app = inspector.attachedApp;
  // Capture only ever starts scoped to an app: an unscoped capture streams OSLog
  // for the whole simulator, which drowns the viewer in unrelated system noise.
  if (!app) return;
  logs.entries = [];
  logs.cursor = null;
  try {
    await api("/api/v1/logs/capture", { method: "POST", body: JSON.stringify({ app }) });
    logs.captureStarted = true;
    logs.status = "Capturing " + app + "'s OSLog.";
  } catch (error) {
    logs.status = "Log capture failed: " + error.message;
    throw error;
  }
}

async function pollLogs() {
  if (!logs.captureStarted) { await startLogsCapture(); if (!logs.captureStarted) return; }
  await loadLaunches();
  const since = logs.cursor == null ? "" : "&since=" + logs.cursor;
  const payload = await apiJSON("/api/v1/logs/capture?limit=500" + since);
  const entries = payload.entries || [];
  if (payload.cursor != null) logs.cursor = payload.cursor;
  logs.dropped = payload.droppedCount || 0;
  if (!entries.length) { if (inspector.tab === "logs") renderLogs(); return; }
  logs.entries = logs.entries.concat(entries);
  if (logs.entries.length > LOGS_MAX) logs.entries = logs.entries.slice(logs.entries.length - LOGS_MAX);
  if (!(logs.follow && logsList.atBottom())) {
    logs.unseen += entries.length;
    logsNew.hidden = false;
    logsNew.innerHTML = icon("follow", "ic-sm") + plural(logs.unseen, "new line", "new lines");
  }
  renderLogs();
}

tabHandlers.logs = { show() { renderLogs(); poller.poke("logs"); } };

function resetLogs() {
  logs.entries = [];
  logs.cursor = null;
  logs.captureStarted = false;
  logs.cleared = 0;
  logsList.select(null);
  renderLogs();
}
