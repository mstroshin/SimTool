// The command palette (⇧⌘P) and the page's keyboard shortcuts. Shortcuts
// follow Simulator.app and Xcode where they exist; tabs use ⌥1–6 because
// browsers keep ⌘1–9 for themselves.

function paletteCommands() {
  const commands = [
    ["Device", "home", "Home", "⇧⌘H", pressHome],
    ["Device", "camera", "Save screenshot", "⌘S", saveScreenshot],
    ["Device", "copy", "Copy screenshot", "", copyScreenshot],
    ["Device", "shake", "Shake", "⌃⌘Z", pressShake],
    ["Device", "keyboard", "Show or hide the software keyboard", keyboardBridge.enabled ? "⌘K" : "", toggleSoftwareKeyboard],
    ["Device", "keyboard", keyboardBridge.enabled ? "Stop typing with the Mac keyboard" : "Type with the Mac keyboard", "⇧⌘K", () => setKeyboardMode(!keyboardBridge.enabled)],
    ["Device", "paste", "Paste the Mac clipboard", "⌘V", pasteFromClipboard],
    ["Device", "photo", "Add files to Photos…", "", () => $("photosFile").click()]
  ];
  if (deviceInfo.app) {
    commands.push(["App", "stop", "Terminate " + deviceInfo.app, "", terminateApp], ["App", "relaunch", "Relaunch " + deviceInfo.app, "", relaunchApp]);
  }
  commands.push(
    ["Inspector", "panel", inspector.open ? "Hide the inspector" : "Show the inspector", "⌥⌘0", () => setInspectorOpen(!inspector.open)],
    ["Inspector", "panel", "Network", "⌥1", () => openTab("network")],
    ["Inspector", "panel", "Logs", "⌥2", () => openTab("logs")],
    ["Inspector", "panel", "State", "⌥3", () => openTab("state")],
    ["Inspector", "pick", "Accessibility", "⌥4", () => openTab("ax")],
    ["Inspector", "panel", "Tests", "⌥5", () => openTab("tests")],
    ["Inspector", "pick", "Activity — what was done to the device", "⌥6", () => openTab("activity")],
    ["Inspector", "search", "Filter the current list", "/", focusFilter],
    ["Network", network.paused ? "play" : "pause", network.paused ? "Resume the request list" : "Pause the request list", "", () => { openTab("network"); networkPause.click(); }],
    ["Network", "trash", "Clear the request list", "", () => { openTab("network"); networkClear.click(); }],
    ["Logs", "follow", logs.follow ? "Stop following new log lines" : "Follow new log lines", "", () => { openTab("logs"); logsFollow.click(); }],
    ["Logs", "trash", "Clear the log list", "", () => { openTab("logs"); logsClear.click(); }],
    ["Accessibility", "pick", ax.pick ? "Stop picking elements" : "Pick elements on the screen", "P", () => { openTab("ax"); setAxPick(!ax.pick); }],
    ["Tests", "film", "Show recorded runs", "", () => { openTab("tests"); tests.view = "history"; store("tests.view", "history"); renderTests(); }]
  );
  for (const test of tests.definitions) {
    if (!test.parseError) commands.push(["Tests", "play", "Run “" + (test.name || test.file) + "”", "", () => { openTab("tests"); tests.view = "tests"; tests.selectedFile = test.file; renderTests(); runTest(test.file); }]);
  }
  if (app.dataset.mode === "replay") commands.push(["Tests", "film", "Back to the live screen", "Esc", exitReplay]);
  const otherTheme = shownTheme() === "dark" ? "light" : "dark";
  commands.push(["View", otherTheme === "light" ? "sun" : "moon", "Use the " + otherTheme + " theme", "", toggleTheme]);
  if (theme.pinned) commands.push(["View", systemTheme() === "light" ? "sun" : "moon", "Follow the system theme (" + systemTheme() + ")", "", () => setTheme(null)]);
  commands.push(["Help", "help", "Keyboard shortcuts", "", showShortcuts]);
  return commands.map(([group, glyph, label, kbd, run]) => ({ group, glyph, label, kbd, run }));
}

