// Activity: what agents, test runs and viewers did to the device — taps,
// scrolls, typing, launches, mocks armed, test steps. The server keeps the
// record; this page marks each touch on the screen in course ink as it
// happens, says in the toolbar who is driving, keeps the last action under the
// device, lists everything in the Activity tab, and asks before a person's own
// input lands in the middle of someone else's run.

const ACTIVITY_MAX = 500;
const MARK_FRESH_MS = 6000;   // older entries are history, not something to draw
const MARK_HOLD_MS = 1600;    // how long a mark stays before it fades
const activity = {
  entries: [],                 // oldest first
  revision: null,
  run: null,                   // the test run the last poll said drives the device
  drawn: new Set(),            // ids already marked on the screen
  cleared: 0,                  // ids below this are cleared from the list
  who: stored("activity.who", "all"),   // all | agent | test | viewer
  follow: true,
  selected: null,
  takenOver: null,             // the driving stretch a person chose to take the device from
  declinedAt: 0                // when a person last chose not to take over
};

const activityFilter = createFilter("activity", { placeholder: "Filter actions — tap, scroll, launch, mock…", onChange: () => renderActivity() });
const activityWho = segmented("Who", [["all", "All"], ["agent", "Agent"], ["test", "Test"], ["viewer", "Viewer"]], () => activity.who, (who) => { activity.who = who; store("activity.who", who); renderActivity(); });
const activityFollow = el("button", { class: "toggle toggle-sm", type: "button", "aria-pressed": "true", "data-tip": "Keep the newest action in view", html: icon("follow") + '<span class="toggle-label">Follow</span>' });
const activityClear = el("button", { class: "tb-btn", type: "button", "aria-label": "Clear the list", "data-tip": "Clear the list", html: icon("trash") });
const activityView = buildListPanel("activity", {
  listLabel: "Actions on the device",
  toolbar: [activityFilter.field, activityWho, el("span", { class: "ptool-spacer" }), activityFilter.help, activityFollow, activityClear]
});

const activityList = createList(activityView.list, {
  header: el("div", { class: "thead act-grid", role: "row", html: '<span class="cell" role="columnheader">Time</span><span class="cell" role="columnheader">Who</span><span class="cell" role="columnheader">Action</span><span class="cell num" role="columnheader">Result</span>' }),
  key: (entry) => String(entry.id),
  version: (entry) => entry.revision + "|" + (activityFilter.text || ""),
  rowClass: (entry) => "act-grid" + (entry.status === "failed" ? " act-failed" : "") + (entry.actor === "viewer" ? " act-viewer" : ""),
  render: renderActivityRow,
  empty: () => activityEmpty(),
  onSelect: (key, entry) => { activity.selected = entry; renderActivityDetail(); },
  exists: (key) => activity.entries.some((entry) => String(entry.id) === key && entry.id >= activity.cleared),
  onActivate: (key, entry) => { if (entry && entry.gesture) markActivity(entry, { replay: true }); },
  onMenu: (key, entry, x, y, row) => openMenu(x, y, activityMenu(entry), row),
  follow: () => activity.follow
});

function actorTag(entry) {
  return '<span class="who who-' + escapeHTML(entry.actor) + '">' + escapeHTML(ACTOR_NAMES[entry.actor] || entry.actor) + "</span>";
}

function activityResult(entry) {
  if (entry.status === "running") return '<span class="verdict v-running"><span class="spinner" aria-hidden="true"></span>Running</span>';
  if (entry.status === "failed") return '<span class="st st-err" title="' + escapeHTML(entry.error || "Failed") + '">' + icon("warn") + "Failed</span>";
  const ms = entry.endedAt ? Date.parse(entry.endedAt) - Date.parse(entry.at) : NaN;
  return '<span class="muted">' + escapeHTML(isFinite(ms) && ms > 0 ? formatDuration(ms) : "—") + "</span>";
}

function renderActivityRow(entry, row) {
  row.innerHTML =
    '<span class="cell time" title="' + escapeHTML(entry.at) + '">' + escapeHTML(formatClock(entry.at, true)) + "</span>" +
    '<span class="cell">' + actorTag(entry) + "</span>" +
    '<span class="cell name" translate="no"><b>' + markMatches(entry.title, activityFilter.text) + "</b>" +
      (entry.detail ? "<span>" + escapeHTML(entry.detail) + "</span>" : "") + "</span>" +
    '<span class="cell num">' + activityResult(entry) + "</span>";
  row.title = entry.title + (entry.error ? " — " + entry.error : "");
}

