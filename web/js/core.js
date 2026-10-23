// Page plumbing shared by every part of the viewer: elements, icons, the
// status message, toasts, copying, menus, dialogs, stored preferences and the
// one scheduler that polls the server.

const $ = (id) => document.getElementById(id);
const app = $("app");

function escapeHTML(value) {
  return String(value == null ? "" : value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function icon(name, extraClass) {
  return '<svg class="ic' + (extraClass ? " " + extraClass : "") + '" aria-hidden="true"><use href="#i-' + name + '"/></svg>';
}

// el("div", { class: "x", onclick: fn }, child, "text") — small, explicit DOM building.
function el(tag, attributes, ...children) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes || {})) {
    if (value == null || value === false) continue;
    if (name.startsWith("on") && typeof value === "function") node.addEventListener(name.slice(2), value);
    else if (name === "html") node.innerHTML = value;
    else if (name === "text") node.textContent = value;
    else node.setAttribute(name, value === true ? "" : String(value));
  }
  for (const child of children) {
    if (child == null || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

// ---- Stored preferences (per browser; the page works without them) ----

function stored(key, fallback) {
  try {
    const raw = localStorage.getItem("simtool." + key);
    return raw == null ? fallback : JSON.parse(raw);
  } catch (_) { return fallback; }
}

function store(key, value) {
  try { localStorage.setItem("simtool." + key, JSON.stringify(value)); } catch (_) {}
}

// ---- Server ----

async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (options.body && typeof options.body === "string" && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const response = await fetch(path, { ...options, headers });
  if (!response.ok) {
    // The server explains failures in {"error": …}; that beats a bare status line.
    let detail = "";
    try { detail = (await response.json()).error || ""; } catch (_) {}
    throw new Error(detail || response.status + " " + response.statusText);
  }
  return response;
}

async function apiJSON(path, options) {
  return (await api(path, options)).json();
}

// The header tells the server's activity feed this came from a person at a viewer.
function postInput(payload) {
  return api("/api/v1/input", { method: "POST", body: JSON.stringify(payload), headers: { "X-SimTool-Source": "viewer" } });
}

// SimTool stops a server nobody uses and shuts its simulator down, and what
// this page fetches by itself is not use: a tab left open is not a person. A
// hand on the page while it is shown is — said at most twice a minute.
const PRESENCE_INTERVAL = 30000;
let presenceSentAt = -Infinity;
function notePresence() {
  if (document.hidden) return;
  const now = performance.now();
  if (now - presenceSentAt < PRESENCE_INTERVAL) return;
  presenceSentAt = now;
  fetch("/api/v1/presence", { method: "POST" }).catch(() => {});
}
for (const type of ["pointerdown", "pointermove", "keydown", "wheel"]) {
  document.addEventListener(type, notePresence, { capture: true, passive: true });
}

// ---- Status message, toasts, announcements ----

let messageTimer = null;
function setMessage(text, kind) {
  const cell = $("sbMessage");
  cell.textContent = text || "";
  cell.classList.toggle("sb-err", kind === "err");
  clearTimeout(messageTimer);
  if (text && kind !== "sticky") messageTimer = setTimeout(() => { if (cell.textContent === text) cell.textContent = ""; }, 8000);
}

let toastTimer = null;
function toast(text, options = {}) {
  const node = $("toast");
  node.innerHTML = "";
  node.className = "toast" + (options.error ? " err" : "");
  node.append(el("span", { html: icon(options.error ? "warn" : options.icon || "check") }), el("span", { text }));
  if (options.action) {
    node.append(el("button", { type: "button", text: options.action.label, onclick: () => { node.hidden = true; options.action.run(); } }));
  }
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { node.hidden = true; if (options.onExpire) options.onExpire(); }, options.duration || 2600);
  if (options.error) setMessage(text, "err");
}

function fail(what, error) {
  toast(what + ": " + (error && error.message ? error.message : error), { error: true, duration: 5000 });
}

async function copyText(text, label) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (_) {
    const area = el("textarea", {});
    area.value = text;
    document.body.append(area);
    area.select();
    try { document.execCommand("copy"); } catch (_) {}
    area.remove();
  }
  toast(label || "Copied", { icon: "copy" });
}

