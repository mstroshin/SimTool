// The inspector frame: tabs, the splitter between the device and the
// inspector, the filter field every tab shares, app launches, and the
// split detail under each list.

const TABS = ["network", "logs", "state", "ax", "tests", "activity"];
const inspector = { tab: stored("tab", "network"), open: stored("inspectorOpen", true), attachedApp: "", configKnown: false };
const tabHandlers = {};   // tab → { show(), hide() }

function setTab(tab, { focus } = {}) {
  if (!TABS.includes(tab)) tab = "network";
  const previous = inspector.tab;
  inspector.tab = tab;
  store("tab", tab);
  for (const name of TABS) {
    const button = $("tab-" + name);
    const active = name === tab;
    button.setAttribute("aria-selected", String(active));
    button.tabIndex = active ? 0 : -1;
    $("panel-" + name).hidden = !active;
  }
  if (focus) $("tab-" + tab).focus();
  if (previous !== tab && tabHandlers[previous] && tabHandlers[previous].hide) tabHandlers[previous].hide();
  if (tabHandlers[tab] && tabHandlers[tab].show) tabHandlers[tab].show();
  closeMenu();
  closePopover();
}

$("tabs").addEventListener("click", (event) => {
  const button = event.target.closest("[role=tab]");
  if (button) setTab(button.dataset.tab);
});
$("tabs").addEventListener("keydown", (event) => {
  const index = TABS.indexOf(inspector.tab);
  let next = null;
  if (event.key === "ArrowRight") next = TABS[(index + 1) % TABS.length];
  if (event.key === "ArrowLeft") next = TABS[(index + TABS.length - 1) % TABS.length];
  if (event.key === "Home") next = TABS[0];
  if (event.key === "End") next = TABS[TABS.length - 1];
  if (next) { event.preventDefault(); setTab(next, { focus: true }); }
});

// The tab's mark is red for failures; with none, amber for client-side problems
// (Network's 4xx and gRPC client codes) — the colour the rows use.
function setCount(tab, count, errors, warnings) {
  const countNode = $("count-" + tab);
  if (countNode) countNode.textContent = count ? formatCount(count) : "";
  const errorNode = $("err-" + tab);
  if (errorNode) {
    const shown = errors || warnings || 0;
    errorNode.hidden = !shown;
    errorNode.classList.toggle("count-warn", !errors && !!warnings);
    errorNode.textContent = shown ? formatCount(shown) : "";
    errorNode.title = errors ? plural(errors, "failure", "failures") : warnings ? plural(warnings, "client error", "client errors") : "";
  }
}

function setInspectorOpen(open) {
  inspector.open = open;
  store("inspectorOpen", open);
  $("workspace").classList.toggle("no-inspector", !open);
  $("inspectorToggle").setAttribute("aria-pressed", String(open));
  if (tabHandlers[inspector.tab]) (open ? tabHandlers[inspector.tab].show : tabHandlers[inspector.tab].hide || (() => {}))();
  requestAnimationFrame(fitDevice);
}
$("inspectorToggle").addEventListener("click", () => setInspectorOpen(!inspector.open));

// ---- Layout: side by side when there is room, stacked in a narrow pane ----

const STACK_BELOW = 760;
function layoutWorkspace() {
  const workspace = $("workspace");
  const rect = workspace.getBoundingClientRect();
  const stacked = rect.width < STACK_BELOW;
  workspace.classList.toggle("stacked", stacked);
  $("splitter").setAttribute("aria-orientation", stacked ? "horizontal" : "vertical");
  if (!stacked) {
    const saved = stored("stageWidth", null);
    // By default the stage is as wide as the device needs at full height; the inspector takes the rest.
    const availableHeight = rect.height - 28 - 40 - (app.dataset.mode === "replay" ? 76 : 0);
    const aspect = screenState.width ? screenState.width / screenState.height : 402 / 874;
    const ideal = Math.round(availableHeight * aspect + 120);
    const width = Math.max(300, Math.min(saved || ideal, rect.width - 380));
    workspace.style.setProperty("--stage-w", width + "px");
  } else {
    const savedHeight = stored("stageHeight", null);
    workspace.style.setProperty("--stage-h", savedHeight ? Math.max(200, Math.min(savedHeight, rect.height - 200)) + "px" : "45%");
  }
  if ($("splitter").syncValue) $("splitter").syncValue();
}
new ResizeObserver(layoutWorkspace).observe($("workspace"));

