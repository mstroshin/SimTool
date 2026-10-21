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
  split: stored("network.split", false),          // Request and Response side by side
  bodyView: stored("network.bodyView", "tree"),  // tree | raw
  sections: stored("network.sections", {}),      // a detail section's name → open
  folds: new Map(),                              // a body node's place → open, as a person left it
  openedFor: "",                                 // the call and term the detail last opened at a hit
  selected: null
};

const networkFilter = createFilter("network", {
  placeholder: "Search URL, method, status, headers, bodies — Enter keeps it",
  fields: NETWORK_FILTER_FIELDS,
  onChange: () => { renderNetwork(); renderNetworkDetail(); }
});

// What a search reads in a call, made once per call object the server sent.
const networkSearchCache = new WeakMap();
function searchFieldsOf(event) {
  let fields = networkSearchCache.get(event);
  if (!fields) {
    fields = networkSearchFields(event);
    fields.all = [fields.url, fields.method, fields.status, fields.host, fields.header, fields.body, fields.mock].join("\n");
    networkSearchCache.set(event, fields);
  }
  return fields;
}

// The live search: its text and the field it names, if any.
function networkQuery() {
  return parseFieldTerm(networkFilter.text, NETWORK_FILTER_FIELDS);
}

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
  // Resuming catches up at once, not when the next request happens to arrive.
  if (!network.paused) { network.events = networkHeard; networkLastPayload = ""; refreshInspector("network"); }
  renderNetwork();
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
  version: (event) => [event.response ? 1 : 0, event.error ? 1 : 0, event.launchId, event.durationMilliseconds, event._wf, newestLaunchId() === event.launchId, networkFilter.text].join("|"),
  // A reviewed run is one launch's story: no launch groups, nothing reads as earlier.
  rowClass: (event) => "net-grid" + (event.mocked ? " mocked" : "") + (!reviewActive() && event.launchId != null && event.launchId !== newestLaunchId() ? " retired" : ""),
  group: (event) => !reviewActive() && event.launchId != null ? String(event.launchId) : null,
  collapsed: [],
  renderGroup: (id, items, collapsed) => launchGroupHTML(id, items, collapsed, "request", networkMarks(items)),
  render: renderNetworkRow,
  empty: () => networkEmpty(),
  onSelect: (key, event) => { network.selected = event; renderNetworkDetail(); },
  exists: (key) => networkRows().some((event) => event.id === key),
  onActivate: () => { const tab = networkView.detail.querySelector("[role=tab][aria-selected=true]"); if (tab) tab.focus(); },
  onMenu: (key, event, x, y, row) => openMenu(x, y, networkRowMenu(event), row),
  onGroupMenu: (id, x, y, button) => openMenu(x, y, launchGroupMenu("network", id), button),
  follow: true
});

function renderNetworkRow(event, row) {
  const status = networkStatus(event);
  const where = requestWhere(event);
  // The search marks what the row shows, and names where else it found the term.
  const query = networkQuery();
  const shown = !query.field || query.field === "url" || query.field === "host" ? query.term : "";
  const hits = query.term ? networkHits(searchFieldsOf(event), query.term, query.field) : [];
  const elsewhere = hits.length && !hits.some((hit) => hit === "url" || hit === "host") ? hits.filter((hit) => /header|body/.test(hit)) : [];
  row.innerHTML =
    '<span class="cell time">' + escapeHTML(formatClock(event.timestamp, true)) + "</span>" +
    '<span class="cell method c-method ' + escapeHTML(event.protocol) + '">' + escapeHTML(event.protocol === "grpc" ? "gRPC" : (event.request && event.request.method) || "") + "</span>" +
    '<span class="cell name" translate="no"><b>' + markHTML(requestName(event), shown) + "</b>" +
      (event.mocked ? '<span class="tag tag-course" title="' + escapeHTML(event.mockRuleId ? "Answered by mock " + event.mockRuleId : "Answered by a mock") + '">Mock</span>' : "") +
      (elsewhere.length ? '<span class="tag tag-hit" title="' + escapeHTML("Found in the " + elsewhere.join(", ")) + '">' + escapeHTML(elsewhere[0]) + "</span>" : "") +
      "<span>" + markHTML(where, shown) + "</span></span>" +
    '<span class="cell"><span class="st st-' + status.severity + '" title="' + escapeHTML(status.title) + '">' + (status.severity === "err" ? icon("warn") : "") + escapeHTML(status.text) + "</span></span>" +
    '<span class="cell num c-size">' + escapeHTML(formatBytes(networkSize(event))) + "</span>" +
    '<span class="cell num">' + escapeHTML(formatDuration(event.durationMilliseconds)) + "</span>" +
    '<span class="cell c-wf"><span class="wf"><i class="' + status.severity + '" style="' + (event._wf || "") + '"></i></span></span>';
  row.title = (event.request && (event.request.method || "")) + " " + requestPath(event);
}

