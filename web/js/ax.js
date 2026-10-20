// Accessibility: the served AX tree, picking on the screen, and redlines —
// the picked element's frame with its distances to the screen edges and to the
// element under the pointer, in points: the same numbers a YAML step or
// `simtool input tap --x/--y` uses.

const ax = {
  tree: null,
  nodes: new Map(),        // key → node (with _key, _parent, _depth)
  expanded: new Set(),
  selected: null,
  hover: null,
  pick: stored("ax.pick", true),
  hideEmpty: stored("ax.hideEmpty", true),
  updatedAt: 0,
  error: ""
};

const axFilter = createFilter("ax", { placeholder: "Filter identifier, label, role", onChange: () => renderAx() });
const axPickButton = el("button", { class: "toggle toggle-sm", type: "button", "aria-pressed": String(ax.pick), "data-tip": "Pick an element on the screen", "data-key": "P", html: icon("pick") + '<span class="toggle-label">Pick</span>' });
const axHideEmptyButton = pillToggle("Hide empty groups", () => ax.hideEmpty, () => { ax.hideEmpty = !ax.hideEmpty; store("ax.hideEmpty", ax.hideEmpty); renderAx(); }, "Fold containers that have no identifier, label or value");
const axRefresh = el("button", { class: "tb-btn", type: "button", "aria-label": "Refresh the tree", "data-tip": "Refresh the tree", html: icon("relaunch") });
const axStatus = el("span", { class: "muted small mono ptool-note" });

const axView = buildListPanel("ax", {
  listRole: "tree",
  listLabel: "Accessibility tree",
  toolbar: [axPickButton, axFilter.field, axHideEmptyButton, el("span", { class: "ptool-spacer" }), axStatus, axRefresh]
});

axPickButton.addEventListener("click", () => setAxPick(!ax.pick));
axRefresh.addEventListener("click", () => poller.poke("ax"));

function setAxPick(on) {
  ax.pick = on;
  store("ax.pick", on);
  axPickButton.setAttribute("aria-pressed", String(on));
  updateAxMode();
}

// Picking happens on the live screen, with the Accessibility tab in view.
function axPickActive() {
  return ax.pick && inspector.open && inspector.tab === "ax" && app.dataset.mode !== "replay" && !!ax.tree;
}

function updateAxMode() {
  app.classList.toggle("ax-pick", axPickActive());
  drawRulers();
  drawRedlines();
}

// ---- Tree ----

function indexAx(tree) {
  const nodes = new Map();
  const walk = (node, parent, depth, path) => {
    // Keys stay stable across refreshes as long as the element keeps its place.
    const key = node.id || path;
    node._key = key;
    node._parent = parent;
    node._depth = depth;
    nodes.set(key, node);
    (node.children || []).forEach((child, index) => walk(child, key, depth + 1, path + "/" + index));
  };
  (tree.roots || []).forEach((root, index) => walk(root, null, 0, String(index)));
  ax.nodes = nodes;
  const screen = axScreenFrame(tree);
  if (screen) {
    screenState.points = { width: screen.width, height: screen.height, x: screen.x, y: screen.y };
    updateReadoutSize();
  }
}

// Rows to show: with "hide empty groups", an anonymous container with exactly
// one child is skipped and its child takes its place.
function axVisibleRows() {
  if (!ax.tree) return [];
  const query = axFilter.text;
  const chips = axFilter.chips;
  let keep = null;
  if (query || chips.length) {
    keep = new Set();
    for (const node of ax.nodes.values()) {
      const hay = [node.accessibilityIdentifier, node.label, node.value, node.title, node.role, node.roleDescription, node.type].filter(Boolean).join(" ").toLowerCase();
      if (!matchesFilters(hay, chips, query)) continue;
      for (let key = node._key; key != null && !keep.has(key); key = ax.nodes.get(key)._parent) keep.add(key);
    }
  }
  const rows = [];
  const walk = (node, depth, folded) => {
    if (keep && !keep.has(node._key)) return;
    const children = node.children || [];
    // An anonymous element with nothing inside says nothing at all.
    if (ax.hideEmpty && axIsAnonymous(node) && !children.length && node._depth > 0) return;
    if (ax.hideEmpty && axIsAnonymous(node) && children.length === 1 && node._depth > 0) {
      walk(children[0], depth, folded + 1);
      return;
    }
    const expanded = keep ? true : ax.expanded.has(node._key);
    rows.push({ node, depth, folded, expanded, hasChildren: children.length > 0 });
    if (expanded) for (const child of children) walk(child, depth + 1, 0);
  };
  for (const root of ax.tree.roots || []) walk(root, 0, 0);
  return rows;
}

