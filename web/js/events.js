// Inspector data pushed by the server: one Server-Sent Events stream per page
// (/api/v1/events) carries Network, Logs, State, Tests, the app launches and
// what was done to the device as they change, so nothing waits for a poll. It is a connection of its own — the
// screen already holds one of the six a browser opens to a server — and not the
// input WebSocket, where a burst of log lines would hold up a touch.
//
// Polling is the fallback: it stands in only while the stream is down (an older
// server, a dropped connection), so a page on a live stream sends no requests
// while nothing happens. However often an entry arrives — stream, replay after a
// reconnect, a poll in between — it is taken once: calls merge by id, logs and
// state skip what is at or below their cursor.

const inspectorEvents = {
  source: null,
  polling: typeof EventSource === "undefined",   // the stream is down: polls stand in
  lastEventId: ""                                // <server instance>:<sequence>
};

function startInspectorEvents() {
  if (typeof EventSource === "undefined") return;
  if (inspectorEvents.source && inspectorEvents.source.readyState !== EventSource.CLOSED) return;
  // The browser resends the last id when it reconnects by itself; a new
  // EventSource has forgotten it, so the query carries it over.
  const resume = inspectorEvents.lastEventId ? "?lastEventId=" + encodeURIComponent(inspectorEvents.lastEventId) : "";
  const source = new EventSource("/api/v1/events" + resume);
  inspectorEvents.source = source;
  source.addEventListener("open", () => { inspectorEvents.polling = false; });
  // Reconnecting, or closed for good by an answer that is not a stream.
  source.addEventListener("error", () => { inspectorEvents.polling = true; });
  const on = (name, apply) => source.addEventListener(name, (message) => {
    apply(JSON.parse(message.data));
    if (message.lastEventId) inspectorEvents.lastEventId = message.lastEventId;
  });
  on("snapshot", applySnapshot);
  on("network", (payload) => applyNetworkTopic(payload, false));
  on("logs", (payload) => applyLogsTopic(payload, false));
  on("state", (payload) => applyStateTopic(payload, false));
  on("tests", (payload) => applyTestsTopic(payload, false));
  on("launches", (payload) => { applyLaunchesTopic(payload); renderSoon(renderNetwork); renderSoon(renderLogs); });
  on("activity", (payload) => applyActivityTopic(payload, false));
  on("device", applyDeviceTopic);
}

// The device's screens changed: a foldable folded, or a screen turned.
function applyDeviceTopic(payload) {
  if (payload && payload.displays) applyDisplays(payload.displays, payload.activeDisplay);
}

// Everything the server holds, in place of what the page had: the stream's
// first event, and its first again whenever it cannot resume where it left off.
function applySnapshot(snapshot) {
  if (serverInstance && snapshot.instance && snapshot.instance !== serverInstance) forgetServer();
  if (snapshot.instance) serverInstance = snapshot.instance;
  applyLaunchesTopic(snapshot.launches || {});
  applyNetworkTopic(snapshot.network || {}, true);
  applyLogsTopic(snapshot.logs || {}, true);
  applyStateTopic(snapshot.state || {}, true);
  applyTestsTopic(snapshot.tests || {}, true);
  applyActivityTopic(snapshot.activity || {}, true);
  applyDeviceTopic(snapshot.device);
  // A restarted server captures the app's logs once asked again.
  ensureLogsCapture().catch(() => renderLogs());
}

// A tab shown, a list resumed: polling fetches now; on the stream it is here already.
function refreshInspector(name) {
  if (inspectorEvents.polling) poller.poke(name);
}

// A burst of events renders each list once.
const pendingRenders = new Set();
let renderTimer = null;
function renderSoon(render) {
  pendingRenders.add(render);
  if (renderTimer) return;
  renderTimer = setTimeout(() => {
    renderTimer = null;
    const renders = [...pendingRenders];
    pendingRenders.clear();
    for (const run of renders) run();
  }, 30);
}
