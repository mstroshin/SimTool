# Web Viewer AX Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the web viewer's stub "AX" tab into a working accessibility inspector — a live tree, screen overlays, two-way selection, and a full-JSON copy button.

**Architecture:** Front-end-only changes to `Sources/SimToolWeb/WebViewer.swift` (HTML, CSS, embedded JS). The backend `GET /api/v1/ax/tree` already returns the normalized tree (with `frame`, identifiers, `raw`). The tree is polled every ~2s; AX `frame` points are normalized against the largest-area node (the full-screen window) and drawn as percentage-positioned overlay boxes inside `.surface`. While the AX tab is active, canvas clicks select instead of forwarding taps.

**Tech Stack:** Swift (string-templated HTML/CSS/JS), vanilla browser JS (no framework), Swifter HTTP server (unchanged), XCTest for the HTML smoke test.

---

## File Structure

- **Modify:** `Sources/SimToolWeb/WebViewer.swift`
  - HTML: replace the `#axPane` stub; add `#axOverlay` inside `.surface`.
  - CSS: replace the `.ax-pane` / `.ax-soon` block with the AX inspector styles.
  - JS: add an `// ---- Accessibility (AX) ----` section; wire it into `setActiveTab`, `setInspectorOpen`, the canvas `pointerup` handler, and the filter input handler.
- **Modify:** `Tests/SimToolWebTests/SimToolWebTests.swift` — add one smoke test for the AX anchors.

All five tasks edit the same file, so execute them in order (no parallelism).

---

### Task 1: HTML + CSS scaffolding and smoke test

**Files:**
- Modify: `Tests/SimToolWebTests/SimToolWebTests.swift`
- Modify: `Sources/SimToolWeb/WebViewer.swift` (HTML around lines 60-63 and 30-31; CSS around lines 193-195)

- [ ] **Step 1: Write the failing smoke test**

Add this method to `final class SimToolWebTests` in `Tests/SimToolWebTests/SimToolWebTests.swift`:

```swift
    func testViewerEmbedsAxInspector() {
        let html = WebViewer.html()

        // AX panel scaffolding
        XCTAssertTrue(html.contains("id=\"axTree\""), "missing AX tree container")
        XCTAssertTrue(html.contains("id=\"axOverlay\""), "missing AX overlay layer")
        XCTAssertTrue(html.contains("id=\"axCopy\""), "missing AX copy button")
        XCTAssertTrue(html.contains("id=\"axRefresh\""), "missing AX refresh button")
        XCTAssertTrue(html.contains("id=\"axSelectedBar\""), "missing AX selected-element bar")
        // The old placeholder copy must be gone.
        XCTAssertFalse(html.contains("Бэкенд уже отдаёт его"), "AX stub placeholder must be removed")
        // Behavior anchors (filled in by later tasks, asserted here once).
        XCTAssertTrue(html.contains("/api/v1/ax/tree"), "AX inspector must poll the tree endpoint")
        XCTAssertTrue(html.contains("function renderAxTree"), "missing AX tree renderer")
        XCTAssertTrue(html.contains("function axHitTest"), "missing AX hit-test")
        XCTAssertTrue(html.contains("function axCopyPayload"), "missing AX copy payload builder")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SimToolWebTests.testViewerEmbedsAxInspector`
Expected: FAIL — assertions about `id="axTree"` etc. fail (anchors not present yet).

- [ ] **Step 3: Add the overlay layer to the surface**

In `WebViewer.swift`, change the surface block (currently lines 29-31):

```html
                  <div id="surface" class="surface">
                    <canvas id="screen" aria-label="Simulator stream"></canvas>
                  </div>
```

to:

```html
                  <div id="surface" class="surface">
                    <canvas id="screen" aria-label="Simulator stream"></canvas>
                    <div id="axOverlay" class="ax-overlay" hidden></div>
                  </div>
```

- [ ] **Step 4: Replace the `#axPane` stub markup**

Replace the stub (currently lines 60-63):

```html
                    <div id="axPane" class="ax-pane scroll-pane" hidden>
                      <span class="ax-soon">Accessibility IDs</span>
                      <p>Дерево элементов с accessibility id появится здесь. Бэкенд уже отдаёт его по <code>/api/v1/ax/tree</code>.</p>
                    </div>
```