function activityEmpty() {
  const shown = activity.entries.filter((entry) => entry.id >= activity.cleared);
  if (activity.entries.length && !shown.length) return el("div", { class: "empty", html: "<b>Cleared</b>New actions appear here as they happen." });
  if (shown.length) {
    const node = el("div", { class: "empty", html: "<b>No action matches</b>The filter above hides all " + formatCount(shown.length) + ". " });
    node.append(el("button", { class: "btn btn-sm", type: "button", text: "Show all actions", onclick: () => { activity.who = "all"; store("activity.who", "all"); activityWho.sync(); activityFilter.clear(); } }));
    return node;
  }
  return el("div", { class: "empty", html: "<b>Nothing has acted on the device yet</b>Taps, scrolls, typing and launches from <code>simtool input</code>, the HTTP API and test runs appear here as they happen — and on the screen, in course ink, where the finger went." });
}

function activityVisible() {
  const query = activityFilter.text, chips = activityFilter.chips;
  return activity.entries.filter((entry) => {
    if (entry.id < activity.cleared) return false;
    if (activity.who !== "all" && entry.actor !== activity.who) return false;
    if (!query && !chips.length) return true;
    const hay = [entry.title, entry.detail, entry.kind, ACTOR_NAMES[entry.actor], entry.via, entry.error].filter(Boolean).join(" ").toLowerCase();
    return matchesFilters(hay, chips, query);
  });
}

let activityLastFilter = "";
function renderActivity() {
  const filterKey = activity.who + "|" + activityFilter.text + "|" + JSON.stringify(activityFilter.chips);
  if (filterKey !== activityLastFilter) { activityLastFilter = filterKey; activityList.invalidate(); }
  const rows = activityVisible();
  activityList.update(rows);
  const total = activity.entries.filter((entry) => entry.id >= activity.cleared).length;
  const failed = activity.entries.filter((entry) => entry.id >= activity.cleared && entry.status === "failed").length;
  setCount("activity", total, failed);
  activityView.guide.innerHTML = guideHTML([
    rows.length ? "<b>" + escapeHTML(formatClock(rows[0].at, true)) + " → " + escapeHTML(formatClock(rows[rows.length - 1].at, true)) + "</b>" : "",
    formatCount(rows.length) + " of " + plural(total, "action", "actions"),
    failed ? '<span class="st-err">' + plural(failed, "failed", "failed") + "</span>" : ""
  ], liveTag(activity.follow ? "following" : "recording"));
  if (activity.selected) {
    const fresh = activity.entries.find((entry) => entry.id === activity.selected.id);
    if (fresh && fresh !== activity.selected) { activity.selected = fresh; renderActivityDetail(); }
  }
}

function activityMenu(entry) {
  const command = activityCommand(entry);
  return [
    { icon: "pick", label: "Show on the screen", disabled: !entry.gesture || app.dataset.mode === "replay", run: () => markActivity(entry, { replay: true }) },
    { icon: "terminal", label: "Copy as command", disabled: !command, run: () => copyText(command, "Command copied") },
    { icon: "copy", label: "Copy the action", run: () => copyText(entry.title + (entry.detail ? " — " + entry.detail : ""), "Copied") },
    "-",
    { icon: "filter", label: "Show only " + (ACTOR_NAMES[entry.actor] || entry.actor), run: () => { activity.who = entry.actor; store("activity.who", entry.actor); activityWho.sync(); renderActivity(); } }
  ];
}

