import React, { useCallback, useEffect, useMemo, useRef, useState } from "https://esm.sh/react@18.3.1";
import { createRoot } from "https://esm.sh/react-dom@18.3.1/client";
import {
  ReactFlow, Background, Controls, MiniMap, Panel, Handle, Position, MarkerType, applyNodeChanges,
} from "https://esm.sh/@xyflow/react@12.8.2?deps=react@18.3.1,react-dom@18.3.1";
import htm from "https://esm.sh/htm@3.1.1";

const html = htm.bind(React.createElement);

function ScreenNode({ data, selected }) {
  return html`<div class="screen-node ${selected ? "selected" : ""}">
    <${Handle} type="target" position=${Position.Left} style=${{ opacity: 0 }} />
    <img src=${"/api/v1/explore/shot?node=" + data.id} loading="lazy" alt="" />
    <div class="screen-title" title=${data.title}>${data.title}</div>
    <div class="screen-meta">${data.actionsTried}/${data.actionsTotal} действий</div>
    <${Handle} type="source" position=${Position.Right} style=${{ opacity: 0 }} />
  </div>`;
}
const nodeTypes = { screen: ScreenNode };

// Columns by BFS depth, rows in discovery order. Deterministic, so a
// poll never shuffles nodes the user has not dragged.
function autoLayout(graphNodes) {
  const byDepth = new Map();
  for (const node of graphNodes) {
    if (!byDepth.has(node.depth)) byDepth.set(node.depth, []);
    byDepth.get(node.depth).push(node);
  }
  const positions = new Map();
  for (const [depth, list] of byDepth) {
    list.forEach((node, index) => {
      // Row height fits a full-height screenshot card (~410px at
      // 168px width) plus room for edge labels.
      positions.set(node.id, { x: depth * 320, y: index * 480 });
    });
  }
  return positions;
}

// Every place a query can hit, grouped so the panel can name what matched.
// The named groups cover what a person searches by; `restValues` sweeps up
// everything else the record carries — depth, visits, timestamps, and any
// field a later schema adds — so a query really searches the whole node.
const SEARCH_GROUPS = [
  { label: "название", pick: (node) => [node.title] },
  { label: "диплинки", pick: (node) => node.deeplinks || [] },
  { label: "локализация", pick: (node) => node.localizationKeys || [] },
  { label: "действия", pick: (node) => node.triedActionKeys || [] },
  { label: "идентификаторы", pick: (node) => [node.id, node.key, node.fingerprint] },
];
const NAMED_FIELDS = new Set([
  "title", "deeplinks", "localizationKeys", "triedActionKeys", "id", "key", "fingerprint",
]);

function restValues(node) {
  const values = [];
  const walk = (value) => {
    if (value === null || value === undefined) return;
    if (Array.isArray(value)) { value.forEach(walk); return; }
    if (typeof value === "object") { Object.values(value).forEach(walk); return; }
    values.push(String(value));
  };
  for (const [name, value] of Object.entries(node)) if (!NAMED_FIELDS.has(name)) walk(value);
  return values;
}

function searchEntry(node, transitionLabels) {
  const groups = SEARCH_GROUPS.map((group) => ({
    label: group.label,
    values: group.pick(node).filter(Boolean).map(String),
  }));
  groups.push({ label: "переходы", values: transitionLabels });
  groups.push({ label: "прочее", values: restValues(node) });
  const haystack = groups.map((group) => group.values.join("\n")).join("\n").toLowerCase();
  return { groups, haystack };
}

// Space-separated terms are ANDed: "профиль deeplink" finds the screen that
// carries both, which is how one narrows a big map down to one card.
function queryTerms(query) {
  return query.trim().toLowerCase().split(/\s+/).filter(Boolean);
}

function hits(text, terms) {
  const lowered = String(text).toLowerCase();
  return terms.some((term) => lowered.includes(term));
}

function edgeLabel(action) {
  if (action.kind === "scroll") return "scroll";
  const target = action.targetLabel || action.targetId || "";
  return target ? `tap «${target}»` : "tap";
}