wireSplitter($("splitter"), {
  axis: "x",
  onMove(position, event) {
    const workspace = $("workspace");
    const rect = workspace.getBoundingClientRect();
    if (workspace.classList.contains("stacked")) {
      const height = Math.max(200, Math.min(rect.height - 200, event.clientY - rect.top));
      workspace.style.setProperty("--stage-h", height + "px");
      $("splitter").dataset.size = height;
    } else {
      const width = Math.max(300, Math.min(rect.width - 380, position - rect.left));
      workspace.style.setProperty("--stage-w", width + "px");
      $("splitter").dataset.size = width;
    }
  },
  onEnd() {
    const size = Number($("splitter").dataset.size);
    if (size) store($("workspace").classList.contains("stacked") ? "stageHeight" : "stageWidth", size);
  },
  step(direction, amount) {
    const workspace = $("workspace");
    const stacked = workspace.classList.contains("stacked");
    const current = stacked ? $("stage").getBoundingClientRect().height : $("stage").getBoundingClientRect().width;
    const rect = workspace.getBoundingClientRect();
    const next = current + direction * amount;
    if (stacked) workspace.style.setProperty("--stage-h", Math.max(200, Math.min(rect.height - 200, next)) + "px");
    else workspace.style.setProperty("--stage-w", Math.max(300, Math.min(rect.width - 380, next)) + "px");
    $("splitter").dataset.size = next;
  },
  value() {
    const workspace = $("workspace").getBoundingClientRect(), stage = $("stage").getBoundingClientRect();
    return $("workspace").classList.contains("stacked") ? stage.height / workspace.height * 100 : stage.width / workspace.width * 100;
  }
});
// ---- Split detail under a list ----

function wireDetailSplit(panel, handle) {
  wireSplitter(handle, {
    axis: "y",
    onMove(position) {
      const rect = panel.getBoundingClientRect();
      const height = Math.max(120, Math.min(rect.height - 140, rect.bottom - position));
      panel.style.setProperty("--detail-h", height + "px");
    },
    onEnd() {
      const height = parseInt(getComputedStyle(panel).getPropertyValue("--detail-h"), 10);
      if (height) store("detailHeight", height);
    },
    step(direction, amount) {
      const detail = panel.querySelector(".detail");
      const rect = panel.getBoundingClientRect();
      const height = Math.max(120, Math.min(rect.height - 140, detail.getBoundingClientRect().height - direction * amount));
      panel.style.setProperty("--detail-h", height + "px");
    },
    value() { return panel.querySelector(".detail").getBoundingClientRect().height / panel.getBoundingClientRect().height * 100; }
  });
  const saved = stored("detailHeight", null);
  if (saved) panel.style.setProperty("--detail-h", saved + "px");
}

// The standard frame of a list tab: toolbar, guide words, list, splitter, detail.
function buildListPanel(tab, { toolbar, listRole, listLabel }) {
  const panel = $("panel-" + tab);
  const ptool = el("div", { class: "ptool" });
  for (const node of toolbar) ptool.append(node);
  const guide = el("div", { class: "guide", "aria-live": "off" });
  const list = el("div", { class: "list", role: listRole || "listbox", "aria-label": listLabel });
  const listWrap = el("div", { class: "list-wrap" }, list);
  const handle = el("div", { class: "hsplit", role: "separator", tabindex: "0", "aria-orientation": "horizontal", "aria-label": "Resize the details" });
  const detail = el("div", { class: "detail", role: "region", "aria-label": "Details" });
  panel.append(ptool, guide, listWrap, handle, detail);
  panel.classList.add("no-detail");
  wireDetailSplit(panel, handle);
  return { panel, ptool, guide, list, listWrap, detail };
}