const axList = createList(axView.list, {
  rowRole: "treeitem",
  key: (row) => row.node._key,
  version: (row) => [row.depth, row.folded, row.expanded, row.hasChildren, axTitle(row.node), row.node.label, frameText(row.node)].join("|"),
  rowClass: () => "tree-grid",
  render: renderAxRow,
  empty: () => el("div", { class: "empty", html: ax.error ? "<b>No accessibility tree</b>" + escapeHTML(ax.error) : ax.tree ? "<b>No element matches</b>Clear the filter to see the whole tree." : "<b>Reading the accessibility tree…</b>" }),
  onSelect: (key) => { ax.selected = key; renderAxDetail(); drawRedlines(); },
  onMenu: (key, row, x, y, element) => openMenu(x, y, axMenuItems(row.node), element),
  onActivate: (key, row) => toggleAxNode(row)
});
axView.list.addEventListener("keydown", (event) => {
  const row = axList.selectedItem;
  if (!row || event.target.closest("input")) return;
  if (event.key === "ArrowRight" && row.hasChildren && !row.expanded) { event.preventDefault(); toggleAxNode(row); }
  else if (event.key === "ArrowLeft" && row.expanded) { event.preventDefault(); toggleAxNode(row); }
  else if (event.key === "ArrowLeft" && row.node._parent != null) { event.preventDefault(); axList.select(row.node._parent, { focus: true }); }
});
axView.list.addEventListener("click", (event) => {
  const twisty = event.target.closest(".twisty");
  if (!twisty) return;
  const key = twisty.closest(".row").dataset.key;
  const row = axList.visibleItems.find((candidate) => candidate.node._key === key);
  if (row) toggleAxNode(row);
});
axView.list.addEventListener("mouseover", (event) => {
  const element = event.target.closest(".row[data-key]");
  const key = element ? element.dataset.key : null;
  if (key !== ax.hover) { ax.hover = key; drawRedlines(); }
});
axView.list.addEventListener("mouseleave", () => { ax.hover = null; drawRedlines(); });

function toggleAxNode(row) {
  if (!row.hasChildren) return;
  if (ax.expanded.has(row.node._key)) ax.expanded.delete(row.node._key); else ax.expanded.add(row.node._key);
  renderAx();
}

function frameText(node) {
  return node.frame ? Math.round(node.frame.width) + "×" + Math.round(node.frame.height) : "";
}

function renderAxRow(row, element) {
  const node = row.node;
  element.setAttribute("aria-level", String(row.depth + 1));
  if (row.hasChildren) element.setAttribute("aria-expanded", String(row.expanded)); else element.removeAttribute("aria-expanded");
  const label = node.label && node.label.trim() && node.label.trim() !== node.accessibilityIdentifier ? node.label.trim() : "";
  element.innerHTML =
    '<span class="trow-main" style="padding-left:' + (row.depth * 14) + 'px">' +
      '<span class="twisty" aria-hidden="true">' + (row.hasChildren ? icon(row.expanded ? "chev-d" : "chev-r") : "") + "</span>" +
      '<span class="role">' + escapeHTML(axRoleName(node)) + "</span>" +
      (node.accessibilityIdentifier ? '<span class="ax-id" translate="no">' + escapeHTML(node.accessibilityIdentifier) + "</span>" : "") +
      (label ? '<span class="ax-label" translate="no">“' + escapeHTML(label) + "”</span>" : "") +
      (!node.accessibilityIdentifier && !label && node.value ? '<span class="ax-label" translate="no">' + escapeHTML(node.value) + "</span>" : "") +
      (row.folded ? '<span class="collapsed-run">' + plural(row.folded, "empty group", "empty groups") + " folded</span>" : "") +
    "</span>" +
    '<span class="ax-frame">' + escapeHTML(frameText(node)) + "</span>";
}