function App() {
  const [status, setStatus] = useState(null);
  const [flow, setFlow] = useState({ nodes: [], edges: [] });
  const [selected, setSelected] = useState(null);
  const [error, setError] = useState(null);
  const [query, setQuery] = useState("");
  const [matchIndex, setMatchIndex] = useState(0);
  const searchInput = useRef(null);
  // Node id -> position, both what the user dragged this session and
  // what earlier sessions saved on the server. A local drag always
  // wins over a polled value, so a save in flight never snaps a
  // card back.
  const placedPositions = useRef(new Map());
  const pendingSaves = useRef(new Map());
  const saveTimer = useRef(null);
  const flowInstance = useRef(null);

  // Re-center as the map grows: a scan adds nodes outside the
  // viewport, and watching the map расти is the whole demo.
  useEffect(() => {
    // A search owns the viewport while it is active: re-fitting the whole map
    // under it would throw away the card the user just jumped to.
    if (query.trim()) return undefined;
    const timer = setTimeout(() => {
      if (flowInstance.current) flowInstance.current.fitView({ padding: 0.15, duration: 400 });
    }, 80);
    return () => clearTimeout(timer);
  }, [flow.nodes.length, query]);

  const rebuild = useCallback((graph, layout) => {
    if (!graph) { setFlow({ nodes: [], edges: [] }); return; }
    for (const [id, position] of Object.entries((layout && layout.positions) || {})) {
      if (!placedPositions.current.has(id)) placedPositions.current.set(id, position);
    }
    const auto = autoLayout(graph.nodes);
    const nodes = graph.nodes.map((node) => ({
      id: node.id,
      type: "screen",
      position: placedPositions.current.get(node.id) || auto.get(node.id),
      data: node,
    }));
    const edges = graph.edges.map((edge) => ({
      id: edge.id,
      source: edge.from,
      target: edge.to,
      label: edgeLabel(edge.action),
      markerEnd: { type: MarkerType.ArrowClosed, color: "#7dd3fc" },
      style: { stroke: "rgba(125,211,252,0.55)", strokeWidth: Math.min(1 + edge.count * 0.5, 3) },
      labelStyle: { fill: "rgba(244,247,251,0.75)", fontSize: 10 },
      labelBgStyle: { fill: "#0b1020", fillOpacity: 0.85 },
    }));
    setFlow({ nodes, edges });
  }, []);

  // One POST per burst of dragging: React Flow emits a position
  // change per mouse move, and only where the card came to rest
  // matters. `keepalive` lets the last save outlive the tab.
  const flushLayout = useCallback(async () => {
    const pending = pendingSaves.current;
    if (pending.size === 0) return;
    pendingSaves.current = new Map();
    const positions = {};
    for (const [id, position] of pending) {
      positions[id] = { x: Math.round(position.x), y: Math.round(position.y) };
    }
    try {
      await fetch("/api/v1/explore/layout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ positions }),
        keepalive: true,
      });
    } catch (saveError) {
      // Re-queue, unless a newer drag already superseded the card:
      // the next drag retries instead of losing the arrangement.
      for (const [id, position] of pending) {
        if (!pendingSaves.current.has(id)) pendingSaves.current.set(id, position);
      }
    }
  }, []);

  const scheduleSave = useCallback((id, position) => {
    pendingSaves.current.set(id, position);
    clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(flushLayout, 400);
  }, [flushLayout]);

  // A tab closed mid-debounce would otherwise drop the last drag.
  useEffect(() => {
    const flush = () => flushLayout();
    window.addEventListener("pagehide", flush);
    return () => { window.removeEventListener("pagehide", flush); flush(); };
  }, [flushLayout]);

  const poll = useCallback(async () => {
    try {
      const response = await fetch("/api/v1/explore/status");
      const payload = await response.json();
      setStatus(payload);
      rebuild(payload.graph, payload.layout);
    } catch (fetchError) {
      setError("Сервер недоступен: " + fetchError.message);
    }
  }, [rebuild]);

  useEffect(() => {
    poll();
    const running = status && status.running;
    const timer = setInterval(poll, running ? 1200 : 3000);
    return () => clearInterval(timer);
  }, [poll, status && status.running]);

  const onNodesChange = useCallback((changes) => {
    setFlow((previous) => {
      const nodes = applyNodeChanges(changes, previous.nodes);
      for (const change of changes) {
        if (change.type === "position" && change.position) {
          placedPositions.current.set(change.id, change.position);
          scheduleSave(change.id, change.position);
        }
      }
      return { nodes, edges: previous.edges };
    });
  }, [scheduleSave]);

  // What a query can match, per node: the node's own record plus the labels of
  // the transitions touching it, so "оплатить" finds the screen a button of
  // that name leads to and the one it leads from.
  const searchIndex = useMemo(() => {
    const transitionLabels = new Map();
    for (const edge of flow.edges) {
      const label = String(edge.label || "");
      if (!label) continue;
      for (const id of [edge.source, edge.target]) {
        if (!transitionLabels.has(id)) transitionLabels.set(id, []);
        transitionLabels.get(id).push(label);
      }
    }
    const index = new Map();
    for (const node of flow.nodes) {
      index.set(node.id, searchEntry(node.data, transitionLabels.get(node.id) || []));
    }
    return index;
  }, [flow.nodes, flow.edges]);

  const terms = useMemo(() => queryTerms(query), [query]);
  const matches = useMemo(() => {
    if (terms.length === 0) return [];
    return flow.nodes
      .filter((node) => {
        const entry = searchIndex.get(node.id);
        return entry && terms.every((term) => entry.haystack.includes(term));
      })
      .map((node) => node.id);
  }, [flow.nodes, searchIndex, terms]);

  // The list identity changes on every poll; its contents do not. Keying the
  // focus effect on the contents keeps a poll from yanking the viewport back.
  const matchesKey = matches.join(",");
  const currentIndex = matches.length ? Math.min(matchIndex, matches.length - 1) : 0;
  const currentMatch = matches.length ? matches[currentIndex] : null;

  useEffect(() => {
    if (!currentMatch) return undefined;
    setSelected(currentMatch);
    // After the drawer this selection opens has taken its 320px: centring
    // before that lands would push the card under the canvas edge.
    const timer = setTimeout(() => {
      if (flowInstance.current) {
        flowInstance.current.fitView({ nodes: [{ id: currentMatch }], padding: 0.6, maxZoom: 1, duration: 400 });
      }
    }, 90);
    return () => clearTimeout(timer);
  }, [matchesKey, matchIndex]);

  const step = useCallback((delta) => {
    setMatchIndex((previous) => {
      if (matches.length === 0) return 0;
      const base = Math.min(previous, matches.length - 1);
      return (base + delta + matches.length) % matches.length;
    });
  }, [matches.length]);

  const clearSearch = useCallback(() => {
    setQuery("");
    setMatchIndex(0);
    if (searchInput.current) searchInput.current.blur();
  }, []);

  const onSearchKeyDown = useCallback((event) => {
    if (event.key === "Enter") { event.preventDefault(); step(event.shiftKey ? -1 : 1); }
    if (event.key === "Escape") { event.preventDefault(); clearSearch(); }
  }, [step, clearSearch]);

  // «/» and ⌘F land in the search box, the way a find-in-page does — the
  // browser's own find would only see the handful of cards it has rendered.
  useEffect(() => {
    const onKeyDown = (event) => {
      const tag = event.target && event.target.tagName;
      const typing = tag === "INPUT" || tag === "TEXTAREA";
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
        event.preventDefault();
        if (searchInput.current) { searchInput.current.focus(); searchInput.current.select(); }
        return;
      }
      if (event.key === "/" && !typing) {
        event.preventDefault();
        if (searchInput.current) searchInput.current.focus();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  // Dim what the query rules out, ring what it keeps: the map itself answers
  // «где это встречается», without a result list beside it.
  const displayNodes = useMemo(() => {
    if (terms.length === 0) return flow.nodes;
    const matched = new Set(matches);
    return flow.nodes.map((node) => {
      if (!matched.has(node.id)) return { ...node, className: "dimmed" };
      return { ...node, className: node.id === currentMatch ? "match current" : "match" };
    });
  }, [flow.nodes, matches, currentMatch, terms.length]);

  const matchedGroups = useMemo(() => {
    const entry = currentMatch && searchIndex.get(currentMatch);
    if (!entry) return "";
    return entry.groups
      .filter((group) => group.values.some((value) => hits(value, terms)))
      .map((group) => group.label)
      .join(", ");
  }, [currentMatch, searchIndex, terms]);

  // What exactly matched on the открытая нода. A hit can sit in a field the
  // drawer never showed — a tried action key, an id, a transition label — and
  // «нашлось, а где?» is a worse answer than no search at all.
  const matchedValues = useMemo(() => {
    if (terms.length === 0 || !selected) return [];
    const entry = searchIndex.get(selected);
    if (!entry) return [];
    const seen = new Set();
    const groups = [];
    for (const group of entry.groups) {
      const values = [];
      for (const value of group.values) {
        if (!hits(value, terms) || seen.has(value)) continue;
        seen.add(value);
        values.push(value);
      }
      if (values.length > 0) groups.push({ label: group.label, values: values.slice(0, 12) });
    }
    return groups;
  }, [terms, selected, searchIndex]);

  const running = status && status.running;
  const graph = status && status.graph;
  const stats = graph ? `${graph.stats.screens} экранов · ${graph.stats.transitions} переходов · ${graph.stats.steps} шагов` : "";

  useEffect(() => {
    document.getElementById("appName").textContent = (status && status.app) || "—";
    document.getElementById("stats").textContent = stats;
    const message = document.getElementById("message");
    message.textContent = error || (status && (status.error || status.message)) || "";
    message.className = "msg" + ((error || (status && status.error)) ? " err" : "");
  }, [status, stats, error]);

  const selectedNode = selected && graph ? graph.nodes.find((node) => node.id === selected) : null;

  return html`
    <div class="canvas">
      <${ReactFlow}
        nodes=${displayNodes}
        edges=${flow.edges}
        nodeTypes=${nodeTypes}
        onNodesChange=${onNodesChange}
        onNodeClick=${(event, node) => setSelected(node.id)}
        onPaneClick=${() => setSelected(null)}
        onInit=${(instance) => { flowInstance.current = instance; }}
        fitView
        minZoom=${0.1}
        proOptions=${{ hideAttribution: true }}
        colorMode="dark"
      >
        <${Panel} position="top-left">
          <div class="search">
            <span class="search-icon">🔍</span>
            <input
              ref=${searchInput}
              class="search-input"
              type="text"
              spellCheck=${false}
              placeholder="Поиск по нодам: название, диплинк, ключ, действие…"
              value=${query}
              onInput=${(event) => { setQuery(event.target.value); setMatchIndex(0); }}
              onKeyDown=${onSearchKeyDown}
            />
            ${terms.length > 0 && html`<span class=${"search-count" + (matches.length ? "" : " none")}>
              ${matches.length ? `${currentIndex + 1}/${matches.length}` : "0"}
            <//>`}
            <button class="search-step" title="Предыдущее совпадение (⇧⏎)" disabled=${matches.length < 2} onClick=${() => step(-1)}>↑</button>
            <button class="search-step" title="Следующее совпадение (⏎)" disabled=${matches.length < 2} onClick=${() => step(1)}>↓</button>
            ${query.length > 0 && html`<button class="search-step" title="Сбросить (Esc)" onClick=${clearSearch}>✕</button>`}
            ${matchedGroups && html`<span class="search-hint" title=${matchedGroups}>совпало: ${matchedGroups}<//>`}
          </div>
        <//>
        <${Background} color="#233052" gap=${24} />
        <${Controls} />
        <${MiniMap} pannable zoomable nodeColor=${() => "#31436e"} maskColor="rgba(5,7,13,0.7)" style=${{ background: "#0d1428" }} />
      <//>
      ${flow.nodes.length === 0 && html`<div class="empty">
        Карта пуста.<br/>Запустите обход приложения — экраны появятся здесь<br/>по мере того, как их проходят.
        ${running && html`<div><span class="spin"></span>сканирую…</div>`}
      </div>`}
    </div>
    ${selectedNode && html`<aside class="details">
      <button class="close" onClick=${() => setSelected(null)}>✕</button>
      <h2 class=${hits(selectedNode.title, terms) ? "hit" : ""}>${selectedNode.title}</h2>
      ${matchedValues.length > 0 && html`<div class="section">
        <div class="section-title">Совпадения</div>
        ${matchedValues.map((group) => html`<div class="match-group" key=${group.label}>
          <div class="match-label">${group.label}</div>
          ${group.values.map((value) => html`<div class="mono hit" key=${value}>${value}</div>`)}
        <//>`)}
      <//>`}
      <img src=${"/api/v1/explore/shot?node=" + selectedNode.id} alt="" />
      <div class="section">
        <div class="section-title">Диплинки</div>
        ${(selectedNode.deeplinks || []).length
          ? selectedNode.deeplinks.map((url) => html`<div class=${"mono" + (hits(url, terms) ? " hit" : "")} key=${url}>${url}</div>`)
          : html`<div class="muted">не найдены</div>`}
      </div>
      <div class="section">
        <div class="section-title">Ключи локализации</div>
        ${(selectedNode.localizationKeys || []).length
          ? selectedNode.localizationKeys.map((key) => html`<div class=${"mono" + (hits(key, terms) ? " hit" : "")} key=${key}>${key}</div>`)
          : html`<div class="muted">не найдены</div>`}
      </div>
    <//>`}
  `;
}

createRoot(document.getElementById("root")).render(html`<${App} />`);