function renderActivityDetail() {
  const entry = activity.selected;
  showDetail(activityView.panel, !!entry);
  if (!entry) return;
  const command = activityCommand(entry);
  const ms = entry.endedAt ? Date.parse(entry.endedAt) - Date.parse(entry.at) : NaN;
  const gesture = entry.gesture;
  const point = (p) => Math.round(p.x) + ", " + Math.round(p.y) + " pt";
  let body = "";
  if (entry.status === "failed") body += '<div class="callout err">' + icon("warn") + "<div><b>Failed</b>" + (entry.error ? "<br>" + escapeHTML(entry.error) : "") + "</div></div>";
  // The head names who and how; a touch's own section says where.
  body += kvHTML({
    Action: entry.kind,
    Started: formatClock(entry.at, true),
    Finished: entry.endedAt ? formatClock(entry.endedAt, true) : "still running",
    Took: isFinite(ms) ? formatDuration(ms) : "",
    Detail: gesture ? "" : entry.detail
  });
  if (gesture) {
    body += '<div class="sec">Finger</div>' + kvHTML({
      Down: point(gesture.from),
      Up: Math.hypot(gesture.to.x - gesture.from.x, gesture.to.y - gesture.from.y) >= 1 ? point(gesture.to) : "where it went down",
      Rested: gesture.press ? formatDuration(gesture.press * 1000) : "",
      "Down for": formatDuration(gesture.duration * 1000),
      Screen: gesture.screen ? Math.round(gesture.screen.width) + " × " + Math.round(gesture.screen.height) + " pt" : ""
    });
  }
  if (command) body += '<div class="sec">Repeat it</div><div class="snippet"><pre class="code" translate="no">' + escapeHTML(command) + '</pre><button class="tb-btn" type="button" data-act="copy-command" aria-label="Copy the command" data-tip="Copy the command">' + icon("copy", "ic-sm") + "</button></div>";
  patchPane(activityView.detail, String(entry.id) + "|" + entry.revision,
    '<div class="dhead">' + actorTag(entry) + '<span class="dtitle ui" translate="no">' + escapeHTML(entry.title) + "</span>" +
      '<div class="dactions">' + (gesture ? '<button class="btn btn-sm btn-course" type="button" data-act="show">' + icon("pick", "ic-sm") + "Show on the screen</button>" : "") +
      '<button class="tb-btn" type="button" data-act="close" aria-label="Close the details">' + icon("close") + "</button></div></div>" +
    '<div class="dmeta"><span>' + escapeHTML(formatClock(entry.at, true)) + "</span>" + (entry.via ? "<span>via " + escapeHTML(entry.via) + "</span>" : "") + "<span>" + activityResult(entry) + "</span></div>" +
    '<div class="dbody">' + body + "</div>");
}

activityView.detail.addEventListener("click", (event) => {
  const action = event.target.closest("[data-act]");
  if (!action || !activity.selected) return;
  if (action.dataset.act === "show") markActivity(activity.selected, { replay: true });
  if (action.dataset.act === "copy-command") copyText(activityCommand(activity.selected), "Command copied");
  if (action.dataset.act === "close") { activityList.select(null); activityList.focus(); }
});

function setActivityFollow(on) {
  if (activity.follow === on) return;
  activity.follow = on;
  activityFollow.setAttribute("aria-pressed", String(on));
  renderActivity();
}
activityFollow.addEventListener("click", () => { setActivityFollow(!activity.follow); if (activity.follow) activityList.scrollToEnd(); });
activityView.list.addEventListener("scroll", () => {
  const atBottom = activityList.atBottom();
  if (atBottom !== activity.follow && activityView.list.scrollHeight > activityView.list.clientHeight) setActivityFollow(atBottom);
}, { passive: true });
activityClear.addEventListener("click", () => {
  const previous = activity.cleared;
  const last = activity.entries[activity.entries.length - 1];
  activity.cleared = last ? last.id + 1 : 0;
  activityList.select(null);
  renderActivity();
  toast("Activity list cleared", { icon: "trash", duration: 5000, action: { label: "Undo", run: () => { activity.cleared = previous; renderActivity(); } } });
});

// ---- Marks on the screen: where the finger went, in course ink ----

const activityLayer = $("activityLayer");
let activityCaption = null;