function showDetail(panel, visible) { panel.classList.toggle("no-detail", !visible); }

// ---- The filter field: live text plus include/exclude chips, per tab ----

const FILTER_HELP = {
  network: '<p><b>Type</b> to filter by name, host, path, status.</p><p><b>Enter</b> keeps the text as an include chip — show only matches; <b>-text Enter</b> makes an exclude chip.</p><p><b>Right-click</b> a request to show or hide its path.</p>',
  logs: '<p><b>Type</b> to filter messages; <b>subsystem:text</b> (or category, process, level, message) matches one field.</p><p><b>Enter</b> keeps it as an include chip; <b>-text Enter</b> excludes.</p><p><b>Select text</b> in a line and right-click to show or hide it.</p>',
  state: '<p><b>Type</b> to filter models by name and their keys and values.</p>',
  ax: '<p><b>Type</b> to filter by identifier, label, role; matches keep their ancestors visible.</p>',
  tests: '<p><b>Type</b> to filter tests and runs by name, file, reference, verdict.</p>',
  activity: '<p><b>Type</b> to filter actions by what they did — tap, scroll, launch, mock — and who did it.</p><p><b>Enter</b> on an action draws it on the screen again.</p>'
};

function createFilter(tab, { placeholder, fields, onChange }) {
  // Earlier viewers kept every tab's chips under one key, simtool.filterChips.
  const legacy = stored("filterChips", null);
  const chips = stored("chips." + tab, null) || (legacy && Array.isArray(legacy[tab]) ? legacy[tab] : []);
  const state = { text: "", chips: chips.filter((chip) => chip && (chip.kind === "include" || chip.kind === "exclude") && typeof chip.term === "string" && chip.term.trim()) };
  const chipsNode = el("span", { class: "chips" });
  const input = el("input", { type: "search", placeholder, "aria-label": "Filter " + tab, autocomplete: "off", spellcheck: "false", translate: "no" });
  const field = el("label", { class: "filter" }, el("span", { html: icon("search", "ic-sm") }), chipsNode, input, el("kbd", { class: "filter-kbd", text: "/" }));
  const help = el("button", { class: "tb-btn", type: "button", id: "help-" + tab, "aria-label": "Filter help", "aria-expanded": "false", "aria-haspopup": "dialog", html: icon("help") });

  function save() { store("chips." + tab, state.chips); }
  function renderChips() {
    chipsNode.innerHTML = "";
    state.chips.forEach((chip, index) => {
      const label = (chip.field ? chip.field + ":" : "") + chip.term;
      const node = el("span", { class: "chip chip-" + chip.kind, title: (chip.kind === "include" ? "Showing only " : "Hiding ") + label },
        el("span", { text: (chip.kind === "exclude" ? "−" : "") + label }));
      node.append(el("button", { type: "button", "aria-label": "Remove filter " + label, html: icon("close", "ic-xs"),
        onclick: (event) => { event.preventDefault(); state.chips.splice(index, 1); save(); renderChips(); onChange(); } }));
      chipsNode.append(node);
    });
  }
  input.addEventListener("input", () => { state.text = input.value; onChange(); });
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      const text = input.value.trim();
      if (!text) return;
      event.preventDefault();
      const kind = text.startsWith("-") ? "exclude" : "include";
      const parsed = parseFieldTerm(kind === "exclude" ? text.slice(1) : text, fields || null);
      state.chips = withChip(state.chips, kind, parsed.term, parsed.field);
      input.value = "";
      state.text = "";
      save(); renderChips(); onChange();
    } else if (event.key === "Backspace" && !input.value && state.chips.length) {
      state.chips.pop(); save(); renderChips(); onChange();
    } else if (event.key === "Escape" && input.value) {
      event.preventDefault(); event.stopPropagation();
      input.value = ""; state.text = ""; onChange();
    }
  });
  help.addEventListener("click", (event) => {
    event.stopPropagation();
    if (!$("popover").hidden && $("popover").dataset.anchor === help.id) closePopover();
    else openPopover(help, FILTER_HELP[tab]);
  });
  renderChips();
  return {
    field, help, input,
    get chips() { return state.chips; },
    get text() { return state.text.trim().toLowerCase(); },
    get active() { return state.chips.length + (state.text.trim() ? 1 : 0); },
    addChip(kind, term, fieldName) { state.chips = withChip(state.chips, kind, term, fieldName); save(); renderChips(); onChange(); },
    clear() { state.chips = []; state.text = ""; input.value = ""; save(); renderChips(); onChange(); },
    focus() { input.focus(); input.select(); }
  };
}

