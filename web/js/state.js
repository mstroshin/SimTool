// State: live snapshots of the app's @SimToolDebugState models — a list of
// models, the selected one's snapshot, and what changed, as before → after.

const STATE_HISTORY_LIMIT = 500;
const stateView = {
  cursor: null,
  latest: {},          // modelId → latest event (a deallocation keeps the last snapshot)
  changes: [],         // { event, diffs }, oldest first
  selected: stored("state.selected", null),
  mode: "snapshot",    // snapshot | changes
  lastChange: {},      // modelId → paths changed by its latest event
  folded: new Set()    // "modelId|path" of the nested values a person folded
};

const stateFilter = createFilter("state", { placeholder: "Filter models, keys and values", onChange: () => renderState() });
const stateModes = segmented("View", [["snapshot", "Snapshot"], ["changes", "Changes"]], () => stateView.mode, (mode) => { stateView.mode = mode; renderState(); });
const stateCopy = el("button", { class: "tb-btn", type: "button", "aria-label": "Copy the snapshot as JSON", "data-tip": "Copy the snapshot as JSON", html: icon("copy") });

const statePanel = $("panel-state");
const stateModels = el("div", { class: "models", role: "listbox", "aria-label": "Tracked models", tabindex: "0" });
const stateBody = el("div", { class: "state-body", role: "region", "aria-label": "Model state" });
statePanel.append(
  el("div", { class: "ptool" }, stateFilter.field, stateModes, el("span", { class: "ptool-spacer" }), stateCopy),
  el("div", { class: "state-split" }, stateModels, stateBody)
);

stateCopy.addEventListener("click", () => {
  const event = stateModelsView().latest[stateView.selected];
  if (event) copyText(JSON.stringify(event.snapshot, (key, value) => key === MODEL_ID_KEY ? undefined : value, 2), "Snapshot copied");
});

// The models the tab is about: live, or as a reviewed run held them at the end of its window.
function stateModelsView() {
  return reviewStateView(stateView);
}

function stateMatches(id, view) {
  const query = stateFilter.text;
  const chips = stateFilter.chips;
  if (!query && !chips.length) return true;
  const event = view.latest[id];
  const hay = (id + " " + JSON.stringify(event ? event.snapshot : "")).toLowerCase();
  return matchesFilters(hay, chips, query);
}

function renderStateTree(value, changed, path, modelId) {
  if (!value || typeof value !== "object") return '<span>' + escapeHTML(stateValueText(value)) + "</span>";
  const keys = Array.isArray(value) ? value.map((_, index) => index) : Object.keys(value).filter((key) => key !== MODEL_ID_KEY).sort();
  return keys.map((key) => {
    const child = value[key];
    const childPath = path ? path + (Array.isArray(value) ? "[" + key + "]" : "." + key) : String(key);
    const label = Array.isArray(value) ? "[" + key + "]" : key;
    const isChanged = changed.some((candidate) => candidate === childPath || candidate.startsWith(childPath + ".") || candidate.startsWith(childPath + "["));
    if (child && typeof child === "object" && Object.keys(child).filter((k) => k !== MODEL_ID_KEY).length) {
      const summary = Array.isArray(child) ? label + " [" + child.length + "]" : label;
      const open = stateView.folded.has(modelId + "|" + childPath) ? "" : " open";
      return "<details" + open + '><summary data-path="' + escapeHTML(childPath) + '"><span class="k">' + escapeHTML(summary) + '</span></summary><div class="indent">' + renderStateTree(child, changed, childPath, modelId) + "</div></details>";
    }
    return '<div><span class="k">' + escapeHTML(label) + '</span>: <span class="' + (isChanged ? "changed" : "") + '">' + escapeHTML(stateValueText(child)) + "</span></div>";
  }).join("");
}