with:

```html
                    <div id="axPane" class="ax-pane" hidden>
                      <div class="ax-toolbar">
                        <button id="axRefresh" class="ax-refresh" type="button" title="Refresh tree">⟳</button>
                        <span id="axStatus" class="ax-status">—</span>
                      </div>
                      <div id="axSelectedBar" class="ax-selected-bar" hidden>
                        <span id="axSelectedLabel" class="ax-selected-label">—</span>
                        <button id="axCopy" class="ax-copy" type="button">Copy JSON</button>
                      </div>
                      <div id="axTree" class="ax-tree"></div>
                    </div>
```

- [ ] **Step 5: Replace the AX CSS block**

Replace the three `.ax-pane` / `.ax-soon` rules (currently lines 193-195):

```css
    .ax-pane { padding: 14px; color: rgba(244,247,251,0.6); font: 12px ui-sans-serif, system-ui, sans-serif; line-height: 1.6; }
    .ax-pane code { font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: #7dd3fc; }
    .ax-soon { display: inline-block; font: 10px ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: 0.1em; text-transform: uppercase; color: rgba(244,247,251,0.42); border: 1px dashed rgba(255,255,255,0.22); padding: 3px 8px; border-radius: 7px; margin-bottom: 10px; }
```

with:

```css
    /* AX inspector: toolbar + selected-element bar + scrollable tree. */
    .ax-pane { display: flex; flex-direction: column; min-height: 0; flex: 1 1 auto; }
    .ax-pane[hidden] { display: none; }
    .ax-toolbar { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border-bottom: 1px solid rgba(255,255,255,0.08); }
    .ax-refresh { appearance: none; width: 26px; height: 24px; display: grid; place-items: center; border: 1px solid rgba(255,255,255,0.14); border-radius: 7px; background: rgba(255,255,255,0.06); color: #cdd6e6; cursor: pointer; font-size: 13px; }
    .ax-refresh:hover { background: rgba(255,255,255,0.10); }
    .ax-status { font: 10px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.55); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .ax-selected-bar { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border-bottom: 1px solid rgba(255,255,255,0.08); background: rgba(125,211,252,0.06); }
    .ax-selected-bar[hidden] { display: none; }
    .ax-selected-label { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; color: #bae6fd; }
    .ax-copy { appearance: none; border: 1px solid rgba(125,211,252,0.4); border-radius: 7px; background: rgba(125,211,252,0.14); color: #bae6fd; padding: 4px 10px; font: 11px ui-sans-serif, system-ui, sans-serif; cursor: pointer; white-space: nowrap; }
    .ax-copy:hover { background: rgba(125,211,252,0.22); }
    .ax-tree { overflow: auto; flex: 1 1 auto; min-height: 0; padding: 4px 0; }
    .ax-row { display: flex; align-items: center; gap: 6px; padding: 3px 10px 3px 0; cursor: pointer; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; white-space: nowrap; }
    .ax-row:hover { background: rgba(255,255,255,0.05); }
    .ax-row.selected { background: rgba(125,211,252,0.16); }
    .ax-chevron { display: inline-block; width: 12px; text-align: center; color: rgba(244,247,251,0.5); flex: 0 0 auto; }
    .ax-label { color: #f4f7fb; overflow: hidden; text-overflow: ellipsis; }
    .ax-secondary { color: rgba(244,247,251,0.4); flex: 0 0 auto; }
    .ax-empty { display: block; padding: 12px; color: rgba(244,247,251,0.5); font: 12px ui-sans-serif, system-ui, sans-serif; }

    /* AX overlays drawn over the device image (never into the video canvas). */
    .ax-overlay { position: absolute; inset: 0; pointer-events: none; z-index: 2; }
    .ax-overlay[hidden] { display: none; }
    .ax-box { position: absolute; border: 1px solid rgba(125,211,252,0.32); box-sizing: border-box; }
    .ax-box.hover { border-color: rgba(125,211,252,0.85); background: rgba(125,211,252,0.12); }
    .ax-box.selected { border: 2px solid #7dd3fc; background: rgba(125,211,252,0.20); box-shadow: 0 0 0 1px rgba(7,10,18,0.6); }
    canvas.ax-pick { cursor: default; }
```

