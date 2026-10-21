// A keyed list: rows are created once per key and updated in place, so focus,
// text selection, hover and scroll survive every poll. One row at a time is in
// the tab order (roving tabindex); ↑/↓/Home/End move the selection, Enter
// activates it, Esc clears it, Shift+F10 or the menu key opens its menu.
//
// options:
//   key(item) → string, version(item) → string (re-render when it changes),
//   render(item, row) fills the row element, rowClass(item) → extra classes,
//   group(item) → group id or null, renderGroup(id, items, collapsed) → { html, label },
//   onSelect(key, item), onActivate(key, item), onMenu(key, item, x, y, row),
//   onGroupMenu(id, x, y, button), follow: true (or a function) to stick to the newest row
//   while the list sits at its end, header: element kept first (sticky column headers),
//   empty() → element shown when no rows, exists(key) → whether a selected row that a
//   filter hides still exists (its selection then survives the filter).

function createList(container, options) {
  const rows = new Map();     // key → { element, version, item }
  const groups = new Map();   // group id → button
  const collapsed = new Set(options.collapsed || []);
  let items = [];
  let visible = [];           // items whose rows are shown, in order
  let selectedKey = null;
  let emptyNode = null;

  container.setAttribute("tabindex", "-1");
  if (options.header) container.append(options.header);

  function atBottom() {
    return container.scrollHeight - container.scrollTop - container.clientHeight <= 24;
  }

  function rowFor(item) {
    const key = options.key(item);
    const version = options.version ? options.version(item) : "";
    let entry = rows.get(key);
    if (!entry) {
      const element = document.createElement("div");
      element.className = "row";
      element.setAttribute("role", options.rowRole || "option");
      element.tabIndex = -1;
      element.dataset.key = key;
      entry = { element, version: null, item };
      rows.set(key, entry);
    }
    entry.item = item;
    if (entry.version !== version) {
      entry.version = version;
      entry.element.className = "row " + (options.rowClass ? options.rowClass(item) : "");
      options.render(item, entry.element);
    }
    entry.element.setAttribute("aria-selected", String(key === selectedKey));
    return entry.element;
  }

  function groupFor(id, groupItems) {
    let button = groups.get(id);
    if (!button) {
      button = document.createElement("button");
      button.type = "button";
      button.className = "group-row";
      button.dataset.group = id;
      groups.set(id, button);
    }
    const isCollapsed = collapsed.has(id);
    const rendered = options.renderGroup(id, groupItems, isCollapsed);
    if (button.dataset.html !== rendered) {
      button.innerHTML = rendered;
      button.dataset.html = rendered;
    }
    button.setAttribute("aria-expanded", String(!isCollapsed));
    return button;
  }

  function update(nextItems) {
    const follow = (typeof options.follow === "function" ? options.follow() : options.follow) && atBottom();
    const scrollTop = container.scrollTop;
    items = nextItems;
    visible = [];
    const desired = [];
    if (options.header) desired.push(options.header);
    if (!items.length) {
      emptyNode = options.empty ? options.empty() : null;
      if (emptyNode) desired.push(emptyNode);
    } else {
      let currentGroup;
      let groupItems = [];
      for (let index = 0; index < items.length; index++) {
        const item = items[index];
        const groupId = options.group ? options.group(item) : null;
        if (groupId != null && groupId !== currentGroup) {
          currentGroup = groupId;
          groupItems = items.filter((candidate) => options.group(candidate) === groupId);
          desired.push(groupFor(groupId, groupItems));
        }
        if (groupId != null && collapsed.has(groupId)) continue;
        visible.push(item);
        desired.push(rowFor(item));
      }
    }
    // Reconcile: move only what is out of place, drop what is gone.
    const keep = new Set(desired);
    for (const child of [...container.children]) if (!keep.has(child)) child.remove();
    let cursor = container.firstElementChild;
    for (const node of desired) {
      if (node === cursor) { cursor = cursor.nextElementSibling; continue; }
      container.insertBefore(node, cursor);
    }
    const liveKeys = new Set(items.map(options.key));
    for (const key of [...rows.keys()]) if (!liveKeys.has(key) && key !== selectedKey) rows.delete(key);
    if (selectedKey != null && !liveKeys.has(selectedKey) && !(options.exists && options.exists(selectedKey))) {
      rows.delete(selectedKey);
      selectedKey = null;
      if (options.onSelect) options.onSelect(null, null);
    }
    syncTabStop();
    if (follow) container.scrollTop = container.scrollHeight;
    else if (container.scrollTop !== scrollTop) container.scrollTop = scrollTop;
  }

  function syncTabStop() {
    const selectedEntry = selectedKey != null && rows.get(selectedKey);
    const fallback = visible.length ? rows.get(options.key(visible[0])) : null;
    const stop = (selectedEntry && selectedEntry.element.isConnected) ? selectedEntry.element : fallback && fallback.element;
    for (const entry of rows.values()) entry.element.tabIndex = entry.element === stop ? 0 : -1;
    container.tabIndex = stop ? -1 : 0;
  }

  function select(key, { focus, scroll, quiet } = {}) {
    const previous = selectedKey != null && rows.get(selectedKey);
    if (previous) previous.element.setAttribute("aria-selected", "false");
    selectedKey = key;
    const entry = key != null && rows.get(key);
    if (entry) {
      entry.element.setAttribute("aria-selected", "true");
      if (scroll !== false) entry.element.scrollIntoView({ block: "nearest" });
      if (focus) entry.element.focus({ preventScroll: true });
    }
    syncTabStop();
    if (!quiet && options.onSelect) options.onSelect(key, entry ? entry.item : null);
  }

  function move(delta) {
    if (!visible.length) return;
    const keys = visible.map(options.key);
    let index = keys.indexOf(selectedKey);
    if (index < 0) index = delta > 0 ? -1 : keys.length;
    const next = Math.max(0, Math.min(keys.length - 1, index + delta));
    select(keys[next], { focus: true });
  }

  container.addEventListener("click", (event) => {
    const groupButton = event.target.closest(".group-row");
    if (groupButton && container.contains(groupButton)) {
      toggleGroup(groupButton.dataset.group);
      return;
    }
    const row = event.target.closest(".row[data-key]");
    if (!row || !container.contains(row) || hasTextSelection()) return;
    if (event.target.closest("button, a, input, summary")) return;
    select(row.dataset.key, { focus: true, scroll: false });
  });

  container.addEventListener("dblclick", (event) => {
    const row = event.target.closest(".row[data-key]");
    if (row && options.onActivate) { const entry = rows.get(row.dataset.key); options.onActivate(row.dataset.key, entry && entry.item); }
  });

  container.addEventListener("contextmenu", (event) => {
    const groupButton = event.target.closest(".group-row");
    if (groupButton && options.onGroupMenu) {
      event.preventDefault();
      options.onGroupMenu(groupButton.dataset.group, event.clientX, event.clientY, groupButton);
      return;
    }
    const row = event.target.closest(".row[data-key]");
    if (!row || !options.onMenu) return;
    event.preventDefault();
    if (row.dataset.key !== selectedKey) select(row.dataset.key, { scroll: false });
    const entry = rows.get(row.dataset.key);
    options.onMenu(row.dataset.key, entry && entry.item, event.clientX, event.clientY, row);
  });

  container.addEventListener("keydown", (event) => {
    if (event.target.closest("input, textarea")) return;
    const onGroup = event.target.closest && event.target.closest(".group-row");
    switch (event.key) {
      case "ArrowDown": event.preventDefault(); move(1); break;
      case "ArrowUp": event.preventDefault(); move(-1); break;
      case "PageDown": event.preventDefault(); move(10); break;
      case "PageUp": event.preventDefault(); move(-10); break;
      case "Home": event.preventDefault(); move(-Infinity); break;
      case "End": event.preventDefault(); move(Infinity); break;
      case "Enter":
        if (onGroup) return;
        if (selectedKey != null && options.onActivate) { event.preventDefault(); options.onActivate(selectedKey, rows.get(selectedKey).item); }
        break;
      case "Escape":
        if (selectedKey != null) { event.preventDefault(); event.stopPropagation(); select(null); container.focus(); }
        break;
      case "ArrowLeft": case "ArrowRight":
        if (options.group && selectedKey != null) {
          const entry = rows.get(selectedKey);
          const id = entry && options.group(entry.item);
          if (id != null && (event.key === "ArrowLeft") !== collapsed.has(id)) { event.preventDefault(); toggleGroup(id); }
        }
        break;
      case "ContextMenu": case "F10":
        if (event.key === "F10" && !event.shiftKey) return;
        if (selectedKey != null && options.onMenu && rows.get(selectedKey).element.isConnected) {
          event.preventDefault();
          const entry = rows.get(selectedKey);
          const rect = entry.element.getBoundingClientRect();
          options.onMenu(selectedKey, entry.item, rect.left + 24, rect.bottom, entry.element);
        }
        break;
    }
  });

  function toggleGroup(id) {
    if (collapsed.has(id)) collapsed.delete(id); else collapsed.add(id);
    if (options.onCollapse) options.onCollapse([...collapsed]);
    update(items);
  }

  return {
    update,
    select,
    move,
    toggleGroup,
    get selectedKey() { return selectedKey; },
    get selectedItem() { const entry = selectedKey != null && rows.get(selectedKey); return entry ? entry.item : null; },
    get visibleItems() { return visible; },
    rowElement(key) { const entry = rows.get(key); return entry ? entry.element : null; },
    // Focus without choosing anything: the selected row, or the list itself, where ↓ selects.
    focus() {
      const entry = selectedKey != null && rows.get(selectedKey);
      if (entry && entry.element.isConnected) entry.element.focus();
      else container.focus();
    },
    // Re-render every row (a setting that changes how rows look, not what they hold).
    invalidate() { for (const entry of rows.values()) entry.version = null; update(items); },
    scrollToEnd() { container.scrollTop = container.scrollHeight; },
    atBottom
  };
}