// A touch draws its path and a caption beside it; anything else captions the
// top of the screen. A mark comes and goes by timers, so it reads the same
// with reduced motion — only the drawing-in is animated.
function markActivity(entry, { replay } = {}) {
  if (app.dataset.mode === "replay") return;
  const ratios = entry.gesture ? gestureRatios(entry.gesture, screenState.points) : null;
  const rect = activityLayer.getBoundingClientRect();
  if (ratios && rect.width) {
    const mark = el("div", { class: "act-mark" + (entry.status === "failed" ? " failed" : "") });
    const x1 = ratios.from.x * rect.width, y1 = ratios.from.y * rect.height, x2 = ratios.to.x * rect.width, y2 = ratios.to.y * rect.height;
    const travel = Math.max(0.3, Math.min(2, entry.gesture.duration - entry.gesture.press)) + "s";
    if (ratios.moved) {
      const length = Math.hypot(x2 - x1, y2 - y1);
      const angle = Math.atan2(y2 - y1, x2 - x1) * 180 / Math.PI;
      mark.innerHTML = '<svg class="act-path" width="' + rect.width + '" height="' + rect.height + '" viewBox="0 0 ' + rect.width + " " + rect.height + '">' +
        '<line x1="' + x1 + '" y1="' + y1 + '" x2="' + x2 + '" y2="' + y2 + '" style="stroke-dasharray:' + length + ";stroke-dashoffset:" + length + ";--travel:" + travel + '"/>' +
        '<path d="M -9 -6 L 0 0 L -9 6" transform="translate(' + x2 + " " + y2 + ") rotate(" + angle + ')" style="--travel:' + travel + '"/></svg>';
    }
    mark.append(el("span", { class: "act-ring" + (entry.kind === "long-press" || entry.gesture.press >= 0.5 ? " held" : ""), style: "left:" + x1 + "px;top:" + y1 + "px" }));
    const caption = el("span", { class: "act-label", text: (replay ? "" : (ACTOR_NAMES[entry.actor] || "") + " · ") + entry.title });
    // Above the finger unless that would leave the screen; kept inside its sides.
    caption.style.top = (y1 > 48 ? y1 - 40 : y1 + 26) + "px";
    caption.style.left = Math.min(Math.max(8, x1 - 60), Math.max(8, rect.width - 168)) + "px";
    mark.append(caption);
    activityLayer.append(mark);
    retire(mark, Math.max(MARK_HOLD_MS, entry.gesture.duration * 1000 + 900));
    return;
  }
  if (activityCaption) activityCaption.remove();
  const caption = el("div", { class: "act-caption" + (entry.status === "failed" ? " failed" : "") }, el("span", { class: "who who-" + entry.actor, text: ACTOR_NAMES[entry.actor] || entry.actor }), el("span", { text: entry.title }));
  activityLayer.append(caption);
  activityCaption = caption;
  retire(caption, MARK_HOLD_MS + 800, () => { if (activityCaption === caption) activityCaption = null; });
}

function retire(node, after, done) {
  setTimeout(() => {
    node.classList.add("fading");
    setTimeout(() => { node.remove(); if (done) done(); }, 400);
  }, after);
}

// Marks only what is happening now: an entry seen first in history is a row, not a mark.
function markFresh(entry) {
  if (entry.actor === "viewer" || activity.drawn.has(entry.id)) return;
  if (Date.now() - Date.parse(entry.at) > MARK_FRESH_MS) { activity.drawn.add(entry.id); return; }
  // A touch waits for its path; the server learns it a moment after the entry opens.
  if (["tap", "long-press", "swipe", "drag", "scroll", "fling"].includes(entry.kind) && !entry.gesture && entry.status === "running") return;
  activity.drawn.add(entry.id);
  markActivity(entry);
}

// ---- Who drives the device, and the last thing done to it ----

// On the stream the Tests topic keeps the run current; polls bring it with the feed.
function currentDriver() {
  return deviceDriver(activity.entries, inspectorEvents.polling ? activity.run : tests.run, Date.now());
}

function renderDriver() {
  const driver = currentDriver();
  const chip = $("driverChip");
  app.classList.toggle("driven", !!driver);
  chip.hidden = !driver;
  if (driver) {
    const long = driver.actor === "test"
      ? "Test running" + (driver.step ? " · step " + driver.step.index + " of " + driver.step.total : "")
      : "Agent driving";
    const short = driver.actor === "test" ? (driver.step ? driver.step.index + "/" + driver.step.total : "Test") : "Agent";
    $("driverLabel").textContent = long;
    $("driverShort").textContent = short;
    chip.dataset.tip = driver.actor === "test" ? "“" + driver.title + "” is driving the device" : "Last: " + driver.title + " · " + formatSince(Date.now() - driver.lastAt);
    chip.setAttribute("aria-label", long + (driver.actor === "test" ? ": " + driver.title : "") + " — show the activity");
  }
  const last = [...activity.entries].reverse().find((entry) => entry.actor !== "viewer");
  const age = last ? Date.now() - Date.parse(last.endedAt || last.at) : Infinity;
  const cell = $("readLast");
  cell.hidden = !last || age > 10 * 60 * 1000;
  if (!cell.hidden) {
    cell.classList.toggle("recent", last.status === "running" || age < 5000);
    cell.innerHTML = '<span class="who who-' + escapeHTML(last.actor) + '">' + escapeHTML(ACTOR_NAMES[last.actor] || last.actor) + "</span>" +
      '<span class="read-title" translate="no">' + escapeHTML(last.title) + "</span>" +
      "<span>" + escapeHTML(last.status === "running" ? "running" : last.status === "failed" ? "failed · " + formatSince(age) : formatSince(age)) + "</span>";
  }
}
setInterval(renderDriver, 1000);
$("driverChip").addEventListener("click", () => openTab("activity"));
$("readLast").addEventListener("click", () => openTab("activity"));