// Switching tabs from the keyboard lands in the new tab's list, where ↑/↓ work
// at once — unless focus was somewhere a person is still using, like the screen.
function openTab(tab) {
  const active = document.activeElement;
  const landInList = !active || active === document.body || $("inspector").contains(active);
  if (!inspector.open) setInspectorOpen(true);
  setTab(tab);
  if (landInList) focusTabList(tab);
}

function focusTabList(tab) {
  const lists = { network: networkList, logs: logsList, ax: axList, tests: tests.view === "history" ? historyList : definitionList, activity: activityList };
  if (lists[tab]) lists[tab].focus();
  else if (tab === "state") (stateModels.querySelector('[tabindex="0"]') || stateModels).focus();
}

function focusFilter() {
  if (!inspector.open) setInspectorOpen(true);
  const filters = { network: networkFilter, logs: logsFilter, state: stateFilter, ax: axFilter, tests: testsFilter, activity: activityFilter };
  filters[inspector.tab].focus();
}

let paletteItems = [];
let paletteIndex = 0;
let paletteOpener = null;

function renderPalette() {
  const query = $("paletteInput").value.trim().toLowerCase();
  const words = query.split(/\s+/).filter(Boolean);
  paletteItems = paletteCommands().filter((command) => words.every((word) => (command.group + " " + command.label).toLowerCase().includes(word)));
  paletteIndex = Math.min(paletteIndex, Math.max(0, paletteItems.length - 1));
  const list = $("paletteList");
  list.innerHTML = "";
  let group = "";
  paletteItems.forEach((command, index) => {
    if (command.group !== group) { group = command.group; list.append(el("div", { class: "pal-group", role: "presentation", text: group })); }
    const item = el("div", { class: "pal-item", role: "option", id: "pal-" + index, "aria-selected": String(index === paletteIndex), "data-index": index },
      el("span", { html: icon(command.glyph) }), el("span", { text: command.label }), command.kbd ? el("kbd", { text: command.kbd }) : null);
    list.append(item);
  });
  if (!paletteItems.length) list.append(el("div", { class: "empty", html: "<b>No command matches</b>Try “screenshot”, “logs” or a test's name." }));
  $("paletteInput").setAttribute("aria-activedescendant", paletteItems.length ? "pal-" + paletteIndex : "");
  const selected = $("pal-" + paletteIndex);
  if (selected) selected.scrollIntoView({ block: "nearest" });
}

function openPalette() {
  closeMenu();
  closePopover();
  paletteOpener = document.activeElement;
  $("paletteScrim").hidden = false;
  $("paletteInput").value = "";
  paletteIndex = 0;
  renderPalette();
  $("paletteInput").focus();
}

function closePalette(restore) {
  if ($("paletteScrim").hidden) return false;
  $("paletteScrim").hidden = true;
  if (restore !== false && paletteOpener && paletteOpener.focus) paletteOpener.focus();
  return true;
}

function runPaletteItem(index) {
  const command = paletteItems[index];
  closePalette(false);
  if (command) command.run();
}

$("paletteInput").addEventListener("input", () => { paletteIndex = 0; renderPalette(); });
$("paletteInput").addEventListener("keydown", (event) => {
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    if (!paletteItems.length) return;
    paletteIndex = (paletteIndex + (event.key === "ArrowDown" ? 1 : paletteItems.length - 1)) % paletteItems.length;
    renderPalette();
  } else if (event.key === "Enter") {
    event.preventDefault();
    runPaletteItem(paletteIndex);
  } else if (event.key === "Escape") {
    event.preventDefault();
    closePalette();
  } else if (event.key === "Tab") {
    event.preventDefault();
  }
});
$("paletteList").addEventListener("click", (event) => {
  const item = event.target.closest(".pal-item");
  if (item) runPaletteItem(Number(item.dataset.index));
});
$("paletteScrim").addEventListener("mousedown", (event) => { if (event.target === $("paletteScrim")) closePalette(); });
$("paletteButton").addEventListener("click", openPalette);

