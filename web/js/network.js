// Network: HTTP and gRPC calls the app's logger reported, grouped by app
// launch, with the selected call's detail under the list.

const network = {
  events: [],
  mockRules: {},
  protocol: stored("network.protocol", "all"),   // all | http | grpc
  failedOnly: stored("network.failed", false),
  mockedOnly: stored("network.mocked", false),
  sort: { key: "time", dir: 1 },
  paused: false,
  pausedNew: 0,
  cleared: new Set(),
  detailTab: "response",
  selected: null
};

const networkFilter = createFilter("network", {
  placeholder: "Filter name, host, status — Enter keeps it",
  onChange: () => renderNetwork()
});

// Pressed states follow the model: sync() re-reads it after a change made elsewhere.
function segmented(label, options, current, onPick) {
  const group = el("div", { class: "seg", role: "group", "aria-label": label });
  for (const [value, text] of options) {
    const button = el("button", { type: "button", "data-value": value, text });
    button.addEventListener("click", () => { onPick(value); group.sync(); });
    group.append(button);
  }
  group.sync = () => { for (const button of group.children) button.setAttribute("aria-pressed", String(current() === button.dataset.value)); };
  group.sync();
  return group;
}

function pillToggle(html, pressed, onToggle, title) {
  const button = el("button", { class: "pill", type: "button", html, title });
  button.addEventListener("click", () => { onToggle(); button.sync(); });
  button.sync = () => button.setAttribute("aria-pressed", String(pressed()));
  button.sync();
  return button;
}



const networkPause = el("button", { class: "tb-btn", type: "button", "aria-label": "Pause the list", "aria-pressed": "false", "data-tip": "Pause the list", html: icon("pause") });
const networkClear = el("button", { class: "tb-btn", type: "button", "aria-label": "Clear the list", "data-tip": "Clear the list", html: icon("trash") });

const networkProtocol = segmented("Protocol", [["all", "All"], ["http", "HTTP"], ["grpc", "gRPC"]], () => network.protocol, (value) => { network.protocol = value; store("network.protocol", value); renderNetwork(); });
const networkProblems = pillToggle(icon("warn", "ic-sm") + "Problems", () => network.failedOnly, () => { network.failedOnly = !network.failedOnly; store("network.failed", network.failedOnly); renderNetwork(); }, "Only 4xx, 5xx, failed calls and gRPC errors");
const networkMocked = pillToggle('<span class="dot dot-course"></span>Mocked', () => network.mockedOnly, () => { network.mockedOnly = !network.mockedOnly; store("network.mocked", network.mockedOnly); renderNetwork(); }, "Only calls a mock answered");
const networkView = buildListPanel("network", {
  listLabel: "Requests",
  toolbar: [networkFilter.field, networkProtocol, networkProblems, networkMocked, el("span", { class: "ptool-spacer" }), networkFilter.help, networkPause, networkClear]
});

function clearNetworkFilters() {
  network.protocol = "all"; network.failedOnly = false; network.mockedOnly = false;
  store("network.protocol", "all"); store("network.failed", false); store("network.mocked", false);
  networkProtocol.sync(); networkProblems.sync(); networkMocked.sync();
  networkFilter.clear();
}

networkPause.addEventListener("click", () => {
  network.paused = !network.paused;
  network.pausedNew = 0;
  networkPause.setAttribute("aria-pressed", String(network.paused));
  networkPause.innerHTML = icon(network.paused ? "play" : "pause");
  networkPause.dataset.tip = network.paused ? "Resume the list" : "Pause the list";
  networkPause.setAttribute("aria-label", networkPause.dataset.tip);
  renderNetwork();
  // Resuming catches up at once, not when the next request happens to arrive.
  if (!network.paused) { networkLastPayload = ""; poller.poke("network"); }
});
networkClear.addEventListener("click", () => {
  const previous = new Set(network.cleared);
  for (const event of network.events) network.cleared.add(event.id);
  networkList.select(null);
  renderNetwork();
  toast("Request list cleared", { icon: "trash", duration: 5000, action: { label: "Undo", run: () => { network.cleared = previous; renderNetwork(); } } });
});

// The logger stamps a call when it finishes; the waterfall works its start out from the duration.
const NETWORK_COLUMNS = [
  { key: "time", label: "Finished", sort: true },
  { key: "method", label: "Method", class: "c-method" },
  { key: "name", label: "Name", sort: true },
  { key: "status", label: "Status", sort: true },
  { key: "size", label: "Size", sort: true, class: "num c-size", defaultDir: -1 },
  { key: "duration", label: "Duration", sort: true, class: "num", defaultDir: -1 },
  { key: "wf", label: "Waterfall", class: "c-wf" }
];