// ---- Before a person's input lands in someone else's run ----

// True when the person may act now. Otherwise asks once per driving stretch
// whether to take over, and runs `proceed` (the action that was stopped) on yes.
// A no holds for a moment: a trackpad's momentum and a held key keep sending
// input after the answer, and none of it should ask again.
const DECLINE_QUIET_MS = 1500;
function manualInputAllowed(proceed) {
  const driver = currentDriver();
  if (!driver || activity.takenOver === driver.key) return true;
  if (!$("dialogScrim").hidden || Date.now() - activity.declinedAt < DECLINE_QUIET_MS) return false;
  const text = driver.actor === "test"
    ? "“" + driver.title + "” is running" + (driver.step ? " at step " + driver.step.index + " of " + driver.step.total : "") + ". A touch, a key or a button now lands in the middle of its steps and can break the run — and the recording shows it."
    : "An agent acted on it " + formatSince(Date.now() - driver.lastAt) + " (" + driver.title + "). Input from here can change the screen under its next step.";
  confirmDestructive(driver.actor === "test" ? "A test is driving this device" : "An agent is driving this device", text, "Take over").then((yes) => {
    if (!yes) { activity.declinedAt = Date.now(); return; }
    activity.takenOver = driver.key;
    toast("You have the device until the next run or agent starts", { icon: "check" });
    if (proceed) proceed();
  });
  return false;
}

// ---- Polling ----

// An entry arrives once per change, by the stream, a poll or both, and two of
// its changes may cross on the way: the higher revision is the one kept.
// Returns the entries that were news.
function mergeActivity(entries) {
  if (!entries.length) return [];
  const index = new Map(activity.entries.map((entry, position) => [entry.id, position]));
  const fresh = [];
  for (const entry of entries) {
    const at = index.get(entry.id);
    if (at == null) { index.set(entry.id, activity.entries.length); activity.entries.push(entry); }
    else if (activity.entries[at].revision < entry.revision) activity.entries[at] = entry;
    else continue;
    fresh.push(entry);
  }
  activity.entries.sort((a, b) => a.id - b.id);
  if (activity.entries.length > ACTIVITY_MAX) activity.entries.splice(0, activity.entries.length - ACTIVITY_MAX);
  return fresh;
}

// What arrived — a poll's answer, a stream message, or (`history`) everything
// the server holds. History is rows, not marks: marks are for what happens
// while the page watches.
function takeActivity(entries, revision, history) {
  const fresh = mergeActivity(entries);
  if (revision != null) activity.revision = Math.max(activity.revision || 0, revision);
  for (const entry of fresh) { if (history) activity.drawn.add(entry.id); else markFresh(entry); }
  renderDriver();
  if (fresh.length || history) renderSoon(renderActivity);
}

async function pollActivity() {
  const first = activity.revision == null;
  const payload = await apiJSON("/api/v1/activity" + (first ? "" : "?since=" + activity.revision));
  activity.run = payload.run || null;
  takeActivity(payload.entries || [], payload.revision, first);
}

// The stream's `activity` topic; a snapshot replaces the list.
function applyActivityTopic(payload, reset) {
  if (reset) { activity.entries = []; activity.revision = null; }
  takeActivity(payload.entries || [], payload.revision, reset);
}

tabHandlers.activity = { show() { renderActivity(); poller.poke("activity"); } };

function resetActivity() {
  activity.entries = [];
  activity.revision = null;
  activity.run = null;
  activity.cleared = 0;
  activityList.select(null);
  renderActivity();
  renderDriver();
}