// A table's header whose columns a person arranges: a column's name dragged
// moves it, the line at its right edge sizes it (a double-click resets it),
// the header's menu shows or hides columns — ⌥←/⌥→, ←/→ on an edge and ⇧F10
// do the same from the keyboard — and the layout is kept per browser under
// `storeKey`. With `sort`, a click on a column's name sorts by it; on the
// sorted column it flips the direction.
//
// options: { className, spec (see LOG_COLUMNS), storeKey, classes: { key: "c-size num" },
//   sort: { state: { key, dir }, dirs: { key: default direction }, onChange() }, onLayout() }
// The rows draw `header.columns`, in that order; `attach(list)` gives the list
// the grid templates its rows follow (`--cols`, `--cols-n1`… per narrower step).
function createColumnHeader(options) {
  const spec = options.spec;
  const sort = options.sort || null;
  let layout = columnLayout(spec, stored(options.storeKey, null));
  let target = null;
  let drag = null;
  const header = el("div", { class: "thead col-head " + options.className, role: "row" });
  const columnOf = (key) => layout.find((column) => column.key === key);
  const shown = () => layout.filter((column) => !column.hidden);

  function render() {
    const focused = header.contains(document.activeElement) ? document.activeElement : null;
    const focusCol = focused && focused.dataset.col, focusEdge = focused && focused.dataset.resize;
    header.innerHTML = shown().map((column, index) => {
      const label = escapeHTML(spec.labels[column.key]);
      const sorts = sort && sort.dirs[column.key] != null;
      const sorted = sorts && sort.state.key === column.key;
      const name = sorts
        ? '<button type="button" class="col-sort' + (sorted ? " sorted" : "") + '" tabindex="-1" data-sort="' + column.key + '">' + label + (sorted ? icon(sort.state.dir > 0 ? "chev-u" : "chev-d", "ic-xs") : "") + "</button>"
        : '<span class="col-label">' + label + "</span>";
      return '<span class="cell col ' + (options.classes && options.classes[column.key] || "") + '" role="columnheader" data-col="' + column.key + '" tabindex="' + (index === 0 ? 0 : -1) + '"' +
        (sorts ? ' aria-sort="' + (sorted ? (sort.state.dir > 0 ? "ascending" : "descending") : "none") + '"' : "") +
        ' aria-roledescription="movable column" title="' + (sorts ? "Click to sort · " : "") + 'drag to move · ⌥← ⌥→ moves it · right-click for the columns">' + name +
        (column.key === spec.flex ? "" : '<span class="col-resize" role="separator" aria-orientation="vertical" tabindex="0" data-resize="' + column.key + '" aria-label="Resize ' + label +
          '" aria-valuemin="' + (spec.min[column.key] || 40) + '" aria-valuemax="640" aria-valuenow="' + column.width + '" title="Drag to resize · double-click resets"></span>') +
        "</span>";
    }).join("");
    const again = focusEdge ? header.querySelector('[data-resize="' + focusEdge + '"]') : focusCol ? header.querySelector('[data-col="' + focusCol + '"]') : null;
    if (again) {
      if (focusCol) { header.querySelectorAll("[data-col]").forEach((cell) => { cell.tabIndex = -1; }); again.tabIndex = 0; }
      again.focus({ preventScroll: true });
    }
  }

  // The widths go to the rows as grid templates; a new order or a column shown re-renders them.
  function apply({ save, rows } = {}) {
    if (target) {
      target.style.setProperty("--cols", gridTemplate(spec, layout, 0));
      spec.narrow.forEach((_, index) => target.style.setProperty("--cols-n" + (index + 1), gridTemplate(spec, layout, index + 1)));
    }
    if (rows !== false) { render(); if (options.onLayout) options.onLayout(); }
    if (save) store(options.storeKey, layout);
  }

  function set(next, message) {
    layout = columnLayout(spec, next);
    apply({ save: true });
    if (message) setMessage(message);
  }

  function moveBy(key, step) {
    const visible = shown();
    const target = visible[visible.findIndex((column) => column.key === key) + step];
    if (!target) return;
    const before = layout.findIndex((column) => column.key === target.key) + (step > 0 ? 1 : 0);
    set(moveColumn(layout, key, before), spec.labels[key] + " moved " + (step > 0 ? "right" : "left"));
  }

  function sortBy(key) {
    if (!sort || sort.dirs[key] == null) return;
    if (sort.state.key === key) sort.state.dir = -sort.state.dir; else { sort.state.key = key; sort.state.dir = sort.dirs[key]; }
    render();
    sort.onChange();
  }

  function menu(key) {
    const visible = shown();
    const at = visible.findIndex((column) => column.key === key);
    return [
      { icon: "chev-r", label: "Move " + spec.labels[key] + " left", kbd: "⌥←", disabled: at <= 0, run: () => moveBy(key, -1) },
      { icon: "chev-r", label: "Move " + spec.labels[key] + " right", kbd: "⌥→", disabled: at < 0 || at >= visible.length - 1, run: () => moveBy(key, 1) },
      "-",
      { caption: "Columns" },
      ...layout.filter((column) => column.key !== spec.flex).map((column) => ({
        label: spec.labels[column.key], checked: !column.hidden,
        run: () => set(layout.map((other) => other.key === column.key ? { ...other, hidden: !other.hidden } : other))
      })),
      "-",
      { icon: "relaunch", label: "Reset the columns", run: () => set(null, "Columns reset") }
    ];
  }

  function endDrag(event, cancelled) {
    const ending = drag;
    if (!ending) return;
    drag = null;
    try { header.releasePointerCapture(event.pointerId); } catch (_) {}
    header.querySelectorAll(".dragging, .drop-before, .drop-after, .active").forEach((node) => node.classList.remove("dragging", "drop-before", "drop-after", "active"));
    if (cancelled) apply();
    else if (ending.kind === "resize") apply({ save: true, rows: false });
    else if (ending.moved && ending.before != null) set(moveColumn(layout, ending.key, ending.before));
  }

  // A name moves its column once dragged a few pixels — a plain click sorts —
  // and the line at its right edge sizes it from the first pixel.
  header.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    const handle = event.target.closest("[data-resize]");
    const cell = event.target.closest("[data-col]");
    if (!handle && !cell) return;
    event.preventDefault();
    const key = handle ? handle.dataset.resize : cell.dataset.col;
    drag = { kind: handle ? "resize" : "move", key, x: event.clientX, width: columnOf(key).width, moved: false, before: null, node: handle || cell, pointerId: event.pointerId };
    if (handle) {
      try { header.setPointerCapture(event.pointerId); } catch (_) {}
      handle.classList.add("active");
    }
  });
  header.addEventListener("pointermove", (event) => {
    if (!drag) return;
    if (!event.buttons) { endDrag(event, true); return; }
    const dx = event.clientX - drag.x;
    if (drag.kind === "resize") {
      const column = columnOf(drag.key);
      column.width = clampColumnWidth(spec, drag.key, drag.width + dx);
      drag.node.setAttribute("aria-valuenow", String(column.width));
      apply({ rows: false });
      return;
    }
    if (!drag.moved && Math.abs(dx) < 4) return;
    if (!drag.moved) {
      drag.moved = true;
      drag.node.classList.add("dragging");
      try { header.setPointerCapture(event.pointerId); } catch (_) {}
    }
    const cells = [...header.querySelectorAll("[data-col]")];
    const over = cells.find((cell) => { const rect = cell.getBoundingClientRect(); return event.clientX < rect.left + rect.width / 2; });
    drag.before = over ? layout.findIndex((column) => column.key === over.dataset.col) : layout.length;
    cells.forEach((cell) => cell.classList.remove("drop-before", "drop-after"));
    if (over) over.classList.add("drop-before"); else cells[cells.length - 1].classList.add("drop-after");
  });
  header.addEventListener("pointerup", (event) => endDrag(event, false));
  header.addEventListener("pointercancel", (event) => endDrag(event, true));
  header.addEventListener("click", (event) => {
    const button = event.target.closest("[data-sort]");
    if (button) sortBy(button.dataset.sort);
  });
  header.addEventListener("dblclick", (event) => {
    const handle = event.target.closest("[data-resize]");
    if (!handle) return;
    columnOf(handle.dataset.resize).width = spec.widths[handle.dataset.resize];
    apply({ save: true });
  });
  header.addEventListener("contextmenu", (event) => {
    const cell = event.target.closest("[data-col]");
    if (!cell) return;
    event.preventDefault();
    event.stopPropagation();
    openMenu(event.clientX, event.clientY, menu(cell.dataset.col), cell);
  });
  header.addEventListener("keydown", (event) => {
    const handle = event.target.closest("[data-resize]");
    if (handle) {
      const step = { ArrowLeft: -1, ArrowRight: 1 }[event.key];
      if (!step) return;
      event.preventDefault();
      event.stopPropagation();
      const column = columnOf(handle.dataset.resize);
      column.width = clampColumnWidth(spec, column.key, column.width + step * (event.shiftKey ? 32 : 8));
      handle.setAttribute("aria-valuenow", String(column.width));
      apply({ save: true, rows: false });
      return;
    }
    const cell = event.target.closest("[data-col]");
    if (!cell || event.target !== cell) return;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      event.stopPropagation();
      const step = event.key === "ArrowRight" ? 1 : -1;
      if (event.altKey) { moveBy(cell.dataset.col, step); return; }
      const cells = [...header.querySelectorAll("[data-col]")];
      const next = cells[cells.indexOf(cell) + step];
      if (next) { cells.forEach((other) => { other.tabIndex = -1; }); next.tabIndex = 0; next.focus(); }
    } else if (event.key === "Enter" || event.key === " ") {
      if (!sort || sort.dirs[cell.dataset.col] == null) return;
      event.preventDefault();
      event.stopPropagation();
      sortBy(cell.dataset.col);
    } else if (event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey)) {
      event.preventDefault();
      event.stopPropagation();
      openMenuAt(cell, menu(cell.dataset.col));
    }
  });

  render();
  return {
    element: header,
    get columns() { return shown(); },
    attach(list) { target = list; apply({ rows: false }); },
    set,
    moveBy
  };
}