function renderAx() {
  axList.update(axVisibleRows());
  const age = ax.updatedAt ? Math.round((Date.now() - ax.updatedAt) / 1000) : null;
  axStatus.textContent = ax.error ? "error" : ax.tree ? plural(ax.tree.nodeCount || ax.nodes.size, "node", "nodes") + " · " + (age < 2 ? "just now" : age + " s ago") : "";
  axView.guide.innerHTML = guideHTML([
    ax.pick ? "Pick: click an element on the screen" : "Picking is off — press P",
    ax.selected && ax.nodes.get(ax.selected) ? "<b>" + escapeHTML(axTitle(ax.nodes.get(ax.selected))) + "</b>" : ""
  ], "");
  renderAxDetail();
  drawRedlines();
}

// ---- Selected element ----

function axPath(node) {
  const path = [];
  for (let key = node._parent; key != null; key = ax.nodes.get(key)._parent) {
    const parent = ax.nodes.get(key);
    if (!axIsAnonymous(parent)) path.unshift(axTitle(parent));
  }
  return path;
}

function axCopyPayload(node) {
  return {
    accessibilityIdentifier: node.accessibilityIdentifier ?? null, label: node.label ?? null, value: node.value ?? null,
    title: node.title ?? null, role: node.role ?? null, roleDescription: node.roleDescription ?? null, type: node.type ?? null,
    enabled: node.enabled ?? null, pid: node.pid ?? null, frame: node.frame ?? null, ancestorPath: axPath(node), raw: node.raw ?? null
  };
}

function axMenuItems(node) {
  return [
    { icon: "copy", label: "Copy as YAML step", run: () => copyText(axYamlStep(node), "YAML step copied") },
    { icon: "terminal", label: "Copy CLI command", run: () => copyText(axCliCommand(node), "Command copied") },
    { icon: "copy", label: "Copy JSON", run: () => copyText(JSON.stringify(axCopyPayload(node), null, 2), "Element copied") }
  ];
}

function renderAxDetail() {
  const node = ax.selected ? ax.nodes.get(ax.selected) : null;
  showDetail(axView.panel, !!node);
  if (!node) return;
  const frame = node.frame || {};
  const yaml = axYamlStep(node);
  const cli = axCliCommand(node);
  // The tree refreshes every two seconds; the detail changes only with the element.
  patchPane(axView.detail, node._key,
    '<div class="dhead"><span class="role">' + escapeHTML(axRoleName(node)) + '</span><span class="dtitle" translate="no">' + escapeHTML(axTitle(node)) + "</span>" +
      '<div class="dactions"><button class="btn btn-sm" type="button" data-act="json">' + icon("copy", "ic-sm") + "Copy JSON</button>" +
      '<button class="tb-btn" type="button" data-act="close" aria-label="Close the details">' + icon("close") + "</button></div></div>" +
    '<div class="dmeta"><span translate="no">' + escapeHTML(axPath(node).join(" › ") || "—") + "</span></div>" +
    '<div class="dbody">' + kvHTML({
      Role: node.roleDescription ? axRoleName(node) + " (" + node.roleDescription + ")" : axRoleName(node),
      Identifier: node.accessibilityIdentifier || "—",
      Label: node.label || "—",
      Value: node.value || "—",
      Frame: node.frame ? "x " + Math.round(frame.x) + "  y " + Math.round(frame.y) + "  w " + Math.round(frame.width) + "  h " + Math.round(frame.height) + " pt" : "—",
      Enabled: node.enabled == null ? "—" : String(node.enabled)
    }) +
      '<div class="sec">Use in a test</div>' +
      '<div class="snippet"><pre class="code" translate="no">' + escapeHTML(yaml) + '</pre><button class="btn btn-sm" type="button" data-act="yaml">' + icon("copy", "ic-sm") + "YAML step</button></div>" +
      '<div class="snippet"><pre class="code" translate="no">' + escapeHTML(cli) + '</pre><button class="btn btn-sm" type="button" data-act="cli">' + icon("copy", "ic-sm") + "CLI</button></div>" +
      (axSelector(node) ? "" : '<p class="muted small">This element has no identifier or label, so the step taps its centre. Giving it an accessibilityIdentifier makes the test survive layout changes.</p>') +
    "</div>");
}