function networkEmpty() {
  if (reviewActive()) return reviewEmpty("network");
  if (!inspector.attachedApp && inspector.configKnown && !network.events.length) return noAppPanel("network");
  if (network.events.length && network.events.every((event) => network.cleared.has(event.id))) {
    return el("div", { class: "empty", html: "<b>Cleared</b>New requests appear here as the app makes them." });
  }
  if (network.events.length) {
    const node = el("div", { class: "empty", html: "<b>No request matches</b>The filters above hide all " + formatCount(network.events.length) + ". " });
    node.append(el("button", { class: "btn btn-sm", type: "button", text: "Clear filters", onclick: clearNetworkFilters }));
    return node;
  }
  return el("div", { class: "empty", html: "<b>No requests yet</b>The app's network logger reports each call here as it finishes. Apps launched by <code>simtool run</code>, by a <code>simtool serve --app</code> server or by <code>simtool app launch</code> with its <code>--env</code> have it armed; apps that link <code>SimToolNetworkLogger</code> keep reporting after a relaunch." });
}

// The requests the list is about: the live ones not cleared, or the reviewed run's in its window.
function networkRows() {
  return reviewActive() ? reviewRows("network", network.events) : network.events.filter((event) => !network.cleared.has(event.id));
}

function networkVisible() {
  const query = networkQuery();
  const chips = networkFilter.chips;
  return networkRows().filter((event) => {
    if (network.protocol !== "all" && event.protocol !== network.protocol) return false;
    if (network.failedOnly && !isNetworkProblem(event)) return false;
    if (network.mockedOnly && !event.mocked) return false;
    if (!query.term && !chips.length) return true;
    const fields = searchFieldsOf(event);
    return matchesFilters(fields.all, chips, query.term, fields, query.field);
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
  const all = networkRows();
  const shown = rows.length, total = all.length;
  const times = rows.map((event) => event.timestamp).filter(Boolean).sort();
  const hidden = total - shown;
  networkView.guide.innerHTML = guideHTML([
    times.length ? "<b>" + escapeHTML(formatClock(times[0], true)) + " → " + escapeHTML(formatClock(times[times.length - 1], true)) + "</b>" : "",
    formatCount(shown) + " of " + plural(total, "request", "requests"),
    hidden ? formatCount(hidden) + " hidden by filters" : "",
    network.paused && network.pausedNew ? plural(network.pausedNew, "new while paused", "new while paused") : ""
  ], liveTag("capturing", network.paused));
  const [failed, problems] = networkMarks(all);
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
// Request and Response, as tabs or side by side: each with its headers or
// metadata and its body — JSON or protobuf text as a tree that folds, or as
// raw text — and the Response with its status. A search marks what it found
// and opens the side it is on.

function renderNetworkDetail() {
  const event = network.selected;
  showDetail(networkView.panel, !!event);
  if (!event) return;
  const grpc = event.protocol === "grpc";
  const request = event.request || {};
  const query = networkQuery();
  const hits = query.term ? networkHits(searchFieldsOf(event), query.term, query.field) : [];
  // A search opens the side it found the term on — once, so a tab picked afterwards stays.
  const opened = event.id + "|" + query.term;
  if (network.openedFor !== opened) networkMatchIndex = -1;
  if (hits.length && network.openedFor !== opened) {
    const side = hits.find((hit) => /^(request|response) /.test(hit));
    if (side && !network.split) network.detailTab = side.split(" ")[0];
  }
  network.openedFor = opened;
  const tabs = [["request", "Request"], ["response", "Response"]].concat(event.mocked && !network.split ? [["mock", "Mock rule"]] : []);
  if (!tabs.some(([key]) => key === network.detailTab)) network.detailTab = "response";
  const needle = query.term;
  let body;
  if (network.split) {
    body = '<div class="net-split"><section class="net-side" aria-label="Request"><h3 class="side-title">Request</h3>' + requestSideHTML(event, needle, query.field) + "</section>" +
      '<section class="net-side" aria-label="Response"><h3 class="side-title">Response</h3>' + responseSideHTML(event, needle, query.field) + (event.mocked ? mockSectionHTML(event) : "") + "</section></div>";
  } else if (network.detailTab === "request") {
    body = requestSideHTML(event, needle, query.field);
  } else if (network.detailTab === "mock") {
    body = mockSectionHTML(event);
  } else {
    body = responseSideHTML(event, needle, query.field);
  }
  const status = networkStatus(event);
  const statusText = grpc ? status.text : status.code ? status.code + " " + httpStatusText(status.code) : status.text;
  const sizes = [grpc ? request.messageByteCount : request.bodyByteCount, networkSize(event)];
  const started = event.timestamp ? new Date(Date.parse(event.timestamp) - (event.durationMilliseconds || 0)) : null;
  // Polling hands over fresh objects every time; the pane changes only with what it shows.
  patchPane(networkView.detail, event.id + "|" + (network.split ? "split" : network.detailTab),
    '<div class="dhead"><span class="method ' + escapeHTML(event.protocol) + '">' + (grpc ? "gRPC" : escapeHTML(request.method || "")) + "</span>" +
      '<span class="dtitle" translate="no" title="' + escapeHTML(requestPath(event)) + '">' + markHTML(requestPath(event), !query.field || query.field === "url" ? needle : "") + "</span>" +
      '<div class="dactions">' +
        '<button class="btn btn-sm" type="button" data-act="curl">' + icon("terminal", "ic-sm") + "Copy as " + (grpc ? "grpcurl" : "cURL") + "</button>" +
        '<button class="btn btn-sm btn-course" type="button" data-act="mock" title="A mocks: entry for a YAML test that answers this call the same way">' + icon("mock", "ic-sm") + "Copy as YAML mock</button>" +
        '<button class="tb-btn" type="button" data-act="close" aria-label="Close the details">' + icon("close") + "</button>" +
      "</div></div>" +
    '<div class="dmeta"><span class="st st-' + status.severity + '" title="' + escapeHTML(status.title) + '">' + (status.severity === "err" ? icon("warn") : "") + escapeHTML(statusText) + "</span>" +
      "<span>Duration <span class=\"mono\">" + escapeHTML(formatDuration(event.durationMilliseconds)) + "</span></span>" +
      "<span>Sent <span class=\"mono\">" + escapeHTML(formatBytes(sizes[0])) + "</span> · received <span class=\"mono\">" + escapeHTML(formatBytes(sizes[1])) + "</span></span>" +
      "<span class=\"mono\">" + escapeHTML(started ? formatClock(started, true) + " → " + formatClock(event.timestamp, true) : formatClock(event.timestamp, true)) + "</span>" +
      (event.mocked ? '<span class="tag tag-course">Mock</span>' : "") +
      (hits.length ? '<span class="hits">Found in the ' + escapeHTML(hits.join(", ")) + "</span>" : "") + "</div>" +
    '<div class="dbar">' +
      (network.split ? "" : '<div class="dtabs" role="tablist" aria-label="Request details">' + tabs.map(([key, label]) =>
        '<button type="button" role="tab" data-dtab="' + key + '" aria-selected="' + (network.detailTab === key) + '" tabindex="' + (network.detailTab === key ? 0 : -1) + '">' + label + "</button>").join("") + "</div>") +
      '<div class="dbar-tools">' +
        (needle ? '<span class="match-nav"><span class="match-count" data-match-count></span>' +
          '<button class="tb-btn" type="button" data-act="prev-match" aria-label="Previous match" data-tip="Previous match">' + icon("chev-u") + "</button>" +
          '<button class="tb-btn" type="button" data-act="next-match" aria-label="Next match" data-tip="Next match">' + icon("chev-d") + "</button></span>" : "") +
        '<span class="seg" role="group" aria-label="Bodies as"><button type="button" data-act="view-tree" aria-pressed="' + (network.bodyView === "tree") + '">Tree</button><button type="button" data-act="view-raw" aria-pressed="' + (network.bodyView === "raw") + '">Raw</button></span>' +
        '<button class="pill" type="button" data-act="split" aria-pressed="' + network.split + '" title="Show the request and the response side by side">' + icon("panel", "ic-sm") + "Side by side</button>" +
      "</div></div>" +
    '<div class="dbody" role="' + (network.split ? "region" : "tabpanel") + '" aria-label="' + (network.split ? "Request and response" : escapeHTML(network.detailTab)) + '">' + body + "</div>");
  countMatches();
}

function requestSideHTML(event, needle, field) {
  const grpc = event.protocol === "grpc";
  const request = event.request || {};
  const marks = (name) => !field || field === name ? needle : "";
  let html = sectionHTML("request.general", "General", null, kvTableHTML(grpc ? [
    ["Service", request.grpcService], ["Method", request.grpcMethod], ["Authority", request.grpcAuthority || request.host], ["Path", request.path]
  ] : [
    ["Method", request.method], ["URL", request.url || request.path], ["Host", request.host]
  ], marks("url")));
  const params = grpc ? [] : queryParams(request.url || request.path);
  if (params.length) html += sectionHTML("request.query", "Query", params.length, kvTableHTML(params, marks("url")));
  html += sectionHTML("request.body", grpc ? "Message" : "Body", null, bodyHTML(event, "request", request.bodyPreview, grpc ? request.messageByteCount : request.bodyByteCount, headerValue(request.headers, "content-type"), marks("body")));
  const headers = Object.entries((grpc ? request.metadata : request.headers) || {});
  html += sectionHTML("request.headers", grpc ? "Metadata" : "Headers", headers.length, headers.length ? kvTableHTML(headers, marks("header")) : '<p class="muted small">None</p>');
  return html;
}

function responseSideHTML(event, needle, field) {
  const grpc = event.protocol === "grpc";
  const response = event.response || null;
  const status = networkStatus(event);
  const marks = (name) => !field || field === name ? needle : "";
  let html = "";
  if (status.severity === "err" || status.severity === "warn") {
    const headline = event.error ? "Request failed" : grpc ? "gRPC " + (response && response.grpcStatusCode) + " " + status.text : "HTTP " + status.text + " " + httpStatusText(status.code);
    const detail = event.error ? event.error.message : grpc ? (response && response.grpcStatusMessage) || "" : "";
    html += '<div class="callout ' + status.severity + '">' + icon("warn") + "<div><b>" + escapeHTML(headline) + "</b>" + (detail ? "<br>" + markHTML(detail, marks("status")) : "") + "</div></div>";
  }
  if (event.mocked) {
    html += '<div class="callout course">' + icon("mock") + "<div>Answered by mock <b class=\"mono\">" + escapeHTML(event.mockRuleId || "") + "</b>. The app never reached the server.</div></div>";
  }
  if (!response) return html + '<p class="muted">No response — the request did not complete.</p>';
  // Status, duration and size head the pane; the body comes first here.
  html += sectionHTML("response.body", grpc ? "Message" : "Body", null, bodyHTML(event, "response", response.bodyPreview, networkSize(event), headerValue(response.headers, "content-type"), marks("body")));
  const headers = Object.entries((grpc ? response.metadata : response.headers) || {});
  html += sectionHTML("response.headers", grpc ? "Metadata" : "Headers", headers.length, headers.length ? kvTableHTML(headers, marks("header")) : '<p class="muted small">None</p>');
  return html;
}

function mockSectionHTML(event) {
  const rule = event.mockRuleId ? network.mockRules[event.mockRuleId] : null;
  return sectionHTML("mock.rule", "Mock rule", null, rule ? '<pre class="code" translate="no">' + highlightJSON(JSON.stringify(rule)) + "</pre>" : '<p class="muted">The rule ' + escapeHTML(event.mockRuleId || "") + " is no longer active on this server.</p>");
}

function headerValue(headers, name) {
  const match = Object.entries(headers || {}).find(([key]) => key.toLowerCase() === name);
  return match ? match[1] : "";
}

// A section that folds; it stays as a person left it, for every call.
function sectionHTML(name, title, count, content) {
  const open = network.sections[name] !== false;
  return '<details class="dsec" data-sec="' + name + '"' + (open ? " open" : "") + "><summary>" + escapeHTML(title) + (count != null ? ' <span class="count">' + formatCount(count) + "</span>" : "") + "</summary>" + content + "</details>";
}

function kvTableHTML(pairs, needle) {
  const rows = pairs.filter(([, value]) => value != null && value !== "");
  if (!rows.length) return '<p class="muted small">None</p>';
  return '<table class="hdr" translate="no"><tbody>' + rows.map(([key, value]) => "<tr><th>" + markHTML(key, needle) + "</th><td>" + markHTML(value, needle) + "</td></tr>").join("") + "</tbody></table>";
}

// A body as a tree or as text, with what it is and how much of it the logger kept.
function bodyHTML(event, side, text, byteCount, contentType, needle) {
  if (!text) return '<p class="muted small">' + (side === "response" && event.mocked ? "The mock returned no body" : "No body") + (byteCount ? " preview — " + escapeHTML(formatBytes(byteCount)) + " sent" : "") + "</p>";
  const parsed = parseBodyTree(text);
  const format = { json: "JSON", proto: "Protobuf text", text: contentType ? contentType.split(";")[0] : "Text" }[parsed.format] || "Text";
  const cut = !parsed.complete || (parsed.format === "text" && event.protocol !== "grpc" && byteCount != null && byteCount > text.length);
  const meta = [format, byteCount != null ? formatBytes(byteCount) + (event.protocol === "grpc" ? " on the wire" : "") : "", cut ? "preview — cut off by the app's logger" : ""].filter(Boolean).join(" · ");
  const tree = parsed.root && network.bodyView === "tree";
  const place = event.id + "|" + side;
  let content;
  if (tree) {
    const openDepth = treeSize(parsed.root) <= 200 ? Infinity : 2;
    const root = parsed.root;
    content = '<div class="jt" translate="no">' + (root.typeName ? '<div class="jt-type">' + markHTML(root.typeName, needle) + "</div>" : "") +
      (root.kind === "value" ? treeNodeHTML(root, "0", 0, { place, needle, openDepth }) : root.children.map((child, index) => treeNodeHTML(child, String(index), 0, { place, needle, openDepth })).join("")) +
      (cut ? '<div class="jt-cut">… the preview ends here</div>' : "") + "</div>";
  } else {
    content = '<pre class="code" translate="no">' + (needle ? markHTML(prettyBody(parsed, text), needle) : parsed.format === "json" ? highlightJSON(text) : escapeHTML(text)) + "</pre>";
  }
  return '<div class="body-bar"><span class="body-meta">' + escapeHTML(meta) + '</span><span class="body-actions">' +
    (tree ? '<button class="btn btn-sm" type="button" data-act="expand" data-side="' + side + '">Expand all</button><button class="btn btn-sm" type="button" data-act="collapse" data-side="' + side + '">Collapse all</button>' : "") +
    '<button class="btn btn-sm" type="button" data-act="copy-body" data-side="' + side + '">' + icon("copy", "ic-sm") + "Copy</button></span></div>" +
    '<div class="body-view" data-side="' + side + '">' + content + "</div>";
}

function prettyBody(parsed, text) {
  if (parsed.format === "json") { try { return JSON.stringify(JSON.parse(text), null, 2); } catch (_) { return text; } }
  return text;
}

function treeHasNeedle(node, needle) {
  if ((node.key && node.key.toLowerCase().includes(needle)) || (node.text && node.text.toLowerCase().includes(needle))) return true;
  return (node.children || []).some((child) => treeHasNeedle(child, needle));
}

// One node: a value on its row; a message, object or array folding its children,
// open as a person left it, else around a search hit, else near the top.
function treeNodeHTML(node, path, depth, context) {
  const key = node.key == null ? "" : '<span class="jt-key">' + markHTML(node.key, context.needle) + '</span><span class="jt-colon">' + (node.kind === "message" ? " " : ": ") + "</span>";
  if (node.kind === "value") {
    return '<div class="jt-row">' + key + '<span class="j-' + node.type + '">' + markHTML(node.text, context.needle) + "</span></div>";
  }
  const children = node.children || [];
  const fold = context.place + "|" + path;
  const remembered = network.folds.get(fold);
  const open = remembered != null ? remembered : context.needle && treeHasNeedle(node, context.needle) ? true : depth < context.openDepth;
  const braces = node.kind === "array" ? ["[", "]"] : ["{", "}"];
  const count = children.length + (node.kind === "array" ? (children.length === 1 ? " item" : " items") : node.kind === "object" ? (children.length === 1 ? " key" : " keys") : (children.length === 1 ? " field" : " fields"));
  return '<details class="jt-node" data-fold="' + escapeHTML(fold) + '"' + (open ? " open" : "") + '><summary class="jt-row">' + key +
    '<span class="jt-brace">' + braces[0] + '</span><span class="jt-sum">' + count + " " + braces[1] + "</span></summary>" +
    '<div class="jt-kids">' + children.map((child, index) => treeNodeHTML(child, path + "." + index, depth + 1, context)).join("") + "</div>" +
    '<div class="jt-row jt-close"><span class="jt-brace">' + braces[1] + "</span></div></details>";
}

// The search's marks in the pane, and which one ↑ ↓ are at.
let networkMatchIndex = -1;
function countMatches() {
  const count = networkView.detail.querySelector("[data-match-count]");
  if (!count) return;
  const marks = networkView.detail.querySelectorAll(".dbody mark");
  networkMatchIndex = Math.min(networkMatchIndex, marks.length - 1);
  count.textContent = marks.length ? (networkMatchIndex >= 0 ? networkMatchIndex + 1 + " of " : "") + plural(marks.length, "match", "matches") : "No match here";
}

function stepMatch(direction) {
  const marks = [...networkView.detail.querySelectorAll(".dbody mark")];
  if (!marks.length) return;
  networkMatchIndex = (networkMatchIndex + direction + marks.length) % marks.length;
  marks.forEach((mark, index) => mark.classList.toggle("current", index === networkMatchIndex));
  const mark = marks[networkMatchIndex];
  for (let node = mark.parentElement; node && node !== networkView.detail; node = node.parentElement) if (node.tagName === "DETAILS") node.open = true;
  mark.scrollIntoView({ block: "center" });
  countMatches();
}

function bodyText(event, side) {
  const text = side === "request" ? event.request && event.request.bodyPreview : event.response && event.response.bodyPreview;
  return text ? prettyBody(parseBodyTree(text), text) : "";
}

networkView.detail.addEventListener("click", (domEvent) => {
  const tab = domEvent.target.closest("[data-dtab]");
  if (tab) { network.detailTab = tab.dataset.dtab; renderNetworkDetail(); networkView.detail.querySelector('[data-dtab="' + network.detailTab + '"]').focus(); return; }
  const action = domEvent.target.closest("[data-act]");
  if (!action || !network.selected) return;
  const event = network.selected;
  const act = action.dataset.act;
  if (act === "curl") copyText(event.protocol === "grpc" ? grpcurlCommand(event) : curlCommand(event), "Copied as " + (event.protocol === "grpc" ? "grpcurl" : "cURL"));
  if (act === "mock") copyText(mockYaml(event), "Mock copied — paste it into a test's mocks:");
  if (act === "close") { networkList.select(null); networkList.focus(); }
  if (act === "copy-body") copyText(bodyText(event, action.dataset.side), (action.dataset.side === "request" ? "Request" : "Response") + " body copied");
  if (act === "view-tree" || act === "view-raw") { network.bodyView = act === "view-tree" ? "tree" : "raw"; store("network.bodyView", network.bodyView); renderNetworkDetail(); }
  if (act === "split") { network.split = !network.split; store("network.split", network.split); renderNetworkDetail(); }
  if (act === "next-match" || act === "prev-match") stepMatch(act === "next-match" ? 1 : -1);
  if (act === "expand" || act === "collapse") {
    const view = networkView.detail.querySelector('.body-view[data-side="' + action.dataset.side + '"]');
    for (const node of view ? view.querySelectorAll("details.jt-node") : []) { node.open = act === "expand"; network.folds.set(node.dataset.fold, node.open); }
  }
});
// What a person folds stays folded through every re-render.
networkView.detail.addEventListener("toggle", (domEvent) => {
  const node = domEvent.target;
  if (node.matches && node.matches("details.jt-node")) network.folds.set(node.dataset.fold, node.open);
  else if (node.matches && node.matches("details.dsec")) { network.sections[node.dataset.sec] = node.open; store("network.sections", network.sections); }
}, true);
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

// ---- From the server: pushed, or polled while the stream is down ----

const NETWORK_MAX = 1000;   // as many calls as the server keeps
// The server's list as last heard; the table shows it unless paused.
let networkHeard = [];

function showHeardNetwork() {
  if (network.paused) {
    const known = new Set(network.events.map((event) => event.id));
    network.pausedNew = networkHeard.filter((event) => !known.has(event.id)).length;
  } else {
    network.events = networkHeard;
  }
}

function applyNetworkTopic(payload, reset) {
  if (payload.mocks) {
    const map = {};
    for (const rule of payload.mocks) map[rule.id] = rule;
    network.mockRules = map;
  }
  if (reset) networkHeard = [];
  if (payload.removedLaunch != null) networkHeard = networkHeard.filter((event) => String(event.launchId) !== String(payload.removedLaunch));
  if (payload.events) networkHeard = mergeNetworkEvents(networkHeard, payload.events, NETWORK_MAX);
  showHeardNetwork();
  renderSoon(renderNetwork);
}

let networkLastPayload = "";
async function loadNetwork() {
  await loadLaunches();
  const payload = await apiJSON("/api/v1/network/events?limit=" + NETWORK_MAX);
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
  networkHeard = events;
  showHeardNetwork();
  renderNetwork();
}

tabHandlers.network = { show() { renderNetwork(); refreshInspector("network"); } };

function resetNetwork() {
  network.events = [];
  networkHeard = [];
  network.cleared.clear();
  networkLastPayload = "";
  networkList.select(null);
  renderNetwork();
}
