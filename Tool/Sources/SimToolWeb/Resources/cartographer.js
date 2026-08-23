import React, { useCallback, useEffect, useMemo, useRef, useState } from "https://esm.sh/react@18.3.1";
import { createRoot } from "https://esm.sh/react-dom@18.3.1/client";
import {
  ReactFlow, Background, Controls, MiniMap, Panel, Handle, Position, MarkerType, applyNodeChanges,
} from "https://esm.sh/@xyflow/react@12.8.2?deps=react@18.3.1,react-dom@18.3.1";
import htm from "https://esm.sh/htm@3.1.1";

const html = htm.bind(React.createElement);

// The page's own diagnostic (see the boot script in cartographer.html) cannot
// tell «no network» from «the module ran and threw»: reaching this line is the
// only proof the imports above resolved.
if (window.__cartographerBoot) window.__cartographerBoot.loaded = true;

// «1 экран», «2 экрана», «5 экранов»: a count and a noun glued together
// without this read as a half-translated interface.
function plural(count, one, few, many) {
  const hundreds = Math.abs(count) % 100;
  const units = hundreds % 10;
  if (hundreds >= 11 && hundreds <= 14) return many;
  if (units === 1) return one;
  if (units >= 2 && units <= 4) return few;
  return many;
}

function counted(count, one, few, many) {
  return `${count} ${plural(count, one, few, many)}`;
}

// The crawl overwrites a screen's PNG every time it walks that screen again,
// and a URL that never changes is a URL the browser answers out of its own
// cache — the card kept its first screenshot until F5. The run and the visit
// counter change exactly when the file can have changed, so a poll that
// changed nothing re-fetches nothing.
function shotUrl(node) {
  const version = `${node.shotEpoch || ""}-${node.visits || 0}`;
  return `/api/v1/explore/shot?node=${encodeURIComponent(node.id)}&v=${encodeURIComponent(version)}`;
}

// A screenshot that says so when it is missing: a crawl can record a screen
// whose PNG never reached the disk, and a broken-image icon reads as a broken
// map. The failed URL is remembered rather than a flag, so a newer version of
// the shot still gets its own attempt.
function Shot({ node }) {
  const [failed, setFailed] = useState(null);
  const src = shotUrl(node);
  if (failed === src) return html`<div class="shot-missing">нет скриншота</div>`;
  return html`<img src=${src} loading="lazy" alt="" onError=${() => setFailed(src)} />`;
}

// Handles anchor the arrows and are never dragged from. Invisible is not inert:
// a transparent handle still won the mousedown over the card underneath it, and
// dragging a card by its edge drew a connection instead of moving it.
const HANDLE_STYLE = { opacity: 0, pointerEvents: "none" };