// ---- App launches, shared by Network and Logs ----

let launchesById = {};
async function loadLaunches() {
  applyLaunchesTopic(await apiJSON("/api/v1/launches"));
}

function applyLaunchesTopic(payload) {
  const map = {};
  for (const launch of payload.launches || []) map[launch.launchId] = launch;
  launchesById = map;
}

function newestLaunchId() {
  const ids = Object.keys(launchesById).map(Number);
  return ids.length ? Math.max(...ids) : null;
}

// marks: [{ count, tone: "err" | "warn", one, many }] — shown after the count when non-zero.
function launchGroupHTML(launchId, items, collapsed, noun, marks) {
  const launch = launchesById[launchId];
  const time = launch ? formatClock(launch.startedAt) : "";
  const current = Number(launchId) === newestLaunchId();
  return icon(collapsed ? "chev-r" : "chev-d") +
    "<b>App launch" + (time ? " " + escapeHTML(time) : "") + "</b>" +
    (current ? '<span class="gr-now">current</span>' : "") +
    (launch && launch.pid != null ? "<span>pid " + escapeHTML(launch.pid) + "</span>" : "") +
    '<span class="gr-meta">' + plural(items.length, noun, noun + "s") +
    (marks || []).filter((mark) => mark.count).map((mark) => ' · <span class="st-' + mark.tone + '">' + plural(mark.count, mark.one, mark.many) + "</span>").join("") + "</span>";
}

// ---- No app attached: Network, Logs and State need SimTool to launch the app ----

function noAppPanel(tab) {
  const port = location.port ? " --port " + location.port : "";
  const device = deviceInfo.udid ? " --device " + deviceInfo.udid : "";
  const serveCommand = "simtool serve --app <bundle-id>" + device + port;
  const what = { network: "requests", logs: "log lines", state: "model state" }[tab];
  const node = el("div", { class: "noapp" });
  node.innerHTML = "<h2>No app attached</h2>" +
    "<p>The " + what + " come from your app, so SimTool has to launch it: that attaches the network and state loggers and scopes log capture to it. Accessibility and Tests work without an attached app.</p>";
  for (const [title, command] of [["From your project (recommended)", "simtool run --web"], ["Or restart this server for an installed app", serveCommand]]) {
    const line = el("div", { class: "cmdline" }, el("span", { class: "cmd-title", text: title }), el("code", { text: command, translate: "no" }));
    line.append(el("button", { class: "btn btn-sm", type: "button", html: icon("copy", "ic-sm") + "Copy", onclick: () => copyText(command, "Command copied") }));
    node.append(line);
  }
  return node;
}

// Guide words: the first and last time in view, how many are shown, and whether the list still moves.
function guideHTML(parts, live) {
  return parts.filter(Boolean).map((part) => "<span>" + part + "</span>").join("") + (live || "");
}

function liveTag(word, paused) {
  // A reviewed run does not move: its lists are a recording, not a capture.
  if (typeof reviewActive === "function" && reviewActive()) return '<span class="rec">◼ recorded run</span>';
  if (screenState.connection === "reconnecting" || screenState.connection === "offline") return '<span class="stale">● server unreachable — showing the last data</span>';
  if (paused) return '<span class="stale">❚❚ paused</span>';
  return '<span class="live">● ' + word + "</span>";
}