const networkList = createList(networkView.list, {
  header: createSortHeader("net-grid", NETWORK_COLUMNS, network.sort, () => renderNetwork()),
  key: (event) => event.id,
  version: (event) => [event.response ? 1 : 0, event.error ? 1 : 0, event.launchId, event.durationMilliseconds, event._wf, newestLaunchId() === event.launchId].join("|"),
  rowClass: (event) => "net-grid" + (event.mocked ? " mocked" : "") + (event.launchId != null && event.launchId !== newestLaunchId() ? " retired" : ""),
  group: (event) => event.launchId != null ? String(event.launchId) : null,
  collapsed: [],
  renderGroup: (id, items, collapsed) => launchGroupHTML(id, items, collapsed, "request", networkMarks(items)),
  render: renderNetworkRow,
  empty: () => networkEmpty(),
  onSelect: (key, event) => { network.selected = event; renderNetworkDetail(); },
  exists: (key) => !network.cleared.has(key) && network.events.some((event) => event.id === key),
  onActivate: () => { const tab = networkView.detail.querySelector("[role=tab][aria-selected=true]"); if (tab) tab.focus(); },
  onMenu: (key, event, x, y, row) => openMenu(x, y, networkRowMenu(event), row),
  onGroupMenu: (id, x, y, button) => openMenu(x, y, launchGroupMenu("network", id), button),
  follow: true
});

function renderNetworkRow(event, row) {
  const status = networkStatus(event);
  const where = requestWhere(event);
  row.innerHTML =
    '<span class="cell time">' + escapeHTML(formatClock(event.timestamp, true)) + "</span>" +
    '<span class="cell method c-method ' + escapeHTML(event.protocol) + '">' + escapeHTML(event.protocol === "grpc" ? "gRPC" : (event.request && event.request.method) || "") + "</span>" +
    '<span class="cell name" translate="no"><b>' + escapeHTML(requestName(event)) + "</b>" +
      (event.mocked ? '<span class="tag tag-course" title="' + escapeHTML(event.mockRuleId ? "Answered by mock " + event.mockRuleId : "Answered by a mock") + '">Mock</span>' : "") +
      "<span>" + escapeHTML(where) + "</span></span>" +
    '<span class="cell"><span class="st st-' + status.severity + '" title="' + escapeHTML(status.title) + '">' + (status.severity === "err" ? icon("warn") : "") + escapeHTML(status.text) + "</span></span>" +
    '<span class="cell num c-size">' + escapeHTML(formatBytes(networkSize(event))) + "</span>" +
    '<span class="cell num">' + escapeHTML(formatDuration(event.durationMilliseconds)) + "</span>" +
    '<span class="cell c-wf"><span class="wf"><i class="' + status.severity + '" style="' + (event._wf || "") + '"></i></span></span>';
  row.title = (event.request && (event.request.method || "")) + " " + requestPath(event);
}

function networkEmpty() {
  if (!inspector.attachedApp && inspector.configKnown && !network.events.length) return noAppPanel("network");
  if (network.events.length && network.events.every((event) => network.cleared.has(event.id))) {
    return el("div", { class: "empty", html: "<b>Cleared</b>New requests appear here as the app makes them." });
  }
  if (network.events.length) {
    const node = el("div", { class: "empty", html: "<b>No request matches</b>The filters above hide all " + formatCount(network.events.length) + ". " });
    node.append(el("button", { class: "btn btn-sm", type: "button", text: "Clear filters", onclick: clearNetworkFilters }));
    return node;
  }
  return el("div", { class: "empty", html: "<b>No requests yet</b>The app's network logger reports each call here as it finishes. Apps launched by <code>simtool run</code> or <code>simtool app launch</code> have it armed; apps that link <code>SimToolNetworkLogger</code> keep reporting after a relaunch." });
}

function networkVisible() {
  const query = networkFilter.text;
  const chips = networkFilter.chips;
  return network.events.filter((event) => {
    if (network.cleared.has(event.id)) return false;
    if (network.protocol !== "all" && event.protocol !== network.protocol) return false;
    if (network.failedOnly && !isNetworkProblem(event)) return false;
    if (network.mockedOnly && !event.mocked) return false;
    return (!query && !chips.length) || matchesFilters(networkHaystack(event), chips, query);
  });
}

function networkSortValue(event, key) {
  switch (key) {
    case "name": return requestName(event).toLowerCase();
    case "status": { const status = networkStatus(event); return (status.severity === "err" ? 3 : status.severity === "warn" ? 2 : status.severity === "info" ? 1 : 0) * 1000 + (Number(status.code) || 0); }
    case "size": return networkSize(event) || 0;
    case "duration": return event.durationMilliseconds || 0;
    default: return Date.parse(event.timestamp) || 0;
  }
}