// ---- Menus (APG menu: arrows move, Enter runs, Esc returns focus) ----

let menuOpener = null;
// items: [{ icon, label, kbd, run, tone: "course"|"danger", disabled }], "-" for a rule, or
// { caption } naming the items under it. An item with `checked` is a switch that says
// whether it is on; with `radio` too, it is one choice of several, ticked when chosen.
function openMenu(x, y, items, opener) {
  const menu = $("menu");
  if (!menu.hidden) setMenuExpanded(false);
  menu.innerHTML = "";
  for (const item of items) {
    if (item === "-") { menu.append(el("hr", { role: "separator" })); continue; }
    if (item.caption) { menu.append(el("div", { class: "m-caption", role: "presentation", text: item.caption })); continue; }
    const choice = item.checked != null;
    const button = el("button", {
      type: "button", role: choice ? (item.radio ? "menuitemradio" : "menuitemcheckbox") : "menuitem", tabindex: "-1",
      class: [item.tone ? "m-" + item.tone : "", item.radio ? "m-radio" : ""].join(" ").trim() || null,
      disabled: item.disabled, "aria-checked": choice ? String(!!item.checked) : null
    },
      el("span", { html: icon(item.radio ? "check" : item.icon || "chev-r") }), el("span", { text: item.label }),
      choice && !item.radio ? el("span", { class: "m-switch", "aria-hidden": "true" }) : null,
      item.kbd ? el("kbd", { text: item.kbd }) : null);
    button.addEventListener("click", () => { closeMenu(); item.run(); });
    menu.append(button);
  }
  menu.hidden = false;
  const rect = menu.getBoundingClientRect();
  menu.style.left = Math.max(6, Math.min(x, innerWidth - rect.width - 6)) + "px";
  menu.style.top = Math.max(6, Math.min(y, innerHeight - rect.height - 6)) + "px";
  menuOpener = opener || document.activeElement;
  setMenuExpanded(true);
  const first = menu.querySelector("button:not([disabled])");
  if (first) first.focus();
}

// A button that opens a menu says whether it is open.
function setMenuExpanded(open) {
  if (menuOpener && menuOpener.getAttribute && menuOpener.getAttribute("aria-haspopup") === "menu") menuOpener.setAttribute("aria-expanded", String(open));
}

function closeMenu(restoreFocus) {
  const menu = $("menu");
  if (menu.hidden) return false;
  menu.hidden = true;
  setMenuExpanded(false);
  if (restoreFocus && menuOpener && menuOpener.focus) menuOpener.focus();
  menuOpener = null;
  return true;
}

// A toolbar button whose menu drops under it: a click, Enter, Space or ↓ opens
// it, and a click on the open menu's button closes it. `items()` is read at
// every opening, so the menu shows the state of the moment.
function wireMenuButton(button, items) {
  button.addEventListener("click", () => {
    if (!$("menu").hidden && menuOpener === button) { closeMenu(); return; }
    const rect = button.getBoundingClientRect();
    openMenu(rect.left, rect.bottom + 4, items(), button);
  });
  button.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowDown") return;
    event.preventDefault();
    if ($("menu").hidden || menuOpener !== button) button.click();
  });
}

$("menu").addEventListener("keydown", (event) => {
  const items = [...$("menu").querySelectorAll("button:not([disabled])")];
  const index = items.indexOf(document.activeElement);
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    const next = items[(index + (event.key === "ArrowDown" ? 1 : items.length - 1)) % items.length];
    if (next) next.focus();
  } else if (event.key === "Home" || event.key === "End") {
    event.preventDefault();
    const next = event.key === "Home" ? items[0] : items[items.length - 1];
    if (next) next.focus();
  } else if (event.key === "Escape" || event.key === "Tab") {
    event.preventDefault();
    closeMenu(true);
  }
});