function renderState() {
  const view = stateModelsView();
  const ids = Object.keys(view.latest).sort((a, b) => {
    const left = view.latest[a], right = view.latest[b];
    return (left.deallocated ? 1 : 0) - (right.deallocated ? 1 : 0) || a.localeCompare(b);
  }).filter((id) => stateMatches(id, view));
  // A reviewed moment without the chosen model keeps the choice for when the playhead finds it again.
  if (stateView.selected && !view.latest[stateView.selected] && view === stateView) stateView.selected = null;
  const selected = stateView.selected && view.latest[stateView.selected] ? stateView.selected : ids[0] || null;
  if (view === stateView) stateView.selected = selected;
  setCount("state", Object.keys(view.latest).length, 0);

  const focusedId = document.activeElement && stateModels.contains(document.activeElement) ? document.activeElement.dataset.model : null;
  stateModels.innerHTML = "";
  for (const id of ids) {
    const event = view.latest[id];
    const button = el("button", { type: "button", class: "model" + (event.deallocated ? " dead" : ""), role: "option", "aria-selected": String(id === selected), tabindex: id === selected ? "0" : "-1", "data-model": id });
    button.innerHTML = '<span class="dot ' + (event.deallocated ? "dot-idle" : "dot-ok") + '" title="' + (event.deallocated ? "deallocated" : "alive") + '"></span>' +
      '<span class="m-name" translate="no">' + escapeHTML(id) + '</span><span class="m-seq">#' + escapeHTML(event.seq) + "</span>" +
      '<span class="m-sub">' + (event.deallocated ? "deallocated " : "changed ") + escapeHTML(formatClock(event.timestamp)) + "</span>";
    stateModels.append(button);
  }
  if (focusedId) { const again = stateModels.querySelector('[data-model="' + CSS.escape(focusedId) + '"]'); if (again) again.focus(); }

  if (!ids.length) {
    stateBody.innerHTML = "";
    stateBody.paneKey = null;
    if (view !== stateView && !Object.keys(view.latest).length) stateBody.append(reviewEmpty("state"));
    else if (!inspector.attachedApp && inspector.configKnown && !Object.keys(view.latest).length) stateBody.append(noAppPanel("state"));
    else if (Object.keys(view.latest).length) stateBody.append(el("div", { class: "empty", html: "<b>No model matches</b>Clear the filter to see all " + formatCount(Object.keys(view.latest).length) + "." }));
    else stateBody.append(el("div", { class: "empty", html: "<b>No tracked models yet</b>Annotate an <code>@Observable</code> model with <code>@SimToolDebugState</code>, register it with <code>SimToolState.track(model)</code>, and launch the app through SimTool — its state streams here on every change." }));
    return;
  }
  const event = view.latest[selected];
  // Every state event re-renders; patchPane keeps folds, focus, scroll and a text selection.
  const paneKey = selected + "|" + stateView.mode;
  if (stateView.mode === "snapshot") {
    patchPane(stateBody, paneKey, '<div class="dhead flat"><span class="dtitle" translate="no">' + escapeHTML(selected) + '</span><span class="muted small">seq ' + escapeHTML(event.seq) + " · " + (event.deallocated ? "deallocated" : "alive") + "</span></div>" +
      '<div class="tree-kv" translate="no">' + renderStateTree(event.snapshot, view.lastChange[selected] || [], "", selected) + "</div>");
  } else {
    const embedded = embeddedModelIds(view.latest);
    const blocks = [];
    if (embedded[selected]) {
      patchPane(stateBody, paneKey, '<div class="empty"><b>Changes show in ' + escapeHTML(embedded[selected]) + "</b>This model lives inside that one, so its changes appear there as nested paths.</div>");
      return;
    }
    for (let index = view.changes.length - 1; index >= 0; index--) {
      const { event: change, diffs } = view.changes[index];
      if (change.modelId !== selected) continue;
      // The parent's history entry already shows this change as a nested diff.
      if (embedded[change.modelId]) continue;
      blocks.push('<div class="change"><div class="change-head"><b translate="no">' + escapeHTML(change.modelId) + "</b><span>seq " + escapeHTML(change.seq) + '</span><span class="mono">' + escapeHTML(formatClock(change.timestamp, true)) + "</span>" + (change.deallocated ? "<span>deallocated</span>" : "") + "</div>" +
        diffs.map((diff) => '<div class="diffline" translate="no"><span class="path">' + escapeHTML(diff.path) + "</span><del>" + escapeHTML(stateValueText(diff.before)) + '</del><span class="arrow">→</span><ins>' + escapeHTML(stateValueText(diff.after)) + "</ins></div>").join("") + "</div>");
    }
    const none = view === stateView ? "<b>No changes yet</b>This model has not changed since it was first reported." : "<b>No changes here</b>This model did not change in the reviewed span.";
    patchPane(stateBody, paneKey, blocks.length ? blocks.join("") : '<div class="empty">' + none + "</div>");
  }
}