function renderNetwork() {
  const rows = networkVisible();
  // Grouped by launch, oldest launch first; within a launch, by the chosen column.
  rows.sort((a, b) => ((a.launchId ?? -1) - (b.launchId ?? -1)) || compareBy(a, b));
  function compareBy(a, b) {
    const left = networkSortValue(a, network.sort.key), right = networkSortValue(b, network.sort.key);
    return (left < right ? -1 : left > right ? 1 : 0) * network.sort.dir || ((Date.parse(a.timestamp) || 0) - (Date.parse(b.timestamp) || 0));
  }
  // Waterfall: each call's start and length inside its launch's span.
  const spans = {};
  for (const event of rows) {
    const start = Date.parse(event.timestamp) - (event.durationMilliseconds || 0);
    const end = Date.parse(event.timestamp);
    const span = spans[event.launchId] || (spans[event.launchId] = { start, end });
    span.start = Math.min(span.start, start);
    span.end = Math.max(span.end, end);
  }
  for (const event of rows) {
    const span = spans[event.launchId];
    const total = Math.max(1, span.end - span.start);
    const left = ((Date.parse(event.timestamp) - (event.durationMilliseconds || 0) - span.start) / total) * 100;
    const width = Math.max(1.5, ((event.durationMilliseconds || 0) / total) * 100);
    event._wf = "left:" + left.toFixed(1) + "%;width:" + Math.min(width, 100 - left).toFixed(1) + "%";
  }
  networkList.update(rows);
  const shown = rows.length, total = network.events.filter((event) => !network.cleared.has(event.id)).length;
  const times = rows.map((event) => event.timestamp).filter(Boolean).sort();
  const hidden = total - shown;
  networkView.guide.innerHTML = guideHTML([
    times.length ? "<b>" + escapeHTML(formatClock(times[0], true)) + " → " + escapeHTML(formatClock(times[times.length - 1], true)) + "</b>" : "",
    formatCount(shown) + " of " + plural(total, "request", "requests"),
    hidden ? formatCount(hidden) + " hidden by filters" : "",
    network.paused && network.pausedNew ? plural(network.pausedNew, "new while paused", "new while paused") : ""
  ], liveTag("capturing", network.paused));
  const [failed, problems] = networkMarks(network.events.filter((event) => !network.cleared.has(event.id)));
  setCount("network", total, failed.count, problems.count);
  if (network.selected) {
    const fresh = network.events.find((event) => event.id === network.selected.id);
    if (fresh && fresh !== network.selected) { network.selected = fresh; renderNetworkDetail(); }
  }
}

function networkRowMenu(event) {
  const path = chipPathForEvent(event);
  const short = path.length > 48 ? "…" + path.slice(-47) : path;
  const body = event.response && event.response.bodyPreview;
  return [
    { icon: "copy", label: event.protocol === "grpc" ? "Copy method path" : "Copy URL", run: () => copyText(requestPath(event), "Copied") },
    { icon: "terminal", label: event.protocol === "grpc" ? "Copy as grpcurl" : "Copy as cURL", run: () => copyText(event.protocol === "grpc" ? grpcurlCommand(event) : curlCommand(event), "Copied as " + (event.protocol === "grpc" ? "grpcurl" : "cURL")) },
    { icon: "copy", label: "Copy response body", disabled: !body, run: () => copyText(body, "Response body copied") },
    { icon: "mock", label: "Copy as YAML mock", tone: "course", run: () => copyText(mockYaml(event), "Mock copied — paste it into a test's mocks:") },
    "-",
    { icon: "filter", label: "Show only “" + short + "”", disabled: !path, run: () => networkFilter.addChip("include", path) },
    { icon: "close", label: "Hide “" + short + "”", disabled: !path, run: () => networkFilter.addChip("exclude", path) }
  ];
}

