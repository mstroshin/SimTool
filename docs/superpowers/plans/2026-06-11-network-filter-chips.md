# Network Filter Chips Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent include/exclude filter chips to the Network tab of the SimTool web viewer, with a right-click context menu on request rows and a `?` help popover.

**Architecture:** The web viewer is a single Swift file (`Sources/SimToolWeb/WebViewer.swift`) embedding HTML, CSS, and vanilla JS as string literals. We wrap the existing `#inspectorFilter` input in a chip-rendering field, extend `filteredNetworkEvents()` with chip semantics (exclude wins; includes are OR'd; live text is an extra AND), reuse the `axMenu` context-menu pattern for a new `networkMenu`, and persist chips in `localStorage`. Tests are XCTest string-presence assertions on the generated HTML (house style — see `testViewerEmbedsAxInspector`).

**Tech Stack:** Swift (string-embedded HTML/CSS/JS), XCTest, vanilla JavaScript, localStorage.

**Spec:** `docs/superpowers/specs/2026-06-11-network-filter-chips-design.md`

**Important Swift string-literal notes:**
- The CSS lives in a plain `"""…"""` literal — do not introduce backslashes or `\(` sequences.
- The JS lives in a raw `#"""…"""#` literal — `${…}` template syntax and `\(…)` are safe (not interpolated); never type the sequence `"""#` inside the JS.

---

### Task 1: Failing test for the whole feature

**Files:**
- Modify: `Tests/SimToolWebTests/SimToolWebTests.swift` (append a test before the closing `}` of the class, after `testStateHistoryFoldsEmbeddedModelsIntoParent`)

- [ ] **Step 1: Write the failing test**

Append this test function to the `SimToolWebTests` class:

```swift
    func testViewerEmbedsNetworkFilterChips() {
        let html = WebViewer.html()

        // Chip field scaffolding (filled in by later tasks, asserted here once).
        XCTAssertTrue(html.contains("id=\"filterChips\""), "missing chip container in the filter field")
        XCTAssertTrue(html.contains("id=\"filterHelp\""), "missing filter help button")
        XCTAssertTrue(html.contains("id=\"filterHelpPop\""), "missing filter help popover")
        // Right-click menu on network rows.
        XCTAssertTrue(html.contains("id=\"networkMenu\""), "missing network context menu")
        XCTAssertTrue(html.contains("id=\"networkMenuExclude\""), "missing Exclude menu item")
        XCTAssertTrue(html.contains("id=\"networkMenuInclude\""), "missing Include menu item")
        XCTAssertTrue(html.contains("function showNetworkMenu"), "missing network menu opener")
        XCTAssertTrue(html.contains("function chipPathForEvent"), "missing request path extraction")
        // Chip state and filtering semantics.
        XCTAssertTrue(html.contains("function addNetworkChip"), "missing chip add helper")
        XCTAssertTrue(html.contains("function renderFilterChips"), "missing chip renderer")
        XCTAssertTrue(html.contains("function networkEventHaystack"), "missing shared match haystack")
        // Chips survive a reload.
        XCTAssertTrue(html.contains("simtool.networkFilterChips"), "chips must persist in localStorage")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SimToolWebTests.testViewerEmbedsNetworkFilterChips`
Expected: FAIL on `missing chip container in the filter field` (and the rest).

- [ ] **Step 3: Commit**

```bash
git add Tests/SimToolWebTests/SimToolWebTests.swift
git commit -m "test(web): add failing test for network filter chips"
```

---

### Task 2: HTML and CSS scaffolding

**Files:**
- Modify: `Sources/SimToolWeb/WebViewer.swift:52` (HTML: wrap the filter input, add `?` button)
- Modify: `Sources/SimToolWeb/WebViewer.swift:88-90` (HTML: network menu + help popover next to `axMenu`)
- Modify: `Sources/SimToolWeb/WebViewer.swift:182` (CSS: replace the `.inspector-filter` rule)

- [ ] **Step 1: Wrap the filter input and add the help button**

In the `html()` HTML literal, replace this line (currently line 52):

```html
          <input id="inspectorFilter" class="inspector-filter" type="search" placeholder="filter service / status / host" />
```

with:

```html
          <div id="filterField" class="filter-field">
            <span id="filterChips" class="filter-chips"></span>
            <input id="inspectorFilter" class="inspector-filter" type="search" placeholder="filter service / status / host" />
          </div>
          <button id="filterHelp" class="filter-help" type="button" title="Filter help">?</button>
```

(Keep the surrounding indentation consistent with the neighboring tab buttons.)

- [ ] **Step 2: Add the network context menu and help popover elements**

Directly after the existing `axMenu` block:

```html
    <div id="axMenu" class="ax-menu" hidden>
      <button id="axMenuCopy" class="ax-menu-item" type="button">Copy element</button>
    </div>
```

add:

```html
    <div id="networkMenu" class="ax-menu" hidden>
      <button id="networkMenuExclude" class="ax-menu-item" type="button">Exclude</button>
      <button id="networkMenuInclude" class="ax-menu-item" type="button">Include</button>
    </div>
    <div id="filterHelpPop" class="filter-help-pop" hidden>
      <p><b>type text</b> — live substring filter (method, url, status, protocol, host)</p>
      <p><b>Enter</b> — turn the text into an include chip (show only matches)</p>
      <p><b>-text + Enter</b> — exclude chip (hide matches)</p>
      <p><b>right-click a request</b> — include/exclude its path</p>
    </div>
```

- [ ] **Step 3: Replace the filter CSS**

In the `css` literal, replace this single rule (currently line 182; keep the `.inspector-filter:disabled` rule on the next line untouched):

```css
.inspector-filter { margin-left: auto; min-width: 0; width: 130px; background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.14); border-radius: 8px; color: #f4f7fb; padding: 4px 8px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; }
```

with:

```css
.filter-field { margin-left: auto; min-width: 0; max-width: 60%; display: flex; flex-wrap: wrap; align-items: center; gap: 3px; padding: 2px 4px; background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.14); border-radius: 8px; }
.filter-field:focus-within { border-color: rgba(125,211,252,0.5); }
.filter-chips { display: contents; }
.inspector-filter { min-width: 60px; width: 110px; flex: 1 1 60px; background: none; border: 0; outline: none; color: #f4f7fb; padding: 2px 4px; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; }
.filter-chip { display: inline-flex; align-items: center; gap: 4px; max-width: 150px; padding: 1px 4px 1px 6px; border-radius: 6px; border: 1px solid; font: 10px ui-monospace, SFMono-Regular, Menlo, monospace; }
.filter-chip.include { color: #86efac; border-color: rgba(74,222,128,0.4); background: rgba(74,222,128,0.10); }
.filter-chip.exclude { color: #fda4af; border-color: rgba(248,113,113,0.4); background: rgba(248,113,113,0.10); }
.filter-chip .chip-term { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.filter-chip-x { appearance: none; border: 0; background: none; color: inherit; cursor: pointer; padding: 0 2px; font-size: 9px; opacity: 0.65; }
.filter-chip-x:hover { opacity: 1; }
.filter-help { appearance: none; flex: 0 0 auto; width: 18px; height: 18px; display: grid; place-items: center; border: 1px solid rgba(255,255,255,0.14); border-radius: 999px; background: rgba(255,255,255,0.06); color: rgba(244,247,251,0.6); font-size: 10px; cursor: pointer; }
.filter-help:hover { background: rgba(255,255,255,0.10); color: #cdd6e6; }
.filter-help[hidden] { display: none; }
.filter-help-pop { position: fixed; z-index: 10; max-width: 300px; padding: 8px 10px; background: #0b1020; border: 1px solid rgba(255,255,255,0.16); border-radius: 9px; box-shadow: 0 12px 32px rgba(0,0,0,0.55); font: 11px ui-sans-serif, system-ui, sans-serif; color: rgba(244,247,251,0.85); }
.filter-help-pop[hidden] { display: none; }
.filter-help-pop p { margin: 0 0 6px; }
.filter-help-pop p:last-child { margin-bottom: 0; }
.filter-help-pop b { color: #bae6fd; }
```

Note: `.filter-help[hidden]` / `.filter-help-pop[hidden]` rules are required — the explicit `display` values would otherwise override the UA's `[hidden]` handling (same pattern as `.ax-menu[hidden]` at line 263).

- [ ] **Step 4: Build and run the test**

Run: `swift build && swift test --filter SimToolWebTests`
Expected: build succeeds; `testViewerEmbedsNetworkFilterChips` still FAILS, but now only on the JS assertions (`function showNetworkMenu`, `function addNetworkChip`, …). All other `SimToolWebTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimToolWeb/WebViewer.swift
git commit -m "feat(web): add filter chip field, help button, and menu markup"
```

---

### Task 3: Chip state, rendering, input handling, persistence

**Files:**
- Modify: `Sources/SimToolWeb/WebViewer.swift:324` (JS: element refs after `axMenuCopy`)
- Modify: `Sources/SimToolWeb/WebViewer.swift:644` (JS: chip state in the `---- Network ----` section)
- Modify: `Sources/SimToolWeb/WebViewer.swift:1555-1557` (JS: `setActiveTab` visibility)
- Modify: `Sources/SimToolWeb/WebViewer.swift:1596-1602` (JS: keydown listener after the existing `input` listener)

- [ ] **Step 1: Add element references**

In the JS literal, after the line `const axMenuCopy = $("axMenuCopy");` add:

```js
    const filterChips = $("filterChips");
    const filterHelp = $("filterHelp");
    const filterHelpPop = $("filterHelpPop");
    const networkMenu = $("networkMenu");
    const networkMenuExclude = $("networkMenuExclude");
    const networkMenuInclude = $("networkMenuInclude");
```

- [ ] **Step 2: Add chip state, persistence, and rendering**

In the `// ---- Network ----` section, directly after `let networkTimer = null;` add:

```js
    // Include/exclude filter chips (Network tab only). Persisted across reloads.
    const NETWORK_CHIPS_KEY = "simtool.networkFilterChips";
    let networkChips = [];
    try {
      const stored = JSON.parse(localStorage.getItem(NETWORK_CHIPS_KEY) || "[]");
      if (Array.isArray(stored)) {
        networkChips = stored.filter((chip) =>
          chip && (chip.kind === "include" || chip.kind === "exclude")
          && typeof chip.term === "string" && chip.term.trim()
        );
      }
    } catch (_) { /* malformed storage: start clean */ }

    function saveNetworkChips() {
      try { localStorage.setItem(NETWORK_CHIPS_KEY, JSON.stringify(networkChips)); } catch (_) {}
    }

    // Adding a chip replaces any chip with the same term (either kind), so an
    // exclude flips an identical include instead of stacking next to it.
    function addNetworkChip(kind, term) {
      const trimmed = term.trim();
      if (!trimmed) return;
      const key = trimmed.toLowerCase();
      networkChips = networkChips.filter((chip) => chip.term.toLowerCase() !== key);
      networkChips.push({ kind, term: trimmed });
      saveNetworkChips();
      renderFilterChips();
      renderNetworkList();
    }

    function removeNetworkChip(index) {
      networkChips.splice(index, 1);
      saveNetworkChips();
      renderFilterChips();
      renderNetworkList();
    }

    function renderFilterChips() {
      filterChips.innerHTML = "";
      if (activeTab !== "network") return;
      networkChips.forEach((chip, index) => {
        const el = document.createElement("span");
        el.className = "filter-chip " + chip.kind;
        const term = document.createElement("span");
        term.className = "chip-term";
        term.textContent = (chip.kind === "exclude" ? "−" : "") + chip.term;
        term.title = chip.term;
        const x = document.createElement("button");
        x.type = "button";
        x.className = "filter-chip-x";
        x.textContent = "✕";
        x.title = "Remove filter";
        x.addEventListener("click", () => removeNetworkChip(index));
        el.append(term, x);
        filterChips.appendChild(el);
      });
    }
```

(`renderFilterChips` reads `activeTab`, declared later with `let` — safe because the function is only called after that declaration runs.)

- [ ] **Step 3: Show chips and the help button only on the Network tab**

In `setActiveTab`, after the line `inspectorFilter.disabled = false;` add:

```js
      filterHelp.hidden = tab !== "network";
      renderFilterChips();
      if (tab !== "network") { hideNetworkMenu(); hideFilterHelp(); }
```

(`hideNetworkMenu`/`hideFilterHelp` are defined in Task 5 — until then this breaks tab switching at runtime, which is fine mid-feature; the build and string-presence tests don't execute JS.)

- [ ] **Step 4: Add Enter / `-term` / Backspace handling**

Directly after the existing `inspectorFilter.addEventListener("input", …)` block (ends at line 1602) add:

```js
    inspectorFilter.addEventListener("keydown", (event) => {
      if (activeTab !== "network") return;
      if (event.key === "Enter") {
        const text = inspectorFilter.value.trim();
        if (!text) return;
        event.preventDefault();
        if (text.startsWith("-")) addNetworkChip("exclude", text.slice(1));
        else addNetworkChip("include", text);
        inspectorFilter.value = "";
        filterByTab.network = "";
        renderNetworkList();
      } else if (event.key === "Backspace" && !inspectorFilter.value && networkChips.length) {
        removeNetworkChip(networkChips.length - 1);
      }
    });
```

- [ ] **Step 5: Build and run the test**

Run: `swift build && swift test --filter SimToolWebTests`
Expected: build succeeds; `testViewerEmbedsNetworkFilterChips` still FAILS only on `function showNetworkMenu`, `function chipPathForEvent`, and `function networkEventHaystack`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimToolWeb/WebViewer.swift
git commit -m "feat(web): add network filter chip state, input handling, persistence"
```

---

### Task 4: Filtering semantics

**Files:**
- Modify: `Sources/SimToolWeb/WebViewer.swift:702-711` (JS: replace `filteredNetworkEvents`)

- [ ] **Step 1: Replace `filteredNetworkEvents` with chip-aware filtering**

Replace the existing function:

```js
    function filteredNetworkEvents() {
      const query = (filterByTab.network || "").trim().toLowerCase();
      if (!query) return networkEvents;
      return networkEvents.filter((event) => {
        const request = event.request || {};
        const hay = [summarizeRequest(event), summarizeStatus(event), event.protocol, request.host]
          .filter(Boolean).join(" ").toLowerCase();
        return hay.includes(query);
      });
    }
```

with:

```js
    function networkEventHaystack(event) {
      const request = event.request || {};
      return [summarizeRequest(event), summarizeStatus(event), event.protocol, request.host]
        .filter(Boolean).join(" ").toLowerCase();
    }

    // Exclude chips win over include chips; include chips are OR'd ("show only
    // these"); live input text is an extra substring filter on top.
    function filteredNetworkEvents() {
      const query = (filterByTab.network || "").trim().toLowerCase();
      const excludes = networkChips.filter((chip) => chip.kind === "exclude").map((chip) => chip.term.toLowerCase());
      const includes = networkChips.filter((chip) => chip.kind === "include").map((chip) => chip.term.toLowerCase());
      if (!query && !excludes.length && !includes.length) return networkEvents;
      return networkEvents.filter((event) => {
        const hay = networkEventHaystack(event);
        if (excludes.some((term) => hay.includes(term))) return false;
        if (includes.length && !includes.some((term) => hay.includes(term))) return false;
        return !query || hay.includes(query);
      });
    }
```

- [ ] **Step 2: Build and run the test**

Run: `swift build && swift test --filter SimToolWebTests`
Expected: build succeeds; `testViewerEmbedsNetworkFilterChips` still FAILS only on `function showNetworkMenu` and `function chipPathForEvent`.

- [ ] **Step 3: Commit**

```bash
git add Sources/SimToolWeb/WebViewer.swift
git commit -m "feat(web): apply include/exclude chips in network filtering"
```

---

### Task 5: Context menu and help popover wiring

**Files:**
- Modify: `Sources/SimToolWeb/WebViewer.swift:654-660` (JS: add `chipPathForEvent` after `requestPath`)
- Modify: `Sources/SimToolWeb/WebViewer.swift:753-758` (JS: `contextmenu` listener on network rows)
- Modify: `Sources/SimToolWeb/WebViewer.swift:1342-1345` (JS: menu/popover functions after `hideAxMenu`)
- Modify: `Sources/SimToolWeb/WebViewer.swift:1580-1588` (JS: `setInspectorOpen` close branch)
- Modify: `Sources/SimToolWeb/WebViewer.swift:1711-1714` (JS: global wiring)

- [ ] **Step 1: Add `chipPathForEvent`**

Directly after the `requestPath` function add:

```js
    // URL path without host/query for context-menu chips (gRPC: service/method).
    function chipPathForEvent(event) {
      const raw = requestPath(event);
      if (!raw) return "";
      if (event.protocol === "grpc") return raw;
      try { return new URL(raw, "http://localhost").pathname; } catch (_) { return raw; }
    }
```

- [ ] **Step 2: Add the menu and popover open/close functions**

Directly after the `hideAxMenu` function add:

```js
    // Right-click menu on network rows: include/exclude the request path.
    let networkMenuPath = "";
    function showNetworkMenu(x, y, path) {
      networkMenuPath = path;
      const short = path.length > 42 ? "…" + path.slice(-41) : path;
      networkMenuExclude.textContent = "Exclude '" + short + "'";
      networkMenuInclude.textContent = "Include '" + short + "'";
      networkMenu.hidden = false;
      const rect = networkMenu.getBoundingClientRect();
      networkMenu.style.left = Math.max(6, Math.min(x, window.innerWidth - rect.width - 6)) + "px";
      networkMenu.style.top = Math.max(6, Math.min(y, window.innerHeight - rect.height - 6)) + "px";
    }
    function hideNetworkMenu() {
      networkMenu.hidden = true;
      networkMenuPath = "";
    }

    function showFilterHelp() {
      filterHelpPop.hidden = false;
      const button = filterHelp.getBoundingClientRect();
      const rect = filterHelpPop.getBoundingClientRect();
      filterHelpPop.style.left = Math.max(6, Math.min(button.left, window.innerWidth - rect.width - 6)) + "px";
      filterHelpPop.style.top = (button.bottom + 6) + "px";
    }
    function hideFilterHelp() { filterHelpPop.hidden = true; }
```

- [ ] **Step 3: Open the menu from network rows**

In `renderNetworkList`, the row click listener currently reads:

```js
        row.addEventListener("click", () => {
          networkSelectedId = event.id;
          renderNetworkDetail(event);
          showDetailView("Network");
        });
```

Directly after that block (before `networkList.appendChild(row);`) add — note the DOM event parameter is named `domEvent` because `event` is the network event from the enclosing `for (const event of ordered)` loop:

```js
        row.addEventListener("contextmenu", (domEvent) => {
          domEvent.preventDefault();
          const path = chipPathForEvent(event);
          if (!path) return;
          showNetworkMenu(domEvent.clientX, domEvent.clientY, path);
        });
```

- [ ] **Step 4: Close the menu and popover when the inspector closes**

In `setInspectorOpen`, in the `else` branch, after `hideAxMenu();` add:

```js
        hideNetworkMenu();
        hideFilterHelp();
```

- [ ] **Step 5: Wire menu items, help button, and global dismissal**

In the `// ---- Wiring ----` section, replace these four lines:

```js
    axMenuCopy.addEventListener("click", () => { copyAxNode(axMenuNode); hideAxMenu(); });
    document.addEventListener("click", (event) => { if (!axMenu.hidden && !axMenu.contains(event.target)) hideAxMenu(); });
    document.addEventListener("keydown", (event) => { if (event.key === "Escape") hideAxMenu(); });
    window.addEventListener("scroll", () => hideAxMenu(), true);
```

with:

```js
    axMenuCopy.addEventListener("click", () => { copyAxNode(axMenuNode); hideAxMenu(); });
    networkMenuExclude.addEventListener("click", () => { addNetworkChip("exclude", networkMenuPath); hideNetworkMenu(); });
    networkMenuInclude.addEventListener("click", () => { addNetworkChip("include", networkMenuPath); hideNetworkMenu(); });
    filterHelp.addEventListener("click", (event) => {
      event.stopPropagation();
      if (filterHelpPop.hidden) showFilterHelp(); else hideFilterHelp();
    });
    function hidePopups() { hideAxMenu(); hideNetworkMenu(); hideFilterHelp(); }
    document.addEventListener("click", (event) => {
      if (!axMenu.hidden && !axMenu.contains(event.target)) hideAxMenu();
      if (!networkMenu.hidden && !networkMenu.contains(event.target)) hideNetworkMenu();
      if (!filterHelpPop.hidden && !filterHelpPop.contains(event.target)) hideFilterHelp();
    });
    document.addEventListener("keydown", (event) => { if (event.key === "Escape") hidePopups(); });
    window.addEventListener("scroll", () => hidePopups(), true);
```

- [ ] **Step 6: Build and run the test — everything passes now**

Run: `swift build && swift test --filter SimToolWebTests`
Expected: build succeeds; ALL `SimToolWebTests` PASS, including `testViewerEmbedsNetworkFilterChips`.

- [ ] **Step 7: Commit**

```bash
git add Sources/SimToolWeb/WebViewer.swift
git commit -m "feat(web): wire network context menu and filter help popover"
```

---

### Task 6: Full test suite and manual verification

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: all tests PASS.

- [ ] **Step 2: Manual verification in the browser**

Start the viewer (the project's run skill / `simtool run` with a booted simulator), open the web UI, enable Inspect, and on the Network tab verify:

1. Typing text live-filters the list (unchanged behavior).
2. `api` + Enter → green include chip; only matching requests remain; input clears.
3. `-health` + Enter → red `−health` chip; matching requests disappear.
4. Exclude wins: with include `api` and exclude `api`-matching term, the matching rows stay hidden.
5. Two include chips behave as OR (rows matching either remain).
6. ✕ on a chip removes it; Backspace in the empty input removes the last chip.
7. Right-click a request row → menu with `Exclude '/path'` / `Include '/path'`; clicking adds the chip; menu closes on outside click, Escape, and scroll.
8. Adding exclude for a term that exists as include replaces the include chip (and vice versa); no duplicate chips.
9. `?` button toggles the help popover; it closes on outside click and Escape.
10. Reload the page → chips are restored; live input text is not.
11. Logs/State/AX tabs: chips and `?` disappear; their filters work as before.

- [ ] **Step 3: Fix anything found, re-run `swift test`, commit fixes**

```bash
git add -A
git commit -m "fix(web): address manual verification findings for filter chips"
```

(Skip this commit if nothing was found.)