// A menu for an element that has focus but no pointer: below it.
function openMenuAt(element, items) {
  const rect = element.getBoundingClientRect();
  openMenu(rect.left + 16, rect.bottom, items, element);
}

// ---- Popover (help) ----

function openPopover(anchor, html) {
  const popover = $("popover");
  popover.innerHTML = html;
  popover.hidden = false;
  const rect = anchor.getBoundingClientRect();
  const box = popover.getBoundingClientRect();
  popover.style.left = Math.max(6, Math.min(rect.left, innerWidth - box.width - 6)) + "px";
  popover.style.top = Math.min(rect.bottom + 6, innerHeight - box.height - 6) + "px";
  anchor.setAttribute("aria-expanded", "true");
  popover.dataset.anchor = anchor.id || "";
}

function closePopover() {
  const popover = $("popover");
  if (popover.hidden) return false;
  popover.hidden = true;
  const anchor = popover.dataset.anchor && $(popover.dataset.anchor);
  if (anchor) anchor.setAttribute("aria-expanded", "false");
  return true;
}

// ---- Tooltips: the action and its shortcut, on hover and keyboard focus ----
// One floating tip for every [data-tip]: under its control, above it where the
// window has no room below, and moved along so it never leaves the window — a
// button at an edge keeps its words. A tip that changes while it shows (a
// toggled button) is drawn again.

const tip = { node: $("tip"), target: null, watch: null };
const TIP_GAP = 6, TIP_MARGIN = 6;

function showTip(target) {
  if (tip.target !== target) {
    hideTip();
    tip.target = target;
    tip.watch = new MutationObserver(drawTip);
    tip.watch.observe(target, { attributes: true, attributeFilter: ["data-tip", "data-key", "hidden"] });
  }
  drawTip();
}

function drawTip() {
  const target = tip.target;
  if (!target || !target.dataset.tip || !target.isConnected || !target.getClientRects().length) { hideTip(); return; }
  const node = tip.node;
  node.replaceChildren(el("span", { text: target.dataset.tip }), target.dataset.key ? el("span", { text: target.dataset.key }) : "");
  node.hidden = false;
  const anchor = target.getBoundingClientRect(), box = node.getBoundingClientRect();
  const left = Math.max(TIP_MARGIN, Math.min(anchor.left + anchor.width / 2 - box.width / 2, innerWidth - box.width - TIP_MARGIN));
  const below = anchor.bottom + TIP_GAP;
  const top = below + box.height <= innerHeight - TIP_MARGIN ? below : Math.max(TIP_MARGIN, anchor.top - TIP_GAP - box.height);
  node.style.transform = "translate(" + Math.round(left) + "px, " + Math.round(top) + "px)";
}

function hideTip() {
  if (tip.watch) tip.watch.disconnect();
  tip.watch = null;
  tip.target = null;
  tip.node.hidden = true;
}

const tipTarget = (node) => (node && node.closest ? node.closest("[data-tip]") : null);
document.addEventListener("pointerover", (event) => {
  if (event.pointerType === "touch") return;
  const target = tipTarget(event.target);
  if (target) showTip(target);
  else if (tip.target && !tip.target.matches(":focus-visible")) hideTip();
});
document.addEventListener("pointerout", (event) => {
  if (tip.target && !tipTarget(event.relatedTarget) && !tip.target.matches(":focus-visible")) hideTip();
});
document.addEventListener("focusin", (event) => {
  const target = tipTarget(event.target);
  if (target === event.target && target.matches(":focus-visible")) showTip(target);
});
document.addEventListener("focusout", (event) => { if (event.target === tip.target) hideTip(); });
// A press, a key or a scroll takes the tip away; it comes back on the next
// hover. A new window size moves it along with its control.
for (const type of ["pointerdown", "keydown", "wheel", "scroll"]) document.addEventListener(type, hideTip, true);
window.addEventListener("resize", () => { if (tip.target) drawTip(); });