> Note: the smoke test in Step 1 also asserts `function renderAxTree`, `function axHitTest`, and `function axCopyPayload`, which are added in Tasks 2–5. The test will not fully pass until Task 5. That is intentional — it is the single behavioral guard for the whole feature. Build (not the full test) is the per-task gate for Tasks 1–4.

- [ ] **Step 6: Build to verify the scaffolding compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/SimToolWeb/WebViewer.swift Tests/SimToolWebTests/SimToolWebTests.swift
git commit -m "feat(web): scaffold AX inspector panel and overlay layer"
```

---

### Task 2: Fetch, render, poll, and filter the tree

**Files:**
- Modify: `Sources/SimToolWeb/WebViewer.swift` (JS section)

- [ ] **Step 1: Add AX DOM references**

In the DOM-reference block, immediately after `const axPane = $("axPane");` (currently line 239), add:

```js
    const axTreeEl = $("axTree");
    const axOverlay = $("axOverlay");
    const axStatusEl = $("axStatus");
    const axRefreshButton = $("axRefresh");
    const axSelectedBar = $("axSelectedBar");
    const axSelectedLabel = $("axSelectedLabel");
    const axCopyButton = $("axCopy");
```

- [ ] **Step 2: Add the AX section (state, indexing, render, polling)**

Insert this whole block immediately before the `// ---- Inspector shell:` comment (currently line 904):

```js
    // ---- Accessibility (AX) ----

    let axTree = null;            // { roots, nodeCount }
    let axNodesByKey = new Map(); // node.id -> node (augmented with _key/_parentKey/_depth)
    let axExpanded = new Set();   // expanded node keys
    let axSelectedKey = null;
    let axHoverKey = null;
    let axTimer = null;
    let axFetching = false;
    let axLastUpdated = 0;
    let axFilter = "";

    function axHasFrame(node) {
      const f = node.frame;
      return !!(f && f.width > 0 && f.height > 0);
    }

    function axNodeLabel(node) {
      return node.accessibilityIdentifier || node.label || node.title
          || node.value || node.role || node.type || "element";
    }

    function axNodeSecondary(node) {
      return [node.role, node.type].filter(Boolean).join(" · ");
    }

    // Screen reference = the largest-area ROOT frame (the AXApplication, in points).
    // Only roots are considered: some deep container groups report their frame in
    // device pixels (e.g. 1206x2622 = 3x), which would otherwise hijack the reference.
    function axScreenFrame() {
      if (!axTree) return null;
      let best = null, bestArea = 0;
      for (const root of (axTree.roots || [])) {
        const f = root.frame;
        if (!f || !f.width || !f.height) continue;
        const area = f.width * f.height;
        if (area > bestArea) { bestArea = area; best = f; }
      }
      return best;
    }

    function axIndex(tree) {
      const byKey = new Map();
      const walk = (node, parentKey, depth) => {
        node._key = node.id;
        node._parentKey = parentKey;
        node._depth = depth;
        byKey.set(node.id, node);
        for (const child of node.children || []) walk(child, node.id, depth + 1);
      };
      for (const root of (tree.roots || [])) walk(root, null, 0);
      axNodesByKey = byKey;
    }

    function axMatches(node, q) {
      const hay = [node.accessibilityIdentifier, node.label, node.value, node.title, node.role, node.roleDescription, node.type]
        .filter(Boolean).join(" ").toLowerCase();
      return hay.includes(q);
    }

    function axRow(node, expanded) {
      const hasChildren = (node.children || []).length > 0;
      const row = document.createElement("div");
      row.className = "ax-row" + (node._key === axSelectedKey ? " selected" : "");
      row.style.paddingLeft = (8 + node._depth * 14) + "px";
      row.dataset.key = node._key;

      const chevron = document.createElement("span");
      chevron.className = "ax-chevron";
      chevron.textContent = hasChildren ? (expanded ? "▾" : "▸") : "";
      if (hasChildren) {
        chevron.addEventListener("click", (event) => {
          event.stopPropagation();
          if (axExpanded.has(node._key)) axExpanded.delete(node._key);
          else axExpanded.add(node._key);
          renderAxTree();
        });
      }

      const label = document.createElement("span");
      label.className = "ax-label";
      label.textContent = axNodeLabel(node);

      const secondary = document.createElement("span");
      secondary.className = "ax-secondary";
      secondary.textContent = axNodeSecondary(node);

      row.append(chevron, label, secondary);
      row.addEventListener("click", () => selectAxNode(node._key, false));
      row.addEventListener("mouseenter", () => { axHoverKey = node._key; renderAxOverlay(); });
      row.addEventListener("mouseleave", () => { if (axHoverKey === node._key) { axHoverKey = null; renderAxOverlay(); } });
      return row;
    }

    function renderAxTree() {
      if (!axTree) { axTreeEl.innerHTML = '<span class="ax-empty">no accessibility tree</span>'; return; }
      const q = axFilter.trim().toLowerCase();
      let showKeys = null;
      if (q) {
        showKeys = new Set();
        for (const node of axNodesByKey.values()) {
          if (!axMatches(node, q)) continue;
          showKeys.add(node._key);
          let pk = node._parentKey;
          while (pk != null && !showKeys.has(pk)) {
            showKeys.add(pk);
            const parent = axNodesByKey.get(pk);
            pk = parent ? parent._parentKey : null;
          }
        }
      }
      const rows = [];
      const walk = (node) => {
        if (showKeys && !showKeys.has(node._key)) return;
        const expanded = q ? true : axExpanded.has(node._key);
        rows.push(axRow(node, expanded));
        if (expanded) for (const child of (node.children || [])) walk(child);
      };
      for (const root of (axTree.roots || [])) walk(root);
      axTreeEl.innerHTML = "";
      if (!rows.length) { axTreeEl.innerHTML = '<span class="ax-empty">no matches</span>'; return; }
      for (const row of rows) axTreeEl.appendChild(row);
    }

    function updateAxStatus() {
      const count = axTree ? axTree.nodeCount : 0;
      axStatusEl.textContent = axTree ? `${count} nodes · updated just now` : "—";
    }

    async function loadAxTree() {
      if (axFetching) return;
      axFetching = true;
      try {
        const response = await api("/api/v1/ax/tree");
        const payload = await response.json();
        axTree = payload;
        axIndex(payload);
        axLastUpdated = performance.now();
        if (activeTab === "ax" && inspectorOpen) {
          renderAxTree();
          renderAxSelected();
          renderAxOverlay();
          updateAxStatus();
        }
      } catch (error) {
        axStatusEl.textContent = `error: ${error.message}`;
      } finally {
        axFetching = false;
      }
    }

    function startAxPolling() {
      loadAxTree();
      if (!axTimer) axTimer = setInterval(loadAxTree, 2000);
    }

    function stopAxPolling() {
      if (axTimer) { clearInterval(axTimer); axTimer = null; }
    }
```

