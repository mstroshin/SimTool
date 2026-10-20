// Start-up: read /config, start the screen, schedule the polls. A server that
// restarts under the page is a new instance: its logs and state restart their
// numbering, so the page resets its cursors instead of skipping new entries.

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
}

async function bootstrap() {
  const config = await apiJSON("/config");
  const instance = config.instanceId || null;
  if (serverInstance && instance && instance !== serverInstance) {
    // A new server: everything numbered by the old one is stale.
    resetNetwork();
    resetLogs();
    resetState();
    ax.tree = null;
    networkLastPayload = "";
    testsLastSessions = "";
    testsLastDefinitions = "";
    setMessage("The server restarted — lists were reloaded");
  }
  serverInstance = instance;
  applyConfig(config);
  renderNetwork();
  renderLogs();
  renderState();
}

// The screen's size in points, for the pointer readout and the rulers; the
// Accessibility tab refines it with the full tree.
async function loadScreenPoints() {
  if (screenState.points) return;
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

poller.add("network", () => (activeTab("network") ? ACTIVE_MS : BACKGROUND_MS), loadNetwork);
poller.add("logs", () => (activeTab("logs") ? ACTIVE_MS : BACKGROUND_MS), pollLogs, () => !!inspector.attachedApp);
poller.add("state", () => (activeTab("state") ? 1000 : BACKGROUND_MS), pollState);
poller.add("ax", 2000, loadAx, () => activeTab("ax") && app.dataset.mode !== "replay");
poller.add("tests", () => (activeTab("tests") ? ACTIVE_MS : BACKGROUND_MS), loadTests);

onReconnect(async () => {
  try { await bootstrap(); } catch (_) {}
  for (const name of ["network", "logs", "state", "tests"]) poller.poke(name);
});

onConnection((state) => {
  // The guide lines say whether the lists are live.
  renderNetwork();
  if (inspector.tab === "logs") renderLogs();
});

setInspectorOpen(inspector.open);
setTab(inspector.tab);
updateKeyboardIndicator();
runStream();
bootstrap().catch((error) => setMessage("Could not read the server's configuration: " + error.message, "err")).then(loadScreenPoints);
