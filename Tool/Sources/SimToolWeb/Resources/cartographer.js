import React, { useCallback, useEffect, useRef, useState } from "https://esm.sh/react@18.3.1";
import { createRoot } from "https://esm.sh/react-dom@18.3.1/client";
import {
  ReactFlow, Background, Controls, MiniMap, Handle, Position, MarkerType, applyNodeChanges,
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
    const timer = setTimeout(() => {
      if (flowInstance.current) flowInstance.current.fitView({ padding: 0.15, duration: 400 });
    }, 80);
    return () => clearTimeout(timer);
  }, [flow.nodes.length]);

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
        nodes=${flow.nodes}
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
      <h2>${selectedNode.title}</h2>
      <img src=${"/api/v1/explore/shot?node=" + selectedNode.id} alt="" />
      <div class="section">
        <div class="section-title">Диплинки</div>
        ${(selectedNode.deeplinks || []).length
          ? selectedNode.deeplinks.map((url) => html`<div class="mono" key=${url}>${url}</div>`)
          : html`<div class="muted">не найдены</div>`}
      </div>
      <div class="section">
        <div class="section-title">Ключи локализации</div>
        ${(selectedNode.localizationKeys || []).length
          ? selectedNode.localizationKeys.map((key) => html`<div class="mono" key=${key}>${key}</div>`)
          : html`<div class="muted">не найдены</div>`}
      </div>
    <//>`}
  `;
}

createRoot(document.getElementById("root")).render(html`<${App} />`);