function launchGroupMenu(kind, launchId) {
  const list = kind === "network" ? networkList : logsList;
  const launch = launchesById[launchId];
  const what = kind === "network" ? "requests" : "log lines";
  return [
    { icon: "chev-d", label: "Collapse or expand", run: () => list.toggleGroup(launchId) },
    "-",
    { icon: "trash", label: "Delete this launch's " + what + "…", tone: "danger", run: async () => {
      const when = launch ? " from " + formatClock(launch.startedAt) + (launch.pid != null ? " (pid " + launch.pid + ")" : "") : "";
      if (!(await confirmDestructive("Delete " + what + "?", "The " + what + " of the app launch" + when + " are removed from this server for everyone viewing it.", "Delete"))) return;
      try {
        await api("/api/v1/" + (kind === "network" ? "network" : "logs") + "/launches/" + encodeURIComponent(launchId), { method: "DELETE" });
        if (kind === "network") { network.events = network.events.filter((event) => String(event.launchId) !== String(launchId)); renderNetwork(); }
        else { logs.entries = logs.entries.filter((entry) => String(entry.launchId) !== String(launchId)); renderLogs(); }
        toast("Deleted", { icon: "trash" });
      } catch (error) {
        fail("Delete failed", error);
      }
    } }
  ];
}

// ---- Detail ----

function renderNetworkDetail() {
  const event = network.selected;
  showDetail(networkView.panel, !!event);
  if (!event) return;
  const status = networkStatus(event);
  const request = event.request || {};
  const response = event.response || null;
  const grpc = event.protocol === "grpc";
  const tabs = [["headers", "Headers"], ["request", "Request"], ["response", "Response"]].concat(event.mocked ? [["mock", "Mock rule"]] : []);
  if (!tabs.some(([key]) => key === network.detailTab)) network.detailTab = "response";
  let body = "";
  if (status.severity === "err" || status.severity === "warn") {
    const headline = event.error ? "Request failed" : grpc ? "gRPC " + (response && response.grpcStatusCode) + " " + status.text : "HTTP " + status.text;
    const detail = event.error ? event.error.message : grpc ? (response && response.grpcStatusMessage) || "" : "";
    body += '<div class="callout ' + status.severity + '">' + icon("warn") + "<div><b>" + escapeHTML(headline) + "</b>" + (detail ? "<br>" + escapeHTML(detail) : "") + "</div></div>";
  }
  if (event.mocked) {
    body += '<div class="callout course">' + icon("mock") + "<div>Answered by mock <b class=\"mono\">" + escapeHTML(event.mockRuleId || "") + "</b>. The app never reached the server.</div></div>";
  }
  if (network.detailTab === "headers") {
    body += '<div class="sec">General</div>' + kvHTML({
      [grpc ? "Method" : "URL"]: requestPath(event),
      ...(grpc ? { Authority: request.grpcAuthority } : { "HTTP method": request.method, Host: request.host }),
      Status: status.title,
      Started: event.timestamp ? formatClock(new Date(Date.parse(event.timestamp) - (event.durationMilliseconds || 0)), true) : "",
      Finished: event.timestamp ? formatClock(event.timestamp, true) + " (" + new Date(event.timestamp).toISOString() + ")" : "",
      Duration: formatDuration(event.durationMilliseconds),
      App: event.appBundleID,
      Launch: event.launchId != null && launchesById[event.launchId] ? "pid " + launchesById[event.launchId].pid : ""
    }) +
      '<div class="sec">Request ' + (grpc ? "metadata" : "headers") + "</div>" + kvHTML(grpc ? request.metadata : request.headers) +
      '<div class="sec">Response ' + (grpc ? "metadata" : "headers") + "</div>" + (response ? kvHTML(grpc ? response.metadata : response.headers) : '<p class="muted small">No response</p>');
  } else if (network.detailTab === "request") {
    const size = grpc ? request.messageByteCount : request.bodyByteCount;
    body += (size != null ? '<p class="muted small">' + escapeHTML(formatBytes(size)) + (request.bodyPreview && size > request.bodyPreview.length ? " — preview shown" : "") + "</p>" : "") +
      '<pre class="code" translate="no">' + highlightJSON(request.bodyPreview) + "</pre>";
  } else if (network.detailTab === "response") {
    if (!response) body += '<p class="muted">No response — the request did not complete.</p>';
    else {
      const size = networkSize(event);
      body += (size != null ? '<p class="muted small">' + escapeHTML(formatBytes(size)) + (response.bodyPreview && size > response.bodyPreview.length ? " — preview shown" : "") + "</p>" : "") +
        '<pre class="code" translate="no">' + (response.bodyPreview ? highlightJSON(response.bodyPreview) : '<span class="muted">' + (event.mocked ? "The mock returned no body" : "No body") + "</span>") + "</pre>";
    }
  } else if (network.detailTab === "mock") {
    const rule = event.mockRuleId ? network.mockRules[event.mockRuleId] : null;
    body += rule ? '<pre class="code" translate="no">' + highlightJSON(JSON.stringify(rule)) + "</pre>" : '<p class="muted">The rule ' + escapeHTML(event.mockRuleId || "") + " is no longer active on this server.</p>";
  }
  // Polling hands over fresh objects every time; the pane changes only with what it shows.
  patchPane(networkView.detail, event.id + "|" + network.detailTab,
    '<div class="dhead"><span class="method ' + escapeHTML(event.protocol) + '">' + (grpc ? "gRPC" : escapeHTML(request.method || "")) + "</span>" +
      '<span class="dtitle" translate="no" title="' + escapeHTML(requestPath(event)) + '">' + escapeHTML(requestPath(event)) + "</span>" +
      '<div class="dactions">' +
        '<button class="btn btn-sm" type="button" data-act="curl">' + icon("terminal", "ic-sm") + "Copy as " + (grpc ? "grpcurl" : "cURL") + "</button>" +
        '<button class="btn btn-sm btn-course" type="button" data-act="mock" title="A mocks: entry for a YAML test that answers this call the same way">' + icon("mock", "ic-sm") + "Copy as YAML mock</button>" +
        '<button class="tb-btn" type="button" data-act="close" aria-label="Close the details">' + icon("close") + "</button>" +
      "</div></div>" +
    '<div class="dmeta"><span class="st st-' + status.severity + '">' + (status.severity === "err" ? icon("warn") : "") + escapeHTML(status.text) + "</span>" +
      "<span>Duration <span class=\"mono\">" + escapeHTML(formatDuration(event.durationMilliseconds)) + "</span></span>" +
      "<span>Size <span class=\"mono\">" + escapeHTML(formatBytes(networkSize(event))) + "</span></span>" +
      "<span>" + escapeHTML(formatClock(event.timestamp, true)) + "</span></div>" +
    '<div class="dtabs" role="tablist" aria-label="Request details">' + tabs.map(([key, label]) =>
      '<button type="button" role="tab" data-dtab="' + key + '" aria-selected="' + (network.detailTab === key) + '" tabindex="' + (network.detailTab === key ? 0 : -1) + '">' + label + "</button>").join("") + "</div>" +
    '<div class="dbody" role="tabpanel">' + body + "</div>");
}