// Folding a nested value is remembered per model and path, across renders.
stateBody.addEventListener("toggle", (event) => {
  const summary = event.target.firstElementChild;
  if (!summary || summary.dataset.path == null || !stateView.selected) return;
  const key = stateView.selected + "|" + summary.dataset.path;
  if (event.target.open) stateView.folded.delete(key); else stateView.folded.add(key);
}, true);

stateModels.addEventListener("click", (event) => {
  const button = event.target.closest("[data-model]");
  if (!button) return;
  stateView.selected = button.dataset.model;
  store("state.selected", stateView.selected);
  renderState();
  const again = stateModels.querySelector('[data-model="' + CSS.escape(stateView.selected) + '"]');
  if (again) again.focus();
});
stateModels.addEventListener("keydown", (event) => {
  const buttons = [...stateModels.querySelectorAll("[data-model]")];
  const index = buttons.findIndex((button) => button.dataset.model === stateView.selected);
  const delta = { ArrowDown: 1, ArrowUp: -1 }[event.key];
  if (!delta || !buttons.length) return;
  event.preventDefault();
  const next = buttons[Math.max(0, Math.min(buttons.length - 1, index + delta))];
  stateView.selected = next.dataset.model;
  renderState();
  const again = stateModels.querySelector('[data-model="' + CSS.escape(stateView.selected) + '"]');
  if (again) again.focus();
});

// ---- Snapshots pushed, or polled while the stream is down ----

// Takes the events after the cursor; true when there was one.
function takeStateEvents(events) {
  let taken = false;
  for (const event of events || []) {
    if (stateView.cursor != null && event.cursor != null && event.cursor <= stateView.cursor) continue;
    if (event.cursor != null) stateView.cursor = event.cursor;
    taken = true;
    const previous = stateView.latest[event.modelId];
    const diffs = diffStateValues(previous ? previous.snapshot : undefined, event.snapshot, "", []);
    if (previous || event.deallocated) {
      stateView.changes.push({ event, diffs });
      if (stateView.changes.length > STATE_HISTORY_LIMIT) stateView.changes.shift();
    }
    stateView.lastChange[event.modelId] = event.deallocated ? [] : diffs.map((diff) => diff.path);
    // A deallocation carries no snapshot; keep the last known one so the
    // greyed-out model still shows what it looked like.
    stateView.latest[event.modelId] = event.deallocated && previous ? { ...event, snapshot: previous.snapshot } : event;
  }
  return taken;
}

function applyStateTopic(payload, reset) {
  if (reset) forgetStateEvents();
  if (takeStateEvents(payload.events) || reset) renderSoon(renderState);
}

async function pollState() {
  const since = stateView.cursor == null ? "" : "&since=" + stateView.cursor;
  const payload = await apiJSON("/api/v1/state/events?limit=500" + since);
  const taken = takeStateEvents(payload.events);
  if (payload.nextCursor != null) stateView.cursor = Math.max(stateView.cursor ?? -1, payload.nextCursor);
  if (taken) renderState();
}

tabHandlers.state = { show() { renderState(); refreshInspector("state"); } };

function forgetStateEvents() {
  stateView.cursor = null;
  stateView.latest = {};
  stateView.changes = [];
  stateView.lastChange = {};
}

function resetState() {
  forgetStateEvents();
  renderState();
}
