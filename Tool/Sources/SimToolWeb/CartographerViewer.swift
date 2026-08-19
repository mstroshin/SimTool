import Foundation

/// The Картограф tab: a React Flow canvas over the exploration graph the
/// server's ExploreController builds. Served as a self-contained page; React
/// and React Flow load as ES modules from esm.sh, so there is no build step —
/// the price is that the tab needs internet access on first open.
public enum CartographerViewer {
    public static func html() -> String {
        #"""
        <!doctype html>
        <html lang="ru">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Картограф</title>
          <link rel="stylesheet" href="https://unpkg.com/@xyflow/react@12.8.2/dist/style.css">
          <style>
            :root { color-scheme: dark; font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; }
            * { box-sizing: border-box; }
            body { margin: 0; height: 100vh; display: flex; flex-direction: column; background: #0b1020; color: #f4f7fb; }
            header { flex: 0 0 auto; display: flex; align-items: center; gap: 14px; padding: 10px 16px; border-bottom: 1px solid rgba(255,255,255,0.10); background: rgba(255,255,255,0.03); }
            .brand { color: #7dd3fc; font-size: 13px; letter-spacing: 0.14em; text-transform: uppercase; font-weight: 700; }
            .backlink { color: rgba(244,247,251,0.55); text-decoration: none; font-size: 12px; }
            .backlink:hover { color: #bae6fd; }
            .app-name { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.6); }
            .stats { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; color: #bae6fd; }
            .grow { flex: 1; }
            .msg { font-size: 12px; color: rgba(244,247,251,0.65); max-width: 40vw; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .msg.err { color: #f87171; }
            button.scan { appearance: none; border: 1px solid rgba(125,211,252,0.55); border-radius: 10px; background: rgba(125,211,252,0.12); color: #bae6fd; padding: 7px 16px; font-size: 13px; cursor: pointer; }
            button.scan:hover:not(:disabled) { background: rgba(125,211,252,0.22); }
            button.scan:disabled { opacity: 0.45; cursor: default; }
            button.scan.stop { border-color: rgba(248,113,113,0.55); background: rgba(248,113,113,0.10); color: #fca5a5; }
            #root { flex: 1; min-height: 0; display: flex; }
            .canvas { flex: 1; min-width: 0; position: relative; }
            .empty { position: absolute; inset: 0; display: grid; place-items: center; color: rgba(244,247,251,0.45); font-size: 14px; text-align: center; line-height: 1.7; pointer-events: none; }
            .spin { display: inline-block; width: 11px; height: 11px; border: 2px solid rgba(125,211,252,0.3); border-top-color: #7dd3fc; border-radius: 50%; animation: spin 0.8s linear infinite; vertical-align: -1px; margin-right: 6px; }
            @keyframes spin { to { transform: rotate(360deg); } }
            /* Screen node cards */
            .screen-node { width: 168px; border: 1px solid rgba(255,255,255,0.14); border-radius: 12px; background: #101830; overflow: hidden; box-shadow: 0 10px 26px rgba(0,0,0,0.45); }
            .screen-node.selected { border-color: #7dd3fc; box-shadow: 0 0 0 2px rgba(125,211,252,0.35), 0 10px 26px rgba(0,0,0,0.45); }
            /* Full-height screenshot: the natural ratio once loaded, a phone-ish
               placeholder ratio before, so the layout does not jump. */
            .screen-node img { display: block; width: 100%; height: auto; aspect-ratio: auto 9 / 19.5; background: #05070d; }
            .screen-title { padding: 6px 8px 2px; font-size: 11px; font-weight: 600; color: #e8eefb; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .screen-meta { padding: 0 8px 7px; font: 10px ui-monospace, SFMono-Regular, Menlo, monospace; color: rgba(244,247,251,0.5); }
            .react-flow__attribution { display: none; }
            /* Details drawer */
            .details { flex: 0 0 320px; border-left: 1px solid rgba(255,255,255,0.10); background: #0d1428; overflow: auto; padding: 14px; }
            .details h2 { margin: 0 0 10px; font-size: 14px; color: #e8eefb; }
            .details img { width: 100%; border-radius: 10px; border: 1px solid rgba(255,255,255,0.12); }
            .details .section { margin-top: 14px; }
            .details .section-title { font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: rgba(244,247,251,0.45); margin-bottom: 6px; }
            .details .mono { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; color: #bae6fd; line-height: 1.7; word-break: break-all; }
            .details .muted { font-size: 12px; color: rgba(244,247,251,0.4); }
            .details .close { float: right; appearance: none; border: 0; background: none; color: rgba(244,247,251,0.5); font-size: 16px; cursor: pointer; }
            .details .close:hover { color: #f4f7fb; }
          </style>
        </head>
        <body>
          <header>
            <span class="brand">🗺️ Картограф</span>
            <a class="backlink" href="/">← SimTool</a>
            <span id="appName" class="app-name">—</span>
            <span id="stats" class="stats"></span>
            <span class="grow"></span>
            <span id="message" class="msg"></span>
            <button id="scanButton" class="scan" type="button">Сканировать приложение</button>
          </header>
          <div id="root"></div>
          <script type="module">
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
              const [busy, setBusy] = useState(false);
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

              const start = useCallback(async () => {
                setBusy(true); setError(null);
                try {
                  const response = await fetch("/api/v1/explore/start", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: "{}",
                  });
                  if (!response.ok) {
                    const body = await response.json().catch(() => ({}));
                    setError(body.error || response.statusText);
                  }
                } finally { setBusy(false); poll(); }
              }, [poll]);

              const stop = useCallback(async () => {
                setBusy(true);
                try { await fetch("/api/v1/explore/stop", { method: "POST", body: "{}" }); }
                finally { setBusy(false); poll(); }
              }, [poll]);

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
                const button = document.getElementById("scanButton");
                button.textContent = running ? "⏹ Остановить" : "Сканировать приложение";
                button.className = "scan" + (running ? " stop" : "");
                button.disabled = busy;
                button.onclick = running ? stop : start;
              }, [status, stats, error, running, busy, start, stop]);

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
                    Карта пуста.<br/>Нажмите «Сканировать приложение» — робот запустит приложение,<br/>пройдёт по экранам и нарисует их здесь.
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
          </script>
        </body>
        </html>
        """#
    }
}