axView.detail.addEventListener("click", (event) => {
  const action = event.target.closest("[data-act]");
  const node = ax.selected ? ax.nodes.get(ax.selected) : null;
  if (!action || !node) return;
  if (action.dataset.act === "json") copyText(JSON.stringify(axCopyPayload(node), null, 2), "Element copied");
  if (action.dataset.act === "yaml") copyText(axYamlStep(node), "YAML step copied");
  if (action.dataset.act === "cli") copyText(axCliCommand(node), "Command copied");
  if (action.dataset.act === "close") { axList.select(null); axList.focus(); }
});

function selectAxNode(key) {
  // Reveal it: expand its ancestors, then select.
  for (let parent = ax.nodes.get(key)._parent; parent != null; parent = ax.nodes.get(parent)._parent) ax.expanded.add(parent);
  renderAx();
  axList.select(key, { scroll: true });
}

// ---- Picking on the screen ----

function axPointAt(clientX, clientY) {
  const screen = screenState.points;
  if (!screen) return null;
  const rect = canvas.getBoundingClientRect();
  return { x: screen.x + ((clientX - rect.left) / rect.width) * screen.width, y: screen.y + ((clientY - rect.top) / rect.height) * screen.height };
}

// The element under a point: the smallest framed node containing it, then
// walked up to the nearest one a test can name — an anonymous group is
// rarely what a person meant to pick.
function axHitTest(clientX, clientY) {
  const point = axPointAt(clientX, clientY);
  if (!point) return null;
  let best = null, bestArea = Infinity;
  for (const node of ax.nodes.values()) {
    if (!axHasFrame(node)) continue;
    const frame = node.frame;
    if (frame.width > screenState.points.width * 1.05 || frame.height > screenState.points.height * 1.05) continue;
    if (point.x < frame.x || point.x > frame.x + frame.width || point.y < frame.y || point.y > frame.y + frame.height) continue;
    const area = frame.width * frame.height;
    // <= so that among coincident frames the deepest, last-walked node wins.
    if (area <= bestArea) { bestArea = area; best = node; }
  }
  for (let node = best; node; node = node._parent != null ? ax.nodes.get(node._parent) : null) {
    if (!axIsAnonymous(node)) return node;
  }
  return best;
}

function axHoverAt(clientX, clientY) {
  const node = clientX == null ? null : axHitTest(clientX, clientY);
  const key = node ? node._key : null;
  if (key !== ax.hover) { ax.hover = key; drawRedlines(); }
}

function axPickAt(clientX, clientY) {
  const node = axHitTest(clientX, clientY);
  if (node) selectAxNode(node._key);
}

function axMenuAt(clientX, clientY) {
  const node = axHitTest(clientX, clientY);
  if (!node) return;
  selectAxNode(node._key);
  openMenu(clientX, clientY, axMenuItems(node), canvas);
}

// ---- Rulers and redlines ----

function drawRulers() {
  const screen = screenState.points;
  const rulerX = $("rulerX"), rulerY = $("rulerY");
  if (!screen || !axPickActive()) { rulerX.innerHTML = ""; rulerY.innerHTML = ""; return; }
  const device = $("device").getBoundingClientRect();
  const stepX = device.width * 50 / screen.width, stepY = device.height * 50 / screen.height;
  $("device").style.setProperty("--tick-x", stepX + "px");
  $("device").style.setProperty("--tick-y", stepY + "px");
  const marks = (size) => Array.from({ length: Math.floor(size / 100) + 1 }, (_, index) => index * 100);
  rulerX.innerHTML = marks(screen.width).map((value) => '<span style="left:' + (value / screen.width * 100) + '%">' + value + "</span>").join("");
  rulerY.innerHTML = marks(screen.height).map((value) => '<span style="top:' + (value / screen.height * 100) + '%">' + value + "</span>").join("");
}