networkView.detail.addEventListener("click", (domEvent) => {
  const tab = domEvent.target.closest("[data-dtab]");
  if (tab) { network.detailTab = tab.dataset.dtab; renderNetworkDetail(); networkView.detail.querySelector('[data-dtab="' + network.detailTab + '"]').focus(); return; }
  const action = domEvent.target.closest("[data-act]");
  if (!action || !network.selected) return;
  const event = network.selected;
  if (action.dataset.act === "curl") copyText(event.protocol === "grpc" ? grpcurlCommand(event) : curlCommand(event), "Copied as " + (event.protocol === "grpc" ? "grpcurl" : "cURL"));
  if (action.dataset.act === "mock") copyText(mockYaml(event), "Mock copied — paste it into a test's mocks:");
  if (action.dataset.act === "close") { networkList.select(null); networkList.focus(); }
});
networkView.detail.addEventListener("keydown", (domEvent) => {
  const tab = domEvent.target.closest("[data-dtab]");
  if (!tab || !["ArrowLeft", "ArrowRight"].includes(domEvent.key)) return;
  const tabs = [...networkView.detail.querySelectorAll("[data-dtab]")];
  const next = tabs[(tabs.indexOf(tab) + (domEvent.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
  network.detailTab = next.dataset.dtab;
  renderNetworkDetail();
  networkView.detail.querySelector('[data-dtab="' + network.detailTab + '"]').focus();
  domEvent.preventDefault();
});

// ---- Polling ----

let networkLastPayload = "";
async function loadNetwork() {
  await loadLaunches();
  const payload = await apiJSON("/api/v1/network/events?limit=1000");
  const events = payload.events || [];
  const serialized = events.length + ":" + (events.length ? events[events.length - 1].id + (events[events.length - 1].response ? "r" : "") : "") + ":" + Object.keys(launchesById).length;
  try {
    const mocks = await apiJSON("/api/v1/mocks");
    const map = {};
    for (const rule of mocks.rules || []) map[rule.id] = rule;
    network.mockRules = map;
  } catch (_) { /* keep the last known rules */ }
  if (serialized === networkLastPayload) return;
  networkLastPayload = serialized;
  if (network.paused) {
    const known = new Set(network.events.map((event) => event.id));
    network.pausedNew = events.filter((event) => !known.has(event.id)).length;
    renderNetwork();
    return;
  }
  network.events = events;
  renderNetwork();
}

tabHandlers.network = { show() { renderNetwork(); poller.poke("network"); } };

function resetNetwork() {
  network.events = [];
  network.cleared.clear();
  networkLastPayload = "";
  networkList.select(null);
  renderNetwork();
}