> `selectAxNode`, `renderAxSelected`, and `renderAxOverlay` are referenced here but defined in Tasks 3–5. They are function declarations, so hoisting makes the references valid at call time. Until Task 4/5 add them, do not switch to the AX tab at runtime — `swift build` still succeeds because JS is an opaque string to Swift.

- [ ] **Step 3: Wire AX into the tab switch and filter**

Replace the `setActiveTab` function (currently lines 930-943) with:

```js
    function setActiveTab(tab) {
      activeTab = tab;
      for (const key in tabButtons) tabButtons[key].classList.toggle("active", key === tab);
      networkList.hidden = tab !== "network";
      logsControls.hidden = tab !== "logs";
      logsList.hidden = tab !== "logs";
      axPane.hidden = tab !== "ax";
      inspectorFilter.value = filterByTab[tab] || "";
      inspectorFilter.placeholder = FILTER_PLACEHOLDER[tab] || "";
      inspectorFilter.disabled = false;
      showListView();
      if (tab === "network") renderNetworkList();
      else if (tab === "logs") { renderLogsList(); ensureLogs(); }
      else if (tab === "ax") { renderAxTree(); renderAxSelected(); }
      if (tab === "ax") startAxPolling(); else stopAxPolling();
      axUpdateCanvasMode();
      renderAxOverlay();
    }
```

Replace the `FILTER_PLACEHOLDER` object (currently lines 911-915) with:

```js
    const FILTER_PLACEHOLDER = {
      network: "filter service / status / host",
      logs: "filter message / subsystem",
      ax: "filter id / label / role"
    };
```

