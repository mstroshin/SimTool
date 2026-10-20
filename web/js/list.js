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

// Column headers that sort; clicking the sorted column flips the direction.
function createSortHeader(className, columns, state, onChange) {
  const header = el("div", { class: "thead " + className, role: "row" });
  function render() {
    header.innerHTML = "";
    for (const column of columns) {
      const cell = el("span", { class: "cell " + (column.class || ""), role: "columnheader",
        "aria-sort": state.key === column.key ? (state.dir > 0 ? "ascending" : "descending") : (column.sort ? "none" : null) });
      if (column.sort) {
        const button = el("button", { type: "button", class: state.key === column.key ? "sorted" : null }, column.label);
        if (state.key === column.key) button.insertAdjacentHTML("beforeend", icon(state.dir > 0 ? "chev-u" : "chev-d", "ic-xs"));
        button.addEventListener("click", () => {
          if (state.key === column.key) state.dir = -state.dir; else { state.key = column.key; state.dir = column.defaultDir || 1; }
          render();
          onChange();
        });
        cell.append(button);
      } else {
        cell.textContent = column.label;
      }
      header.append(cell);
    }
  }
  render();
  return header;
}