function ScreenNode({ data, selected }) {
  // A node recorded by an older crawl can report having tried more buttons than
  // it found; «7/5 действий» is the display's problem to not print.
  const tried = data.actionsTried || 0;
  const total = Math.max(data.actionsTotal || 0, tried);
  return html`<div class="screen-node ${selected ? "selected" : ""}">
    <${Handle} type="target" position=${Position.Left} style=${HANDLE_STYLE} />
    <${Shot} node=${data} />
    <div class="screen-title" title=${data.title}>${data.title}</div>
    <div class="screen-meta">
      ${tried}/${counted(total, "действие", "действия", "действий")}
      ${data.bridge && html`<span class="bridge-tag" title="Транзит: путь в фичу лежит через этот экран, но он не входит в неё">транзит<//>`}
    </div>
    <${Handle} type="source" position=${Position.Right} style=${HANDLE_STYLE} />
  </div>`;
}
const nodeTypes = { screen: ScreenNode };

// Column width fits a card (168px) plus room for an edge label; row height
// fits a full-height screenshot card (~410px) plus the same.
const COLUMN = 320;
const ROW = 480;
// How tall one column may grow before it continues in the next one. A level of
// a real app holds a dozen screens — one column of those is 6000px tall, and
// fitView answers that by shrinking every card to a thumbnail.
const MAX_ROWS = 4;

// Screens grouped by distance, each group filling as many columns as it needs.
// Deterministic — a poll never shuffles cards the user has not dragged: groups
// go by ascending distance, cards within a group in map order.
function gridPositions(byLevel) {
  const positions = new Map();
  let column = 0;
  for (const level of [...byLevel.keys()].sort((a, b) => a - b)) {
    const list = byLevel.get(level);
    list.forEach((node, index) => {
      positions.set(node.id, {
        x: (column + Math.floor(index / MAX_ROWS)) * COLUMN,
        y: (index % MAX_ROWS) * ROW,
      });
    });
    column += Math.max(1, Math.ceil(list.length / MAX_ROWS));
  }
  return positions;
}

function autoLayout(graphNodes) {
  const byDepth = new Map();
  for (const node of graphNodes) {
    if (!byDepth.has(node.depth)) byDepth.set(node.depth, []);
    byDepth.get(node.depth).push(node);
  }
  return gridPositions(byDepth);
}

// Columns by distance from the flow's doors rather than from the map root, so
// the way in — the fork screen, then the flow's first screen — reads left to
// right and a flow that starts deep opens flush left instead of behind empty
// columns. Rows keep map order, so a screen the crawl adds while the flow is
// open lands at the end of its column instead of reshuffling the ones shown.
function subtreeLayout(nodes, edges, entryIds) {
  const neighbours = new Map();
  for (const edge of edges) {
    if (!neighbours.has(edge.source)) neighbours.set(edge.source, []);
    if (!neighbours.has(edge.target)) neighbours.set(edge.target, []);
    neighbours.get(edge.source).push(edge.target);
    neighbours.get(edge.target).push(edge.source);
  }
  const order = nodes.map((node) => node.id);
  const drawn = new Set(order);
  // Screens the doors cannot reach — recorded after a relaunch — start their
  // own column 0 rather than dropping off the view.
  const sources = [...entryIds, ...order].filter((id) => drawn.has(id));
  const distance = new Map();
  for (const source of sources) {
    if (distance.has(source)) continue;
    distance.set(source, 0);
    const queue = [source];
    for (let head = 0; head < queue.length; head += 1) {
      const current = queue[head];
      for (const next of neighbours.get(current) || []) {
        if (distance.has(next)) continue;
        distance.set(next, distance.get(current) + 1);
        queue.push(next);
      }
    }
  }
  const byDistance = new Map();
  for (const id of order) {
    const column = distance.get(id) || 0;
    if (!byDistance.has(column)) byDistance.set(column, []);
    byDistance.get(column).push({ id });
  }
  return gridPositions(byDistance);
}

// Every place a query can hit, grouped so the panel can name what matched.
// Only what a person can be looking for is in here. Sweeping the rest of the
// record in as well — depth, visit counts, `firstSeenAt`, the screenshot path —
// meant «png», «2026» and «0» each matched every card on the canvas, and a
// search that matches everything is the same as no search at all.
//
// The node's structural hash is out for that reason and not as bookkeeping:
// sixty-four hex characters contain every digit, so one character typed into
// the box would ring every card. Its short id is in — see below.
const SEARCH_GROUPS = [
  { label: "название", pick: (node) => [node.title] },
  { label: "ключ экрана", pick: (node) => [node.key] },
  // The id is the handle everything outside the canvas refers a screen by: it
  // is what a feature chip prints under its label, what the map on disk keys
  // the screen on, and what an agent has in hand after reading that map.
  // Dropping it left the one string printed on the canvas that the box beside
  // it could not find.
  { label: "идентификатор", pick: (node) => [node.id] },
  { label: "фичи", pick: (node) => node.groups || [] },
  { label: "диплинки", pick: (node) => node.deeplinks || [] },
  { label: "локализация", pick: (node) => node.localizationKeys || [] },
  { label: "действия", pick: (node) => node.triedActionKeys || [] },
  // A button nobody has tapped yet is still a button on that screen, and it is
  // what «а куда ведёт эта кнопка» searches for — but it is not an action the
  // crawl took, so it must not be filed under one.
  {
    label: "кнопки без обхода",
    pick: (node) => {
      const tried = new Set(node.triedActionKeys || []);
      return (node.actionKeys || []).filter((key) => !tried.has(key));
    },
  },
];

function searchEntry(node, transitionLabels, featureLabels) {
  const groups = SEARCH_GROUPS.map((group) => ({
    label: group.label,
    values: group.pick(node).filter(Boolean).map(String),
  }));
  // A node carries its flows as keys; what a person searches by is the label
  // the chip shows, so both are in the haystack.
  const features = groups.find((group) => group.label === "фичи");
  if (features) features.values = [...(featureLabels || []), ...features.values];
  groups.push({ label: "переходы", values: transitionLabels });
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

// React Flow keeps what it measured about a card — its size, where its handles
// are — against the very object it was handed, and starts over on a card it has
// not seen before. So does React, for everything the card renders. A derivation
// that spreads a fresh object every poll therefore re-does the whole canvas once
// a second while a crawl runs; this hands back the object built last time until
// the card's own inputs move. `rebuild` keeps the whole map's cards this way,
// and everything derived from them goes through here.
function keptCard(cache, node, signature, build) {
  const previous = cache.get(node.id);
  if (previous && previous.from === node && previous.signature === signature) return previous.card;
  const card = build();
  cache.set(node.id, { from: node, signature, card });
  return card;
}

function edgeLabel(action) {
  if (action.kind === "scroll") return "scroll";
  const target = action.targetLabel || action.targetId || "";
  return target ? `tap «${target}»` : "tap";
}

// How many times one arrangement may be sent before the page stops asking. A
// wire that dropped a request answers the next one; a disk that is full, or a
// directory where layout.json belongs, answers nothing differently ever — and
// the two are the same 500 from here. A few tries and then silence, rather than
// a POST every five seconds for as long as the tab is open.
const SAVE_ATTEMPTS = 3;

function App() {
  const [status, setStatus] = useState(null);
  const [flow, setFlow] = useState({ nodes: [], edges: [] });
  const [selected, setSelected] = useState(null);
  const [error, setError] = useState(null);
  // Whether a status has ever arrived. «Ещё не загрузилось» and «граф пуст»
  // look the same in the graph and read very differently on screen.
  const [loaded, setLoaded] = useState(false);
  const [layoutError, setLayoutError] = useState(null);
  const [assetError, setAssetError] = useState(null);
  const [query, setQuery] = useState("");
  // The cursor into the results is the id of a card, not its place in the list:
  // the crawl reshuffles that list under it, and a positional cursor then walks
  // the viewport to a screen the user never asked for.
  const [matchCursor, setMatchCursor] = useState(null);
  // Which feature the canvas is showing; null is the whole map, and the whole
  // map is a choice in the same row rather than a mode with a way back out.
  const [activeGroupKey, setActiveGroupKey] = useState(null);
  const searchInput = useRef(null);
  // Where the user left the whole map, so returning to it lands where they
  // were instead of at fitView.
  const wholeMapViewport = useRef(null);
  const shownGroupKey = useRef(null);
  // A switch back to the whole map noticed while a query owned the viewport
  // still has to be honoured once the query clears, so what it asked for is
  // remembered instead of dropped.
  const restorePending = useRef(false);
  // Node id -> position, both what the user dragged this session and
  // what earlier sessions saved on the server. A local drag always
  // wins over a polled value, so a save in flight never snaps a
  // card back.
  const placedPositions = useRef(new Map());
  // The cards the two derivations below built last time, so a poll that changed
  // nothing hands the canvas back the very objects it already has (`keptCard`).
  const derivedCards = useRef(new Map());
  const decoratedCards = useRef(new Map());
  const pendingSaves = useRef(new Map());
  const saveTimer = useRef(null);
  // How many times the arrangement now in `pendingSaves` has been refused.
  const saveAttempts = useRef(0);
  const flowInstance = useRef(null);

  // Re-center as the map grows: a scan adds nodes outside the viewport, and
  // watching the map расти is the whole demo. Three things override that, and
  // they share one effect so they cannot fight over the viewport:
  //  - an active search owns it, so a poll never yanks away the card jumped to;
  //  - a feature keeps it while the crawl fills that feature in;
  //  - coming back to the whole map restores where the user left it.
  useEffect(() => {
    const instance = flowInstance.current;
    if (!instance) return undefined;
    // Which view is on screen is tracked before the search bails out, not
    // after: a feature opened while a query was active would otherwise still
    // look like the whole map once the query clears, and the feature's own
    // viewport would be saved as the place to return to.
    const previous = shownGroupKey.current;
    const switched = previous !== activeGroupKey;
    if (switched) {
      if (previous === null) wholeMapViewport.current = instance.getViewport();
      restorePending.current = activeGroupKey === null;
      shownGroupKey.current = activeGroupKey;
    }
    if (query.trim()) return undefined;
    // Growing inside an open feature: the new card joins the subtree, but the
    // view stays exactly where it is.
    if (activeGroupKey !== null && !switched) return undefined;
    const timer = setTimeout(() => {
      const restore = restorePending.current && wholeMapViewport.current;
      restorePending.current = false;
      if (restore) {
        instance.setViewport(wholeMapViewport.current, { duration: 400 });
        return;
      }
      instance.fitView({ padding: 0.15, duration: 400 });
    }, 80);
    return () => clearTimeout(timer);
  }, [flow.nodes.length, query, activeGroupKey]);

  const rebuild = useCallback((graph, layout) => {
    if (!graph) { setFlow((previous) => (previous.nodes.length ? { nodes: [], edges: [] } : previous)); return; }
    for (const [id, position] of Object.entries((layout && layout.positions) || {})) {
      if (!placedPositions.current.has(id)) placedPositions.current.set(id, position);
    }
    const auto = autoLayout(graph.nodes);
    const shotEpoch = (graph.run && graph.run.id) || "";
    // One arrow per pair of screens. Four buttons of a hub can open the same
    // screen, and React Flow draws all four along the same curve — the labels
    // landed on top of one another and read as a single scrambled word. The
    // arrow names the first button and counts the arrows folded into it; every
    // label stays on the edge for the search.
    const byPair = new Map();
    for (const edge of graph.edges) {
      const pair = `${edge.from}→${edge.to}`;
      if (!byPair.has(pair)) byPair.set(pair, []);
      byPair.get(pair).push(edge);
    }
    const edges = [...byPair.values()].map((parallel) => {
      const first = parallel[0];
      const labels = [];
      for (const edge of parallel) {
        const label = edgeLabel(edge.action);
        if (!labels.includes(label)) labels.push(label);
      }
      const taps = parallel.reduce((total, edge) => total + edge.count, 0);
      // Counted over the folded transitions, not over their distinct wordings:
      // three buttons that read the same are still three transitions, and «+2»
      // is the only place the drawing admits that it collapsed them.
      const folded = parallel.length - 1;
      return {
        id: first.id,
        source: first.from,
        target: first.to,
        // A plain string, not markup: React Flow prints an edge label inside an
        // SVG <text>, where HTML renders as nothing at all.
        label: folded > 0 ? `${labels[0]} +${folded}` : labels[0],
        data: { labels },
        markerEnd: { type: MarkerType.ArrowClosed, color: "#7dd3fc" },
        style: { stroke: "rgba(125,211,252,0.55)", strokeWidth: Math.min(1 + taps * 0.5, 3) },
        labelStyle: { fill: "rgba(244,247,251,0.75)", fontSize: 10 },
        labelBgStyle: { fill: "#0b1020", fillOpacity: 0.85 },
      };
    });
    // Merged into the cards already on the canvas rather than built from
    // scratch. React Flow writes back into the node objects it was handed —
    // `selected`, `measured` — and a poll that replaced them dropped the
    // selection ring and made the canvas re-measure every card, which blanks
    // the arrows for a frame. Handing back the very same object where nothing
    // changed is what keeps a running crawl from doing that once a second.
    setFlow((previous) => {
      const byId = new Map(previous.nodes.map((node) => [node.id, node]));
      const nodes = graph.nodes.map((record) => {
        const existing = byId.get(record.id);
        const target = placedPositions.current.get(record.id) || auto.get(record.id);
        const moved = !existing || existing.position.x !== target.x || existing.position.y !== target.y;
        const position = moved ? target : existing.position;
        const data = { ...record, shotEpoch };
        const same = existing && JSON.stringify(existing.data) === JSON.stringify(data);
        if (existing && !moved && same) return existing;
        return { ...(existing || { id: record.id, type: "screen" }), position, data: same ? existing.data : data };
      });
      return { nodes, edges };
    });
  }, []);

  // One POST per burst of dragging: React Flow emits a position
  // change per mouse move, and only where the card came to rest
  // matters. `keepalive` lets the last save outlive the tab.
  //
  // `canRetry` is off on the way out: a retry timer armed after the component
  // is gone has nowhere to report to and nobody to clear it.
  const flushLayout = useCallback(async (canRetry = true) => {
    const pending = pendingSaves.current;
    if (pending.size === 0) return;
    pendingSaves.current = new Map();
    const positions = {};
    const retryable = new Map();
    for (const [id, position] of pending) {
      const x = Math.round(position.x);
      const y = Math.round(position.y);
      // A NaN serializes as null and the server rejects the whole batch over
      // it, taking every good position in the batch down with it. Dropped
      // rather than re-queued: a retry would fail the same way forever.
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
      positions[id] = { x, y };
      retryable.set(id, position);
    }
    if (retryable.size === 0) {
      setLayoutError("Раскладка не сохранена: некорректные координаты карточки");
      return;
    }
    try {
      const response = await fetch("/api/v1/explore/layout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ positions }),
        keepalive: true,
      });
      // `fetch` rejects on a broken wire, not on a refusal: an unwritable
      // .simtool/explore/ answers 500, and taking that for a save means the
      // arrangement the user spent ten minutes on is gone at the next F5.
      if (!response.ok) {
        const refused = new Error("сервер ответил " + response.status);
        // A 4xx is the server's answer about this very body, and it will be the
        // same answer next time: a layout.json a newer simtool wrote and this
        // one refuses to overwrite (409), a position it will not take (400).
        // Nothing to retry — the same reason the NaN above is dropped instead
        // of re-queued.
        refused.settled = response.status >= 400 && response.status < 500;
        throw refused;
      }
      saveAttempts.current = 0;
      setLayoutError(null);
    } catch (saveError) {
      // Re-queue, unless a newer drag already superseded the card: the retry —
      // or, once the attempts are spent, the next drag — keeps the arrangement
      // instead of losing it.
      for (const [id, position] of retryable) {
        if (!pendingSaves.current.has(id)) pendingSaves.current.set(id, position);
      }
      saveAttempts.current = saveError.settled ? SAVE_ATTEMPTS : saveAttempts.current + 1;
      const again = canRetry && saveAttempts.current < SAVE_ATTEMPTS;
      setLayoutError("Раскладка не сохранена (" + saveError.message + ")"
        + (again ? ", повторяю" : " — подвиньте карточку, чтобы попробовать снова"));
      if (again) {
        clearTimeout(saveTimer.current);
        // `flushLayout` is assigned by the time this runs, and going through
        // the binding keeps the retry on whatever the current one is.
        saveTimer.current = setTimeout(() => flushLayout(), 5000);
      }
    }
  }, []);

  const scheduleSave = useCallback((id, position) => {
    pendingSaves.current.set(id, position);
    // A drag is a fresh ask, and it gets the full count of attempts however the
    // last one ended: the alternative is a tab that never saves again because a
    // server was down for a minute an hour ago.
    saveAttempts.current = 0;
    clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => flushLayout(), 400);
  }, [flushLayout]);

  // A tab closed mid-debounce would otherwise drop the last drag.
  useEffect(() => {
    const flush = () => flushLayout();
    window.addEventListener("pagehide", flush);
    return () => {
      window.removeEventListener("pagehide", flush);
      clearTimeout(saveTimer.current);
      flushLayout(false);
    };
  }, [flushLayout]);

  const poll = useCallback(async () => {
    let payload;
    try {
      const response = await fetch("/api/v1/explore/status");
      // An error envelope parses as JSON just as happily as a status does, and
      // passing it on as one wipes the canvas and calls the map empty.
      if (!response.ok) throw new Error("HTTP " + response.status);
      payload = await response.json();
    } catch (fetchError) {
      setError("Сервер недоступен: " + fetchError.message);
      return;
    }
    setLoaded(true);
    // Whatever goes wrong past this point is this page's fault, not the
    // server's — and «сервер недоступен» about it sends the reader looking in
    // the wrong place. The banner is cleared here and nowhere else: a poll that
    // succeeds is the only evidence the server came back.
    try {
      setStatus(payload);
      rebuild(payload.graph, payload.layout);
      setError(null);
    } catch (buildError) {
      setError("Не удалось построить карту: " + buildError.message);
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
      // A card leaves the map only when the graph does. React Flow deletes the
      // selected node on Backspace by default, and a card vanishing from the
      // canvas reads as «этот экран удалён из карты» — it came back on the next
      // poll, four seconds and one re-fit later.
      const kept = changes.filter((change) => change.type !== "remove");
      const nodes = applyNodeChanges(kept, previous.nodes);
      // Only the whole map has an arrangement worth keeping. A feature view
      // places its cards itself, so anything it reports is a computed
      // position, not a decision the user made — recording it would overwrite
      // the arrangement they actually built.
      if (activeGroupKey === null) {
        for (const change of changes) {
          if (change.type === "position" && change.position) {
            placedPositions.current.set(change.id, change.position);
            scheduleSave(change.id, change.position);
          }
        }
      }
      return { nodes, edges: previous.edges };
    });
  }, [scheduleSave, activeGroupKey]);

  const allGroups = useMemo(() => (status && status.groups) || [], [status]);
  // Only flows worth offering: one that draws a single card shows no sequence,
  // so it stays computed but unlisted until a later crawl fills it.
  const groups = useMemo(() => allGroups.filter((group) => group.displayable), [allGroups]);
  // Key -> shown label, listed or not: a screen names every flow it is part
  // of, and a bare key reads like plumbing.
  const groupLabels = useMemo(
    () => new Map(allGroups.map((group) => [group.key, group.label])),
    [allGroups]
  );
  const activeGroup = useMemo(
    () => groups.find((group) => group.key === activeGroupKey) || null,
    [groups, activeGroupKey]
  );

  // A crawl can regroup the map out from under an open feature. Falling back to
  // the whole map beats showing an empty canvas — but only once a status has
  // actually arrived: before the first poll every group is missing, and
  // dropping the choice then would be answering a question nobody asked yet.
  useEffect(() => {
    if (activeGroupKey === null || !status) return;
    if (!activeGroup) setActiveGroupKey(null);
  }, [status, activeGroupKey, activeGroup]);

  // The feature view is derived: its cards are placed by the layout above, not
  // by where the user dragged them on the whole map, and they do not move. That
  // is what keeps one arrangement — the whole map's — the only one to persist.
  //
  // Derived once, not re-derived on every poll. `flow` is a new object each
  // poll even when nothing in it moved, so this memo runs each time — and the
  // spread below would hand the canvas a brand-new object for every card while
  // the crawl fills the flow in, which is exactly the churn `rebuild` goes out
  // of its way to avoid for the whole map.
  const view = useMemo(() => {
    if (!activeGroup) return { nodes: flow.nodes, edges: flow.edges };
    const bridges = new Set(activeGroup.bridges || []);
    const visible = new Set([...(activeGroup.members || []), ...bridges]);
    const nodes = flow.nodes.filter((node) => visible.has(node.id));
    const edges = flow.edges.filter((edge) => visible.has(edge.source) && visible.has(edge.target));
    const positions = subtreeLayout(nodes, edges, [...bridges, activeGroup.entry]);
    return {
      nodes: nodes.map((node) => {
        const position = positions.get(node.id) || node.position;
        const bridge = bridges.has(node.id);
        return keptCard(derivedCards.current, node, `${position.x},${position.y},${bridge}`, () => ({
          ...node,
          position,
          draggable: false,
          data: { ...node.data, bridge },
        }));
      }),
      edges,
    };
  }, [flow, activeGroup]);

  // What a query can match, per node: the node's own record plus the labels of
  // the transitions touching it, so "оплатить" finds the screen a button of
  // that name leads to and the one it leads from.
  const searchIndex = useMemo(() => {
    const transitionLabels = new Map();
    for (const edge of flow.edges) {
      // Every button word of every arrow folded into this one, not just the
      // one the canvas has room to print: a query must still find the screen
      // a button of that name leads to.
      const labels = (edge.data && edge.data.labels) || [];
      for (const label of labels) {
        if (!label) continue;
        for (const id of [edge.source, edge.target]) {
          if (!transitionLabels.has(id)) transitionLabels.set(id, []);
          transitionLabels.get(id).push(label);
        }
      }
    }
    const index = new Map();
    for (const node of flow.nodes) {
      const featureLabels = (node.data.groups || []).map((key) => groupLabels.get(key)).filter(Boolean);
      index.set(node.id, searchEntry(node.data, transitionLabels.get(node.id) || [], featureLabels));
    }
    return index;
  }, [flow.nodes, flow.edges, groupLabels]);

  const terms = useMemo(() => queryTerms(query), [query]);
  const hitsQuery = useCallback((id) => {
    const entry = searchIndex.get(id);
    return Boolean(entry) && terms.every((term) => entry.haystack.includes(term));
  }, [searchIndex, terms]);

  // Search answers about what is on screen. It stays inside the open feature —
  // jumping to a card the current view does not show would be a silent switch.
  const matches = useMemo(() => {
    if (terms.length === 0) return [];
    return view.nodes.filter((node) => hitsQuery(node.id)).map((node) => node.id);
  }, [view.nodes, hitsQuery, terms.length]);

  // ...but hits outside it are counted and offered, so a feature view never
  // makes results disappear without saying so.
  const outsideMatches = useMemo(() => {
    if (terms.length === 0 || !activeGroup) return 0;
    const shown = new Set(view.nodes.map((node) => node.id));
    return flow.nodes.filter((node) => !shown.has(node.id) && hitsQuery(node.id)).length;
  }, [terms.length, activeGroup, view.nodes, flow.nodes, hitsQuery]);

  // The card the cursor is parked on. It survives the list growing, shrinking
  // and reordering around it; only when the crawl regroups it out of the
  // results does the cursor fall back to the first one.
  const currentMatch = useMemo(() => {
    if (matches.length === 0) return null;
    return matches.includes(matchCursor) ? matchCursor : matches[0];
  }, [matches, matchCursor]);
  const currentIndex = currentMatch ? matches.indexOf(currentMatch) : 0;

  // Keyed on the id, so a poll that only changed the list around the cursor
  // neither moves the viewport nor takes the drawer off a card the user opened
  // by hand.
  useEffect(() => {
    if (!currentMatch) return undefined;
    // Parked here for good: until the cursor names a card, «первое совпадение»
    // is whatever the crawl happens to have put first, and the next poll can
    // put another card there.
    setMatchCursor(currentMatch);
    setSelected(currentMatch);
    // After the drawer this selection opens has taken its 320px: centring
    // before that lands would push the card under the canvas edge.
    const timer = setTimeout(() => {
      if (flowInstance.current) {
        flowInstance.current.fitView({ nodes: [{ id: currentMatch }], padding: 0.6, maxZoom: 1, duration: 400 });
      }
    }, 90);
    return () => clearTimeout(timer);
  }, [currentMatch]);

  const step = useCallback((delta) => {
    if (matches.length === 0) return;
    const base = currentMatch ? matches.indexOf(currentMatch) : 0;
    setMatchCursor(matches[(base + delta + matches.length) % matches.length]);
  }, [matches, currentMatch]);

  const clearSearch = useCallback(() => {
    setQuery("");
    setMatchCursor(null);
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
  // «где это встречается», without a result list beside it. A transit card is
  // marked in the same pass, so a card the query says nothing about is handed
  // on exactly as it came.
  const displayNodes = useMemo(() => {
    const matched = terms.length > 0 ? new Set(matches) : null;
    return view.nodes.map((node) => {
      const bridge = node.data && node.data.bridge ? "bridge" : "";
      const found = !matched
        ? ""
        : matched.has(node.id) ? (node.id === currentMatch ? "match current" : "match") : "dimmed";
      const className = bridge && found ? bridge + " " + found : bridge || found;
      if (!className) return node;
      return keptCard(decoratedCards.current, node, className, () => ({ ...node, className }));
    });
  }, [view.nodes, matches, currentMatch, terms.length]);

  const matchedGroups = useMemo(() => {
    const entry = currentMatch && searchIndex.get(currentMatch);
    if (!entry) return "";
    return entry.groups
      .filter((group) => group.values.some((value) => hits(value, terms)))
      .map((group) => group.label)
      .join(", ");
  }, [currentMatch, searchIndex, terms]);

  // What exactly matched on the открытая нода. A hit can sit in a field the
  // drawer never showed — an action key, a button nobody tapped, a transition
  // label — and «нашлось, а где?» is a worse answer than no search at all.
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
  // Transitions counted as arrows, not as recorded edges: the canvas folds the
  // parallel ones between a pair of screens into a single arrow, and a header
  // saying «19 переходов» over 11 arrows is a bug report waiting to happen. The
  // server brings its own count in line with what it draws for the same reason
  // (ExploreGrouping.descending) — this is that invariant on this side.
  const stats = graph
    ? [
        counted(graph.stats.screens, "экран", "экрана", "экранов"),
        counted(flow.edges.length, "переход", "перехода", "переходов"),
        counted(graph.stats.steps, "шаг", "шага", "шагов"),
      ].join(" · ")
    : "";

  // One line, several things that can go wrong with the map: the unreachable
  // server first, then whatever the server itself reports, then a dependency
  // that never arrived. A refused save is not among them — the map is fine, it
  // is the arrangement that is unsaved, and it says so on a line of its own
  // below. It used to lead this list, which is how «повторяю» came to sit over
  // the crawl's progress and over the server's own error for good.
  const failure = error || (status && status.error) || assetError;

  useEffect(() => {
    document.getElementById("appName").textContent = (status && status.app) || "—";
    document.getElementById("stats").textContent = stats;
    const message = document.getElementById("message");
    message.textContent = failure || (status && status.message) || "";
    message.className = "msg" + (failure ? " err" : "");
    // The arrangement is the user's own work and its own subject: what happened
    // to a save must not be the reason the crawl's progress line is missing,
    // and the crawl must not be the reason a lost arrangement goes unmentioned.
    document.getElementById("layout").textContent = layoutError || "";
  }, [status, stats, failure, layoutError]);

  // The React Flow stylesheet comes off unpkg (see CartographerViewer.swift).
  // Without it the cards keep their own CSS but lose the transforms that place
  // them, so the whole map piles up at 0,0 — a missing network that reads as a
  // broken map unless the page says which it is.
  useEffect(() => {
    const boot = window.__cartographerBoot;
    if (!boot) return undefined;
    const report = () => {
      if (boot.failed.length === 0) return;
      setAssetError("Не загрузилось с сети: " + boot.failed.join(", ") + " — карта будет без раскладки");
    };
    report();
    boot.onFail = report;
    return () => { boot.onFail = null; };
  }, []);

  const selectedNode = selected && graph ? graph.nodes.find((node) => node.id === selected) : null;

  // A card is dragged, never deleted and never wired to another one: the map is
  // a picture of what the crawl found, not an editor of it — hence
  // `deleteKeyCode` and `nodesConnectable` below.
  return html`
    <div class="canvas">
      <${ReactFlow}
        nodes=${displayNodes}
        edges=${view.edges}
        nodeTypes=${nodeTypes}
        onNodesChange=${onNodesChange}
        onNodeClick=${(event, node) => setSelected(node.id)}
        onPaneClick=${() => setSelected(null)}
        onInit=${(instance) => { flowInstance.current = instance; }}
        fitView
        minZoom=${0.1}
        deleteKeyCode=${null}
        nodesConnectable=${false}
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
              onInput=${(event) => { setQuery(event.target.value); setMatchCursor(null); }}
              onKeyDown=${onSearchKeyDown}
            />
            ${terms.length > 0 && html`<span class=${"search-count" + (matches.length ? "" : " none")}>
              ${matches.length ? `${currentIndex + 1}/${matches.length}` : "0"}
            <//>`}
            <button class="search-step" title="Предыдущее совпадение (⇧⏎)" disabled=${matches.length < 2} onClick=${() => step(-1)}>↑</button>
            <button class="search-step" title="Следующее совпадение (⏎)" disabled=${matches.length < 2} onClick=${() => step(1)}>↓</button>
            ${query.length > 0 && html`<button class="search-step" title="Сбросить (Esc)" onClick=${clearSearch}>✕</button>`}
            ${matchedGroups && html`<span class="search-hint" title=${matchedGroups}>совпало: ${matchedGroups}<//>`}
            ${outsideMatches > 0 && html`<button
              class="search-elsewhere"
              title="Показать всю карту и найти их"
              onClick=${() => setActiveGroupKey(null)}
            >ещё ${outsideMatches} вне фичи<//>`}
          </div>
          ${groups.length > 0 && html`<div class="groups">
            <button
              class=${"group-chip" + (activeGroupKey === null ? " active" : "")}
              onClick=${() => setActiveGroupKey(null)}
            >Вся карта<span class="group-count">${flow.nodes.length}</span><//>
            ${groups.map((group) => html`<button
              key=${group.key}
              class=${"group-chip" + (activeGroupKey === group.key ? " active" : "") + (group.staleName ? " stale" : "")}
              title=${group.staleName ? group.key + " — состав заметно изменился с момента именования" : group.key}
              onClick=${() => setActiveGroupKey(group.key)}
            >
              ${group.label}
              ${group.label !== group.key && html`<span class="group-key">${group.key}<//>`}
              <span class="group-count">${group.members.length}</span>
            <//>`)}
          </div>`}
        <//>
        <${Background} color="#233052" gap=${24} />
        <${Controls} />
        <${MiniMap} pannable zoomable nodeColor=${() => "#31436e"} maskColor="rgba(5,7,13,0.7)" style=${{ background: "#0d1428" }} />
      <//>
      ${/* An empty canvas has three reasons, and «Карта пуста» is right about
           exactly one of them: the first status still being in flight and the
           server being down both said it too. */ ""}
      ${flow.nodes.length === 0 && html`<div class="empty">
        ${!loaded && !failure
          ? html`<span class="spin"></span>Загружаю карту…`
          : failure
            ? html`Карту не загрузить.<br/>${failure}`
            : html`<span>Карта пуста.<br/>Запустите обход приложения — экраны появятся здесь<br/>по мере того, как их проходят.
                ${running && html`<div><span class="spin"></span>сканирую…</div>`}<//>`}
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
      <${Shot} node=${{ ...selectedNode, shotEpoch: (graph.run && graph.run.id) || "" }} />
      ${(selectedNode.groups || []).length > 0 && html`<div class="section">
        <div class="section-title">Фичи</div>
        ${selectedNode.groups.map((key) => html`<button
          key=${key}
          title=${key}
          class=${"group-chip inline" + (activeGroupKey === key ? " active" : "") + (hits(key, terms) || hits(groupLabels.get(key) || "", terms) ? " hit" : "")}
          disabled=${!groups.some((group) => group.key === key)}
          onClick=${() => setActiveGroupKey(key)}
        >${groupLabels.get(key) || key}<//>`)}
      <//>`}
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

// Without this an exception anywhere in the tree unmounts the whole page: the
// tab goes black, the polling stops with it, and nothing anywhere says why.
// The message is the diagnosis; the console keeps the stack.
class Boundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { failure: null };
  }

  static getDerivedStateFromError(failure) {
    return { failure };
  }

  componentDidCatch(failure, info) {
    console.error("Картограф: отрисовка упала", failure, info);
  }

  render() {
    if (!this.state.failure) return this.props.children;
    return html`<div class="boot err">
      Картограф сломался при отрисовке: ${String((this.state.failure && this.state.failure.message) || this.state.failure)}.
      <br/>Перезагрузите страницу — стек в консоли браузера.
    </div>`;
  }
}

createRoot(document.getElementById("root")).render(html`<${Boundary}><${App} /><//>`);