Change `const filterByTab = { network: "", logs: "" };` (currently line 909) to:

```js
    const filterByTab = { network: "", logs: "", ax: "" };
```

Replace the `inspectorFilter` input handler (currently lines 966-971) with:

```js
    inspectorFilter.addEventListener("input", () => {
      filterByTab[activeTab] = inspectorFilter.value;
      if (activeTab === "network") renderNetworkList();
      else if (activeTab === "logs") renderLogsList();
      else if (activeTab === "ax") { axFilter = inspectorFilter.value; renderAxTree(); }
    });
```

- [ ] **Step 4: Stop AX polling and hide overlay when the inspector closes**

In `setInspectorOpen`, replace the `else` branch (currently lines 955-958):

```js
      } else {
        stopNetworkPolling();
        stopLogsPolling();
      }
```

with:

```js
      } else {
        stopNetworkPolling();
        stopLogsPolling();
        stopAxPolling();
        axUpdateCanvasMode();
        renderAxOverlay();
      }
```

- [ ] **Step 5: Wire the manual refresh button**

In the `// ---- Wiring ----` section, after `shotButton.addEventListener("click", downloadScreenshot);` (currently line 1031), add:

```js
    axRefreshButton.addEventListener("click", loadAxTree);
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: build succeeds. (Switching to the AX tab at runtime is not safe yet — see the note in Step 2.)

- [ ] **Step 7: Commit**

```bash
git add Sources/SimToolWeb/WebViewer.swift
git commit -m "feat(web): fetch, render, poll, and filter the AX tree"
```

---

### Task 3: Overlay rendering and coordinate mapping

**Files:**
- Modify: `Sources/SimToolWeb/WebViewer.swift` (JS section)

- [ ] **Step 1: Add `axFrameToBox` and `renderAxOverlay`**

In the AX section (after `stopAxPolling`, before the Inspector shell comment), add:

```js
    // Frame points -> percentage box within .surface (percentages auto-track resize).
    function axFrameToBox(frame, screen) {
      return {
        left: ((frame.x - screen.x) / screen.width) * 100,
        top: ((frame.y - screen.y) / screen.height) * 100,
        width: (frame.width / screen.width) * 100,
        height: (frame.height / screen.height) * 100
      };
    }

    function renderAxOverlay() {
      if (!axOverlay) return;
      const show = inspectorOpen && activeTab === "ax" && !!axTree;
      axOverlay.hidden = !show;
      if (!show) { axOverlay.innerHTML = ""; return; }
      const screen = axScreenFrame();
      axOverlay.innerHTML = "";
      if (!screen || !screen.width || !screen.height) return;
      for (const node of axNodesByKey.values()) {
        if (!axHasFrame(node)) continue;
        const box = axFrameToBox(node.frame, screen);
        // Skip frames that overflow the point-space screen — these are the
        // pixel-scaled container groups, not real on-screen elements.
        if (box.width > 105 || box.height > 105) continue;
        const el = document.createElement("div");
        let cls = "ax-box";
        if (node._key === axSelectedKey) cls += " selected";
        else if (node._key === axHoverKey) cls += " hover";
        el.className = cls;
        el.style.left = box.left + "%";
        el.style.top = box.top + "%";
        el.style.width = box.width + "%";
        el.style.height = box.height + "%";
        axOverlay.appendChild(el);
      }
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/SimToolWeb/WebViewer.swift
git commit -m "feat(web): draw AX element overlays over the device screen"
```

---

### Task 4: Two-way selection, hit-test, and canvas select mode

**Files:**
- Modify: `Sources/SimToolWeb/WebViewer.swift` (JS section + canvas `pointerup` handler)

- [ ] **Step 1: Add `selectAxNode`, `axHitTest`, `axSelectMode`, `axUpdateCanvasMode`**

In the AX section, add:

```js
    function selectAxNode(key, fromCanvas) {
      axSelectedKey = key;
      if (fromCanvas) {
        let node = axNodesByKey.get(key);
        let pk = node ? node._parentKey : null;
        while (pk != null) {
          axExpanded.add(pk);
          const parent = axNodesByKey.get(pk);
          pk = parent ? parent._parentKey : null;
        }
      }
      renderAxTree();
      renderAxSelected();
      renderAxOverlay();
      if (fromCanvas) {
        const row = axTreeEl.querySelector(".ax-row.selected");
        if (row) row.scrollIntoView({ block: "nearest" });
      }
    }

    // Canvas click -> deepest (smallest-area) framed node containing the point.
    function axHitTest(clientX, clientY) {
      const rect = surface.getBoundingClientRect();
      if (!rect.width || !rect.height) return null;
      const screen = axScreenFrame();
      if (!screen) return null;
      const px = screen.x + ((clientX - rect.left) / rect.width) * screen.width;
      const py = screen.y + ((clientY - rect.top) / rect.height) * screen.height;
      let best = null, bestArea = Infinity;
      for (const node of axNodesByKey.values()) {
        const f = node.frame;
        if (!axHasFrame(node)) continue;
        if (px >= f.x && px <= f.x + f.width && py >= f.y && py <= f.y + f.height) {
          const area = f.width * f.height;
          // <= so that among coincident frames (e.g. Application and its Window
          // both cover the screen) the deepest, last-walked node wins.
          if (area <= bestArea) { bestArea = area; best = node; }
        }
      }
      return best;
    }

    function axSelectMode() {
      return inspectorOpen && activeTab === "ax";
    }

    function axUpdateCanvasMode() {
      canvas.classList.toggle("ax-pick", axSelectMode());
    }
```

- [ ] **Step 2: Intercept canvas `pointerup` in select mode**

Replace the canvas `pointerup` handler (currently lines 1053-1067) with:

```js
    canvas.addEventListener("pointerup", (event) => {
      if (!gesture || event.pointerId !== gesture.pointerId) return;
      const start = gesture;
      gesture = null;
      try { canvas.releasePointerCapture(event.pointerId); } catch (_) {}
      if (axSelectMode()) {
        const node = axHitTest(event.clientX, event.clientY);
        if (node) selectAxNode(node._key, true);
        return;
      }
      const moved = Math.hypot(event.clientX - start.startClientX, event.clientY - start.startClientY);
      if (moved < TAP_MOVE_THRESHOLD) {
        sendTap(start.startPoint);
        return;
      }
      const endPoint = eventToSimulatorPoint(event, canvas);
      const elapsedSeconds = (performance.now() - start.startTime) / 1000;
      const duration = Math.min(SWIPE_MAX_DURATION, Math.max(SWIPE_MIN_DURATION, elapsedSeconds));
      sendSwipe(start.startPoint, endPoint, duration);
    });
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/SimToolWeb/WebViewer.swift
git commit -m "feat(web): sync AX selection between tree and screen, gate canvas taps"
```

---

### Task 5: Copy selected element as JSON

**Files:**
- Modify: `Sources/SimToolWeb/WebViewer.swift` (JS section)

- [ ] **Step 1: Add `axAncestorPath`, `axCopyPayload`, `renderAxSelected`, and the copy handler**

In the AX section, add:

```js
    function axAncestorPath(node) {
      const path = [];
      let pk = node._parentKey;
      while (pk != null) {
        const parent = axNodesByKey.get(pk);
        if (!parent) break;
        path.unshift(axNodeLabel(parent));
        pk = parent._parentKey;
      }
      return path;
    }

    function axCopyPayload(node) {
      return {
        accessibilityIdentifier: node.accessibilityIdentifier ?? null,
        label: node.label ?? null,
        value: node.value ?? null,
        title: node.title ?? null,
        role: node.role ?? null,
        roleDescription: node.roleDescription ?? null,
        type: node.type ?? null,
        enabled: node.enabled ?? null,
        pid: node.pid ?? null,
        frame: node.frame ?? null,
        ancestorPath: axAncestorPath(node),
        raw: node.raw ?? null
      };
    }

    function renderAxSelected() {
      const node = axSelectedKey ? axNodesByKey.get(axSelectedKey) : null;
      if (!node) { axSelectedBar.hidden = true; return; }
      axSelectedBar.hidden = false;
      axSelectedLabel.textContent = axNodeLabel(node);
    }

    async function copyAxSelected() {
      const node = axSelectedKey ? axNodesByKey.get(axSelectedKey) : null;
      if (!node) return;
      const text = JSON.stringify(axCopyPayload(node), null, 2);
      try {
        await navigator.clipboard.writeText(text);
      } catch (_) {
        const area = document.createElement("textarea");
        area.value = text;
        document.body.appendChild(area);
        area.select();
        try { document.execCommand("copy"); } catch (_) {}
        document.body.removeChild(area);
      }
      const original = axCopyButton.textContent;
      axCopyButton.textContent = "Copied ✓";
      setTimeout(() => { axCopyButton.textContent = original; }, 1200);
    }
```

- [ ] **Step 2: Wire the copy button**

In the `// ---- Wiring ----` section, after the `axRefreshButton` line added in Task 2, add:

```js
    axCopyButton.addEventListener("click", copyAxSelected);
```

- [ ] **Step 3: Build, then run the full smoke test**

Run: `swift build && swift test --filter SimToolWebTests.testViewerEmbedsAxInspector`
Expected: build succeeds; the test PASSES (all anchors — `axTree`, `axOverlay`, `axCopy`, `axRefresh`, `axSelectedBar`, `/api/v1/ax/tree`, `renderAxTree`, `axHitTest`, `axCopyPayload` — are present and the stub text is gone).

- [ ] **Step 4: Run the whole web test suite**

Run: `swift test --filter SimToolWebTests`
Expected: all tests pass (no regression in the existing inspector/stream tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SimToolWeb/WebViewer.swift
git commit -m "feat(web): copy selected AX element as full JSON to clipboard"
```

---

### Task 6: Manual verification against a simulator

**Files:** none (verification only)

- [ ] **Step 1: Boot a simulator and serve**

Run: `swift run simtool serve --device <udid-or-name> --port 3200`
Open `http://127.0.0.1:3200`, click **Inspect**, switch to the **AX** tab.

- [ ] **Step 2: Verify the checklist**

- Tree renders within ~2s and refreshes (status shows "N nodes · updated just now"); manual ⟳ pulls immediately.
- Every framed element shows a thin outline over the screen; expanding/collapsing tree nodes works.
- Clicking a tree row highlights that element brightly on screen; hovering a row shows the medium highlight.
- Clicking an element on the screen selects it (the cursor is the default arrow, **no** tap is sent to the app), expands its ancestors, scrolls its row into view, and highlights it.
- The filter box narrows the tree by id/label/role and auto-expands to matches.
- Selecting an element reveals the **Copy JSON** button; clicking it shows "Copied ✓" and the clipboard holds the full JSON (normalized fields + `ancestorPath` + `frame` + `raw`).
- Switching away from the AX tab or closing Inspect removes the overlays, restores the `crosshair` cursor, and lets canvas taps/swipes reach the app again; AX polling stops.

- [ ] **Step 3: Note any defects and loop back** to the relevant task if something fails (use superpowers:systematic-debugging).

---

## Self-Review

**Spec coverage:**
- Tree of accessibility identifiers → Tasks 2 (render) + 1 (markup). ✓
- Highlight elements on screen while AX active → Task 3 (overlays) + 2 (show/hide via tab). ✓
- Select by tree row or by screen, kept in sync → Task 4 (`selectAxNode`, `axHitTest`, tree row click in Task 2). ✓
- "Copy element" with fullest info → Task 5 (`axCopyPayload` incl. `raw` + `ancestorPath`). ✓
- Periodic polling refresh → Task 2 (`startAxPolling`/`stopAxPolling`, 2s). ✓
- Canvas click selects, not interacts → Task 4 (`axSelectMode` gate in `pointerup`). ✓
- Coordinate mapping (points→surface) → Task 3 (`axScreenFrame` + `axFrameToBox`) + Task 4 (`axHitTest`). ✓
- Filter, refresh button, status, edge/empty/error states → Tasks 1–2. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output.

**Type/name consistency:** DOM ids (`axTree`/`axOverlay`/`axStatus`/`axRefresh`/`axSelectedBar`/`axSelectedLabel`/`axCopy`) match their JS refs (`axTreeEl`/`axOverlay`/`axStatusEl`/`axRefreshButton`/`axSelectedBar`/`axSelectedLabel`/`axCopyButton`). Function names referenced before definition (`selectAxNode`, `renderAxSelected`, `renderAxOverlay`, `axUpdateCanvasMode`) are all function declarations (hoisted) and defined in Tasks 3–5. State keys use `node.id` consistently as the map/selection key.
