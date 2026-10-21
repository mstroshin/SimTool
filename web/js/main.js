// Start-up: read /config, start the screen, open the inspector's event stream
// and schedule the polls that stand in for it. A server that restarts under the
// page is a new instance: its logs and state restart their numbering, so the
// page resets its cursors instead of skipping new entries — whichever of
// /config and the stream's snapshot tells it first.

let serverInstance = null;

const poller = createPoller((healthy, error) => {
  if (!healthy && screenState.connection === "live") setMessage("The server did not answer: " + (error && error.message ? error.message : "request failed"), "err");
});

function applyConfig(config) {
  deviceInfo.name = config.device || "";
  deviceInfo.udid = config.udid || "";
  deviceInfo.app = config.logApp || "";
  inspector.attachedApp = config.logApp || "";
  inspector.configKnown = true;
  tests.sessionsPath = config.testSessionsPath || "";
  $("deviceName").textContent = deviceInfo.name || "Simulator";
  $("deviceRuntime").textContent = runtimeName(config.runtime);
  document.title = (deviceInfo.name ? deviceInfo.name + " — " : "") + "SimTool";
  $("appName").textContent = deviceInfo.app || "No app";
  $("appName").title = deviceInfo.app ? "App under test: " + deviceInfo.app : "No app attached — start the server with --app <bundle-id>";
  $("sbDevice").textContent = [deviceInfo.name, runtimeName(config.runtime)].filter(Boolean).join(" · ");
  $("sbUdid").textContent = deviceInfo.udid ? deviceInfo.udid.slice(0, 4) + "…" + deviceInfo.udid.slice(-4) : "";
  $("sbServer").textContent = location.host;
  $("sbApp").textContent = deviceInfo.app || "No app attached";
  $("sbVersion").textContent = config.version ? "simtool " + config.version : "";
  applyDisplays(config.displays, config.activeDisplay);
}

// A new server: everything numbered by the old one is stale.
function forgetServer() {
  resetNetwork();
  resetLogs();
  resetState();
  resetActivity();
  ax.tree = null;
  networkLastPayload = "";
  testsLastSessions = "";
  testsLastDefinitions = "";
  setMessage("The server restarted — lists were reloaded");
}

async function bootstrap() {
  const config = await apiJSON("/config");
  const instance = config.instanceId || null;
  if (serverInstance && instance && instance !== serverInstance) forgetServer();
  serverInstance = instance;
  applyConfig(config);
  renderNetwork();
  renderLogs();
  renderState();
  ensureLogsCapture().catch(() => renderLogs());
}

// The screen's size in points, for the pointer readout and the rulers; the
// Accessibility tab refines it with the full tree.
async function loadScreenPoints() {
  if (screenState.points || screenState.display) return;
  try {
    const flat = await apiJSON("/api/v1/ax/tree?format=flat");
    const root = (flat.nodes || []).find((node) => node.depth === 0 && Array.isArray(node.frame));
    if (root) {
      screenState.points = { x: root.frame[0], y: root.frame[1], width: root.frame[2], height: root.frame[3] };
      updateReadoutSize();
    }
  } catch (_) { /* no AXe: the readout stays in pixels */ }
}

const ACTIVE_MS = 1500;
const BACKGROUND_MS = 6000;
const activeTab = (tab) => inspector.open && inspector.tab === tab;

// Polls stand in for the event stream only while it is down.
const polling = () => inspectorEvents.polling;
poller.add("network", () => (activeTab("network") ? ACTIVE_MS : BACKGROUND_MS), loadNetwork, polling);
poller.add("logs", () => (activeTab("logs") ? ACTIVE_MS : BACKGROUND_MS), pollLogs, () => polling() && !!inspector.attachedApp);
poller.add("state", () => (activeTab("state") ? 1000 : BACKGROUND_MS), pollState, polling);
poller.add("tests", () => (activeTab("tests") ? ACTIVE_MS : BACKGROUND_MS), loadTests, polling);
// The tree is not on the stream: it is read when the screen changed.
poller.add("ax", AX_CHECK_MS, loadAx, () => activeTab("ax") && app.dataset.mode !== "replay" && axTreeStale());
// Every tab needs it — the marks on the screen and who drives the device — so
// while the stream is down it is polled quickly.
poller.add("activity", 500, pollActivity, polling);

onReconnect(async () => {
  try { await bootstrap(); } catch (_) {}
  // A server that came back may be one that streams, where the last one did not.
  startInspectorEvents();
  for (const name of ["network", "logs", "state", "tests", "activity"]) refreshInspector(name);
});

onConnection((state) => {
  // The guide lines say whether the lists are live.
  renderNetwork();
  if (inspector.tab === "logs") renderLogs();
});

$("themeButton").addEventListener("click", toggleTheme);
renderTheme();
setInspectorOpen(inspector.open);
setTab(inspector.tab);
updateKeyboardIndicator();
startInspectorEvents();
runStream();
bootstrap().catch((error) => setMessage("Could not read the server's configuration: " + error.message, "err")).then(loadScreenPoints);