function showShortcuts() {
  openPopover($("paletteButton"),
    "<p><b>⇧⌘P</b> commands · <b>⌥1–5</b> inspector tabs · <b>⌥⌘0</b> show or hide the inspector · <b>/</b> filter</p>" +
    "<p><b>↑ ↓</b> move in a list · <b>Enter</b> open · <b>Esc</b> close · <b>⇧F10</b> the row's menu</p>" +
    "<p><b>⇧⌘H</b> Home · <b>⌘S</b> screenshot · <b>⌃⌘Z</b> shake · <b>⇧⌘K</b> type with the Mac keyboard (⇧⌘K again releases it) · <b>⌘K</b> software keyboard while typing</p>" +
    "<p><b>⌥-drag</b> pinch or rotate · <b>⌥⇧-drag</b> two-finger pan · the wheel scrolls · <b>P</b> picks elements in Accessibility · <b>⌘↩</b> runs the selected test</p>");
}

// The chords that stay SimTool's while the Mac keyboard types into the device —
// the menu shortcuts of Simulator.app keep working there too.
function isViewerChord(event) {
  const meta = event.metaKey || event.ctrlKey;
  return (meta && event.shiftKey && !event.altKey && (event.code === "KeyP" || event.code === "KeyH")) ||
    (event.metaKey && !event.shiftKey && !event.altKey && !event.ctrlKey && event.code === "KeyS") ||
    (event.metaKey && event.ctrlKey && !event.shiftKey && event.code === "KeyZ") ||
    (event.metaKey && event.altKey && event.code === "Digit0");
}

document.addEventListener("keydown", (event) => {
  if (event.defaultPrevented) return;
  const meta = event.metaKey || event.ctrlKey;
  const editing = isEditableTarget(event.target);
  if (meta && event.shiftKey && event.code === "KeyP") { event.preventDefault(); if (!closePalette()) openPalette(); return; }
  if (!$("paletteScrim").hidden || !$("dialogScrim").hidden) return;
  if (event.key === "Escape") {
    if (closeMenu(true) || closePopover()) { event.preventDefault(); return; }
    if (editing) { event.target.blur(); return; }
    if (app.dataset.mode === "replay") { event.preventDefault(); exitReplay(); return; }
    return;
  }
  if (meta && event.shiftKey && event.code === "KeyH") { event.preventDefault(); pressHome(); return; }
  if (event.metaKey && !event.shiftKey && !event.altKey && !event.ctrlKey && event.code === "KeyS") { event.preventDefault(); saveScreenshot(); return; }
  if (event.metaKey && event.ctrlKey && event.code === "KeyZ") { event.preventDefault(); pressShake(); return; }
  if (event.metaKey && event.altKey && event.code === "Digit0") { event.preventDefault(); setInspectorOpen(!inspector.open); return; }
  if (event.altKey && !meta && /^Digit[1-6]$/.test(event.code)) { event.preventDefault(); openTab(TABS[Number(event.code.slice(5)) - 1]); return; }
  if (meta && event.key === "Enter" && inspector.tab === "tests" && tests.view === "tests" && tests.selectedFile) { event.preventDefault(); runTest(tests.selectedFile); return; }
  if (editing || keyboardBridge.enabled) return;
  if (meta && event.code === "KeyF" && inspector.open) { event.preventDefault(); focusFilter(); return; }
  if (event.key === "/" && !meta && !event.altKey) { event.preventDefault(); focusFilter(); return; }
  if (event.code === "KeyP" && !meta && !event.altKey && !event.shiftKey && inspector.tab === "ax" && inspector.open) { event.preventDefault(); setAxPick(!ax.pick); return; }
  if (event.key === " " && app.dataset.mode === "replay" && event.target === document.body) { event.preventDefault(); $("playPause").click(); }
});

// A click outside closes menus and popovers.
document.addEventListener("mousedown", (event) => {
  if (!$("menu").hidden && !$("menu").contains(event.target)) closeMenu();
  if (!$("popover").hidden && !$("popover").contains(event.target) && !event.target.closest("[aria-haspopup=dialog]")) closePopover();
});
window.addEventListener("resize", () => { closeMenu(); closePopover(); });