// ---- Confirmation for what cannot be undone ----

let dialogResolve = null;
function confirmDestructive(title, text, confirmLabel) {
  $("dialogTitle").textContent = title;
  $("dialogText").textContent = text;
  $("dialogConfirm").textContent = confirmLabel || "Delete";
  $("dialogScrim").hidden = false;
  const opener = document.activeElement;
  $("dialogCancel").focus();
  return new Promise((resolve) => {
    dialogResolve = (answer) => {
      $("dialogScrim").hidden = true;
      dialogResolve = null;
      if (opener && opener.focus) opener.focus();
      resolve(answer);
    };
  });
}
$("dialogCancel").addEventListener("click", () => dialogResolve && dialogResolve(false));
$("dialogConfirm").addEventListener("click", () => dialogResolve && dialogResolve(true));
$("dialogScrim").addEventListener("keydown", (event) => {
  if (event.key === "Escape") { event.preventDefault(); dialogResolve && dialogResolve(false); }
  if (event.key === "Tab") {
    // Keep focus inside the dialog.
    const buttons = [$("dialogCancel"), $("dialogConfirm")];
    const index = buttons.indexOf(document.activeElement);
    event.preventDefault();
    buttons[(index + 1) % 2].focus();
  }
});

// ---- One scheduler for every poll ----
// Tasks run on their own interval while their `when()` holds; nothing runs on a
// hidden tab. A failing task backs off (up to 8×) instead of hammering a server
// that is down, and reports to `onHealth` so the page can say so.

function createPoller(onHealth) {
  const tasks = [];
  let timer = null;
  let failures = 0;

  function due(task, now) {
    return task.when() && !task.running && now >= task.nextAt;
  }

  async function run(task) {
    task.running = true;
    try {
      await task.fn();
      task.backoff = 1;
      if (failures) { failures = 0; onHealth(true); }
    } catch (error) {
      task.backoff = Math.min(8, task.backoff * 2);
      failures += 1;
      onHealth(false, error);
    } finally {
      task.running = false;
      const interval = typeof task.interval === "function" ? task.interval() : task.interval;
      task.nextAt = performance.now() + interval * task.backoff;
    }
  }

  function tick() {
    timer = null;
    if (document.hidden) return;
    const now = performance.now();
    for (const task of tasks) if (due(task, now)) run(task);
    timer = setTimeout(tick, 250);
  }

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && !timer) tick();
  });

  return {
    add(name, interval, fn, when) {
      tasks.push({ name, interval, fn, when: when || (() => true), nextAt: 0, backoff: 1, running: false });
      if (!timer && !document.hidden) timer = setTimeout(tick, 0);
    },
    // Run a task now (a user action changed what it would fetch).
    poke(name) {
      const task = tasks.find((candidate) => candidate.name === name);
      if (task && !task.running) run(task);
    }
  };
}

// ---- Resizable split handles (pointer + keyboard) ----

// value() → the share, 0–100, of the pane the handle sizes: what a screen reader announces.
function wireSplitter(handle, { axis, onMove, onEnd, step, value }) {
  let drag = false;
  handle.setAttribute("aria-valuemin", "0");
  handle.setAttribute("aria-valuemax", "100");
  const announce = () => { if (value) handle.setAttribute("aria-valuenow", String(Math.round(value()))); };
  handle.syncValue = announce;
  handle.addEventListener("pointerdown", (event) => {
    drag = true;
    handle.classList.add("active");
    try { handle.setPointerCapture(event.pointerId); } catch (_) {}
    event.preventDefault();
  });
  handle.addEventListener("pointermove", (event) => { if (drag) onMove(axis === "x" ? event.clientX : event.clientY, event); });
  const end = (event) => {
    if (!drag) return;
    drag = false;
    handle.classList.remove("active");
    try { handle.releasePointerCapture(event.pointerId); } catch (_) {}
    if (onEnd) onEnd();
    announce();
  };
  handle.addEventListener("pointerup", end);
  handle.addEventListener("pointercancel", end);
  handle.addEventListener("keydown", (event) => {
    const direction = { ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 }[event.key];
    if (!direction) return;
    event.preventDefault();
    step(direction, event.shiftKey ? 80 : 20);
    if (onEnd) onEnd();
    announce();
  });
}