function drawRedlines() {
  const svg = $("redlines"), labels = $("redlineLabels");
  const screen = screenState.points;
  if (!screen || !axPickActive()) { svg.innerHTML = ""; labels.innerHTML = ""; return; }
  svg.setAttribute("viewBox", screen.x + " " + screen.y + " " + screen.width + " " + screen.height);
  svg.setAttribute("preserveAspectRatio", "none");
  const selected = ax.selected ? ax.nodes.get(ax.selected) : null;
  const hover = ax.hover && ax.hover !== ax.selected ? ax.nodes.get(ax.hover) : null;
  const rect = (node, cls) => {
    const f = node.frame;
    return '<rect class="' + cls + '" x="' + f.x + '" y="' + f.y + '" width="' + f.width + '" height="' + f.height + '"/>';
  };
  let shapes = "";
  let text = "";
  // Every element a test can name, faintly: what there is to pick.
  for (const node of ax.nodes.values()) {
    if (!axHasFrame(node) || axIsAnonymous(node) || node._depth === 0) continue;
    if (node.frame.width > screen.width * 1.05 || node.frame.height > screen.height * 1.05) continue;
    shapes += rect(node, "ghost");
  }
  if (hover && axHasFrame(hover)) shapes += rect(hover, "hover");
  const place = (x, y, value, cls) => {
    text += '<span class="rl' + (cls ? " " + cls : "") + '" style="left:' + ((x - screen.x) / screen.width * 100) + "%;top:" + ((y - screen.y) / screen.height * 100) + '%">' + escapeHTML(value) + "</span>";
  };
  if (selected && axHasFrame(selected)) {
    const { x, y, width, height } = selected.frame;
    const right = screen.x + screen.width, midY = y + height / 2;
    shapes += rect(selected, "box");
    if (x > screen.x) { shapes += '<line class="dim" x1="' + screen.x + '" y1="' + midY + '" x2="' + x + '" y2="' + midY + '"/>'; place((screen.x + x) / 2, midY, Math.round(x - screen.x)); }
    if (x + width < right) { shapes += '<line class="dim" x1="' + (x + width) + '" y1="' + midY + '" x2="' + right + '" y2="' + midY + '"/>'; place((x + width + right) / 2, midY, Math.round(right - x - width)); }
    // Vertical distance to the element under the pointer, when it is above or below.
    if (hover && axHasFrame(hover)) {
      const h = hover.frame, column = x + width * 0.72;
      if (h.y + h.height <= y) { shapes += '<line class="dim" x1="' + column + '" y1="' + (h.y + h.height) + '" x2="' + column + '" y2="' + y + '"/>'; place(column, (h.y + h.height + y) / 2, Math.round(y - h.y - h.height)); }
      else if (h.y >= y + height) { shapes += '<line class="dim" x1="' + column + '" y1="' + (y + height) + '" x2="' + column + '" y2="' + h.y + '"/>'; place(column, (y + height + h.y) / 2, Math.round(h.y - y - height)); }
    }
    place(x + width / 2, y + height + 4, Math.round(width) + " × " + Math.round(height), "rl-size");
  }
  svg.innerHTML = shapes;
  labels.innerHTML = text;
}

// ---- Loading ----

let axFetching = false;
async function loadAx() {
  if (axFetching) return;
  axFetching = true;
  try {
    const tree = await apiJSON("/api/v1/ax/tree?raw=1");
    const firstLoad = !ax.tree;
    ax.tree = tree;
    ax.error = "";
    ax.updatedAt = Date.now();
    indexAx(tree);
    if (firstLoad) {
      // Open the tree down to the first elements that say something.
      for (const node of ax.nodes.values()) {
        if (node._depth < 2 || (axIsAnonymous(node) && (node.children || []).length)) ax.expanded.add(node._key);
      }
    }
    if (ax.selected && !ax.nodes.has(ax.selected)) ax.selected = null;
    updateAxMode();
    if (inspector.tab === "ax") renderAx();
  } catch (error) {
    ax.error = "The tree could not be read: " + error.message + ". Accessibility needs AXe — `simtool doctor` checks it.";
    if (inspector.tab === "ax") renderAx();
    throw error;
  } finally {
    axFetching = false;
  }
}

tabHandlers.ax = {
  show() { renderAx(); updateAxMode(); poller.poke("ax"); },
  hide() { ax.hover = null; updateAxMode(); }
};

// The status line ages between refreshes.
setInterval(() => { if (inspector.tab === "ax" && ax.tree && !ax.error) {
  const age = Math.round((Date.now() - ax.updatedAt) / 1000);
  axStatus.textContent = plural(ax.tree.nodeCount || ax.nodes.size, "node", "nodes") + " · " + (age < 2 ? "just now" : age + " s ago");
} }, 1000);