// JSON with keys and literals told apart; everything escaped first.
function highlightJSON(text) {
  if (!text) return '<span class="muted">No body</span>';
  let pretty = String(text);
  try { pretty = JSON.stringify(JSON.parse(text), null, 2); } catch (_) { return escapeHTML(text); }
  return escapeHTML(pretty)
    .replace(/(&quot;(?:[^&]|&(?!quot;))*?&quot;)(\s*:)/g, '<span class="j-key">$1</span>$2')
    .replace(/(:\s*)(&quot;(?:[^&]|&(?!quot;))*?&quot;)/g, '$1<span class="j-str">$2</span>')
    .replace(/(:\s*|^\s*|\[\s*|,\s*)(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?=\s*[,\]}\n]|$)/gm, '$1<span class="j-num">$2</span>')
    .replace(/(:\s*|^\s*|\[\s*|,\s*)(true|false|null)(?=\s*[,\]}\n]|$)/gm, '$1<span class="j-lit">$2</span>');
}

function kvHTML(entries) {
  const pairs = Object.entries(entries || {}).filter(([, value]) => value != null && value !== "");
  if (!pairs.length) return '<p class="muted small">None</p>';
  return '<dl class="kv">' + pairs.map(([key, value]) => "<dt>" + escapeHTML(key) + "</dt><dd>" + escapeHTML(value) + "</dd>").join("") + "</dl>";
}

// Text a person selected inside an element, if any.
function selectionInside(element) {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed) return "";
  return element.contains(selection.anchorNode) ? selection.toString() : "";
}

function hasTextSelection() {
  const selection = window.getSelection();
  return !!selection && !selection.isCollapsed;
}

// Fills a pane that polling keeps re-rendering. `key` names what the pane
// shows: a new key always renders, from the top. For the same key the markup
// is swapped only when it changed and never under text the person selected in
// it; the focused control and the scroll position survive the swap.
const PANE_FOCUS_KEYS = ["path", "offset", "dtab", "act"];
function patchPane(node, key, html) {
  const same = node.paneKey === key;
  if (same && node.paneHTML === html) return false;
  if (same && selectionInside(node)) return false;
  const active = document.activeElement;
  let focus = null;
  if (same && active && node.contains(active)) {
    const name = PANE_FOCUS_KEYS.find((candidate) => active.dataset[candidate] != null);
    if (name) focus = "[data-" + name + '="' + CSS.escape(active.dataset[name]) + '"]';
  }
  const scroll = same ? node.scrollTop : 0;
  const scrolls = same ? [...node.querySelectorAll(".dbody")].map((element) => element.scrollTop) : [];
  node.innerHTML = html;
  node.paneKey = key;
  node.paneHTML = html;
  node.scrollTop = scroll;
  node.querySelectorAll(".dbody").forEach((element, index) => { if (scrolls[index]) element.scrollTop = scrolls[index]; });
  if (focus) { const again = node.querySelector(focus); if (again) again.focus({ preventScroll: true }); }
  return true;
}

function isEditableTarget(target) {
  const element = target instanceof Element ? target : target && target.parentElement;
  return !!(element && element.closest("input, textarea, select, [contenteditable]:not([contenteditable='false'])"));
}
