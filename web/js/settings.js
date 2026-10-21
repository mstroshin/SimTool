// The Device tab: the simulator's settings and debug switches as the device
// reports them — appearance, text size, contrast, the render server's debug
// colours, slow animations, Face ID or Touch ID, the status bar, the
// location — with the controls that change them, and the actions
// Simulator.app kept in its menus: a memory warning, a push. A change goes to
// POST /api/v1/device and lands in Activity like any other action; the tab
// reads the device again after it, while it is open, and when Activity says
// something else changed a setting.

const deviceSettings = { data: null, error: "", loaded: false, loading: null };
// Activity kinds that change what this tab shows.
const DEVICE_SETTING_KINDS = new Set(["appearance", "text-size", "contrast", "debug", "biometrics", "status-bar", "location"]);
const DEBUG_OPTIONS = [
  ["slow-animations", "Slow Animations", "Every app's animations run ten times slower"],
  ["color-blended", "Color Blended Layers", "Green where layers are opaque, red where they blend"],
  ["color-copies", "Color Copied Images", "Cyan where Core Animation copies an image it cannot use as is"],
  ["color-misaligned", "Color Misaligned Images", "Magenta on images off the pixel grid, yellow on scaled ones"],
  ["color-offscreen", "Color Off-screen Rendered", "Yellow where a layer is rendered off-screen first"]
];
const TEXT_SIZES = [
  ["extra-small", "XS"], ["small", "S"], ["medium", "M"], ["large", "L — default"], ["extra-large", "XL"],
  ["extra-extra-large", "XXL"], ["extra-extra-extra-large", "XXXL"], ["accessibility-medium", "AX1"],
  ["accessibility-large", "AX2"], ["accessibility-extra-large", "AX3"], ["accessibility-extra-extra-large", "AX4"],
  ["accessibility-extra-extra-extra-large", "AX5"]
];

async function loadDeviceSettings() {
  if (deviceSettings.loading) return deviceSettings.loading;
  deviceSettings.loading = (async () => {
    try {
      deviceSettings.data = await apiJSON("/api/v1/device");
      deviceSettings.error = "";
    } catch (error) {
      deviceSettings.error = error.message || String(error);
    } finally {
      deviceSettings.loaded = true;
      deviceSettings.loading = null;
      syncDeviceSettings();
    }
  })();
  return deviceSettings.loading;
}

// Changes the device; a person's change during someone else's run asks first.
async function postDevice(payload, label) {
  if (!manualInputAllowed(() => postDevice(payload, label))) return false;
  try {
    await api("/api/v1/device", { method: "POST", body: JSON.stringify(payload), headers: { "X-SimTool-Source": "viewer" } });
    toast(label);
    return true;
  } catch (error) {
    fail(label + " failed", error);
    return false;
  } finally {
    loadDeviceSettings();
  }
}

// What Activity brings: a setting changed by an agent, a test or another viewer.
function deviceActivitySeen(entries) {
  if (activeTab("device") && entries.some((entry) => entry.status !== "running" && DEVICE_SETTING_KINDS.has(entry.kind))) loadDeviceSettings();
}

function setDebugOption(option, enabled) {
  const title = (DEBUG_OPTIONS.find(([name]) => name === option) || [option, option])[1];
  return postDevice({ action: "debug", option, enabled }, title + (enabled ? " on" : " off"));
}

function setAppearance(value) { return postDevice({ action: "appearance", value }, (value === "dark" ? "Dark" : "Light") + " appearance"); }
function setTextSize(value) { return postDevice({ action: "content-size", value }, value === "increment" ? "Larger text" : value === "decrement" ? "Smaller text" : "Text size " + textSizeName(value)); }
function setContrast(enabled) { return postDevice({ action: "increase-contrast", enabled }, "Increase Contrast " + (enabled ? "on" : "off")); }
function simulateMemoryWarning() { return postDevice({ action: "memory-warning" }, "Memory warning sent"); }
function biometrics(value) {
  const sensor = biometryName();
  const words = { enroll: sensor + " enrolled", unenroll: sensor + " unenrolled", match: "Matching " + biometryThing(), nomatch: "Non-matching " + biometryThing() };
  return postDevice({ action: "biometrics", value }, words[value]);
}
function statusBarPreset(value) {
  return value === "clear" ? postDevice({ action: "status-bar", value: "clear" }, "Status bar overrides cleared")
    : postDevice({ action: "status-bar", statusBar: { time: "9:41", dataNetwork: "wifi", wifiMode: "active", wifiBars: 3, batteryState: "charged", batteryLevel: 100 } }, "Status bar set to 9:41");
}
function clearLocation() { return postDevice({ action: "location", value: "clear" }, "Location cleared"); }

function textSizeName(value) { const size = TEXT_SIZES.find(([name]) => name === value); return size ? size[1].split(" ")[0] : value; }
function biometryName() { const kind = deviceSettings.data && deviceSettings.data.biometrics && deviceSettings.data.biometrics.kind; return kind === "touch" ? "Touch ID" : "Face ID"; }
function biometryThing() { return biometryName() === "Touch ID" ? "finger" : "face"; }

// ---- The panel: built once, synced with each reading ----

function switchButton(label, description, onToggle) {
  const button = el("button", { class: "sw", type: "button", role: "switch", "aria-checked": "false", "aria-label": label, title: description || label });
  button.addEventListener("click", () => onToggle(button.getAttribute("aria-checked") !== "true"));
  return button;
}

function settingRow(name, control, note) {
  return el("div", { class: "dev-row" }, el("span", { class: "dev-name", text: name }), note || null, control);
}

function field(label, control) {
  return el("label", { class: "field" }, el("span", { text: label }), control);
}

function select(options, label) {
  const node = el("select", { class: "input", "aria-label": label });
  for (const [value, text] of options) node.append(el("option", { value, text }));
  return node;
}

function devSection(title, ...children) {
  return el("section", { class: "dev-sec", "aria-label": title }, el("h3", { text: title }), ...children);
}

const devicePanel = $("panel-device");
const deviceRead = el("span", { class: "muted" });
const deviceRefresh = el("button", { class: "tb-btn", type: "button", "aria-label": "Read the settings from the device again", "data-tip": "Read the settings from the device again", html: icon("relaunch") });
deviceRefresh.addEventListener("click", () => loadDeviceSettings());
const deviceProblem = el("div", { class: "callout warn", hidden: true });

const appearanceSeg = segmented("Appearance", [["light", "Light"], ["dark", "Dark"]], () => deviceSettings.data && deviceSettings.data.appearance, setAppearance);
const textSizeSelect = select(TEXT_SIZES, "Text size");
textSizeSelect.addEventListener("change", () => setTextSize(textSizeSelect.value));
const textSmaller = el("button", { class: "btn btn-sm", type: "button", "aria-label": "Smaller text", "data-tip": "Smaller text", text: "A−" });
const textLarger = el("button", { class: "btn btn-sm", type: "button", "aria-label": "Larger text", "data-tip": "Larger text", text: "A+" });
textSmaller.addEventListener("click", () => setTextSize("decrement"));
textLarger.addEventListener("click", () => setTextSize("increment"));
const contrastSwitch = switchButton("Increase Contrast", "Increase Contrast", setContrast);

const debugSwitches = {};
for (const [option, title, description] of DEBUG_OPTIONS) debugSwitches[option] = switchButton(title, description, (on) => setDebugOption(option, on));
const memoryButton = el("button", { class: "btn btn-sm", type: "button", text: "Simulate memory warning", title: "Every app gets didReceiveMemoryWarning, as on a device short of memory" });
memoryButton.addEventListener("click", simulateMemoryWarning);

const biometryTitle = el("h3", { text: "Face ID" });
const enrolledSwitch = switchButton("Enrolled", "Whether a face or a finger is enrolled — what canEvaluatePolicy reads", (on) => biometrics(on ? "enroll" : "unenroll"));
const matchButton = el("button", { class: "btn btn-sm", type: "button", text: "Matching face" });
const noMatchButton = el("button", { class: "btn btn-sm", type: "button", text: "Non-matching face" });
matchButton.addEventListener("click", () => biometrics("match"));
noMatchButton.addEventListener("click", () => biometrics("nomatch"));

const statusNow = el("span", { class: "dev-now" });
const statusTime = el("input", { class: "input", type: "text", placeholder: "9:41", "aria-label": "Time" });
const statusBattery = el("input", { class: "input", type: "number", min: "0", max: "100", placeholder: "100", "aria-label": "Battery level" });
const statusBatteryState = select([["", "—"], ["charging", "Charging"], ["charged", "Charged"], ["discharging", "Discharging"]], "Battery state");
const statusNetwork = select([["", "—"], ["wifi", "Wi-Fi"], ["hide", "Hidden"], ["3g", "3G"], ["4g", "4G"], ["lte", "LTE"], ["lte-a", "LTE-A"], ["lte+", "LTE+"], ["5g", "5G"], ["5g+", "5G+"], ["5g-uwb", "5G UWB"], ["5g-uc", "5G UC"]], "Data network");
const statusWifi = select([["", "—"], ["0", "0"], ["1", "1"], ["2", "2"], ["3", "3"]], "Wi-Fi bars");
const statusCell = select([["", "—"], ["0", "0"], ["1", "1"], ["2", "2"], ["3", "3"], ["4", "4"]], "Cellular bars");
const statusOperator = el("input", { class: "input", type: "text", placeholder: "Carrier", "aria-label": "Operator name" });
const statusApply = el("button", { class: "btn btn-sm btn-primary", type: "button", text: "Override" });
const statusClean = el("button", { class: "btn btn-sm", type: "button", text: "9:41 for screenshots", title: "9:41, full Wi-Fi, a charged battery" });
const statusClear = el("button", { class: "btn btn-sm", type: "button", text: "Clear overrides" });
statusApply.addEventListener("click", () => {
  const bar = {};
  if (statusTime.value.trim()) bar.time = statusTime.value.trim();
  if (statusBattery.value !== "") bar.batteryLevel = Number(statusBattery.value);
  if (statusBatteryState.value) bar.batteryState = statusBatteryState.value;
  if (statusNetwork.value) bar.dataNetwork = statusNetwork.value;
  if (statusWifi.value) bar.wifiBars = Number(statusWifi.value);
  if (statusCell.value) bar.cellularBars = Number(statusCell.value);
  if (statusOperator.value) bar.operatorName = statusOperator.value;
  if (!Object.keys(bar).length) { toast("Fill in a field to override", { error: true }); return; }
  postDevice({ action: "status-bar", statusBar: bar }, "Status bar overridden");
});
statusClean.addEventListener("click", () => statusBarPreset("clean"));
statusClear.addEventListener("click", () => statusBarPreset("clear"));

const locationNow = el("span", { class: "dev-now" });
const locationPoint = el("input", { class: "input", type: "text", placeholder: "37.3349, -122.0090", "aria-label": "Latitude, longitude" });
const locationSet = el("button", { class: "btn btn-sm btn-primary", type: "button", text: "Set" });
const locationRoute = el("textarea", { class: "input", rows: "3", placeholder: "One latitude, longitude per line — two or more", "aria-label": "Route" });
const locationSpeed = el("input", { class: "input", type: "number", min: "0.1", step: "any", placeholder: "20", "aria-label": "Speed, metres per second" });
const locationStart = el("button", { class: "btn btn-sm", type: "button", text: "Start the route" });
const locationClear = el("button", { class: "btn btn-sm", type: "button", text: "Clear" });
locationSet.addEventListener("click", () => {
  const point = parseCoordinate(locationPoint.value);
  if (!point) { toast("A location is latitude, longitude — like 37.3349, -122.0090", { error: true }); return; }
  postDevice({ action: "location", location: { waypoints: [point] } }, "Location set");
});
locationStart.addEventListener("click", () => {
  const points = locationRoute.value.split("\n").map((line) => line.trim()).filter(Boolean).map(parseCoordinate);
  if (points.length < 2 || points.some((point) => !point)) { toast("A route is two or more lines of latitude, longitude", { error: true }); return; }
  const location = { waypoints: points };
  if (locationSpeed.value) location.speed = Number(locationSpeed.value);
  postDevice({ action: "location", location }, "Route started");
});
locationClear.addEventListener("click", clearLocation);

const pushApp = el("input", { class: "input", type: "text", "aria-label": "App bundle identifier" });
const pushPayload = el("textarea", { class: "input", rows: "5", spellcheck: "false", "aria-label": "Payload JSON" });
pushPayload.value = JSON.stringify({ aps: { alert: { title: "SimTool", body: "A push from the viewer" }, sound: "default" } }, null, 2);
const pushSend = el("button", { class: "btn btn-sm btn-primary", type: "button", text: "Send" });
pushSend.addEventListener("click", () => {
  let payload;
  try { payload = JSON.parse(pushPayload.value); } catch (error) { toast("The payload is not JSON: " + error.message, { error: true }); return; }
  const bundleId = pushApp.value.trim() || deviceInfo.app;
  if (!bundleId) { toast("Name the app to push to", { error: true }); return; }
  postDevice({ action: "push", bundleId, payload }, "Push sent to " + bundleId);
});

const deviceBody = el("div", { class: "dev-body" },
  deviceProblem,
  devSection("Appearance and text",
    settingRow("Appearance", appearanceSeg),
    settingRow("Text size", el("span", { class: "dev-inline" }, textSmaller, textSizeSelect, textLarger)),
    settingRow("Increase Contrast", contrastSwitch)),
  devSection("Rendering",
    ...DEBUG_OPTIONS.map(([option, title]) => settingRow(title, debugSwitches[option])),
    el("div", { class: "dev-actions" }, memoryButton)),
  el("section", { class: "dev-sec", "aria-label": "Biometrics" }, biometryTitle,
    settingRow("Enrolled", enrolledSwitch),
    el("div", { class: "dev-actions" }, matchButton, noMatchButton)),
  devSection("Status bar",
    el("div", { class: "dev-row" }, statusNow),
    el("div", { class: "dev-grid" },
      field("Time", statusTime), field("Battery %", statusBattery), field("Battery", statusBatteryState),
      field("Data network", statusNetwork), field("Wi-Fi bars", statusWifi), field("Cellular bars", statusCell), field("Operator", statusOperator)),
    el("div", { class: "dev-actions" }, statusApply, statusClean, statusClear)),
  devSection("Location",
    el("div", { class: "dev-row" }, locationNow),
    el("div", { class: "dev-inline" }, locationPoint, locationSet),
    field("Route", locationRoute),
    el("div", { class: "dev-actions" }, field("Speed, m/s", locationSpeed), locationStart, locationClear)),
  devSection("Push notification",
    field("App", pushApp),
    field("Payload", pushPayload),
    el("div", { class: "dev-actions" }, pushSend))
);
devicePanel.append(el("div", { class: "ptool" }, deviceRead, el("span", { class: "ptool-spacer" }), deviceRefresh), deviceBody);

function parseCoordinate(text) {
  const parts = String(text).split(",").map((part) => Number(part.trim()));
  if (parts.length !== 2 || parts.some((part) => !isFinite(part)) || Math.abs(parts[0]) > 90 || Math.abs(parts[1]) > 180) return null;
  return { latitude: parts[0], longitude: parts[1] };
}

function setSwitch(button, on) {
  button.setAttribute("aria-checked", String(!!on));
  button.disabled = on == null;
}

// Each control shows the device's answer; what it would not tell stays blank
// and the callout says why.
function syncDeviceSettings() {
  const data = deviceSettings.data || {};
  deviceRead.textContent = deviceSettings.error ? "Could not read the device" : deviceSettings.loaded ? "As the device reports it" : "Reading the device…";
  const problems = Object.entries(data.unavailable || {}).map(([name, reason]) => name + ": " + reason);
  if (deviceSettings.error) problems.unshift(deviceSettings.error);
  deviceProblem.hidden = !problems.length;
  deviceProblem.innerHTML = icon("warn") + "<span>" + problems.map(escapeHTML).join("<br>") + "</span>";
  appearanceSeg.sync();
  if (data.contentSize && TEXT_SIZES.some(([name]) => name === data.contentSize)) textSizeSelect.value = data.contentSize;
  setSwitch(contrastSwitch, data.increaseContrast);
  for (const [option] of DEBUG_OPTIONS) setSwitch(debugSwitches[option], data.debug ? data.debug[option] : null);
  const bio = data.biometrics;
  biometryTitle.textContent = bio && !bio.kind ? "Biometrics — this device has no sensor" : biometryName();
  setSwitch(enrolledSwitch, bio ? bio.enrolled : null);
  matchButton.textContent = "Matching " + biometryThing();
  noMatchButton.textContent = "Non-matching " + biometryThing();
  matchButton.title = noMatchButton.title = "Answers the " + biometryName() + " prompt the app has up";
  statusNow.textContent = data.statusBar ? "Now: " + statusBarSummary(data.statusBar) : "";
  locationNow.textContent = data.location ? "Set by SimTool " + formatAgo(data.location.setAt) + ": " + locationSummary(data.location) : "No location set by SimTool — simctl cannot read one back";
  pushApp.placeholder = deviceInfo.app || "com.example.app";
}

function statusBarSummary(bar) {
  const parts = [];
  if (bar.time) parts.push(bar.time);
  if (bar.dataNetwork) parts.push(bar.dataNetwork);
  if (bar.wifiBars != null) parts.push("Wi-Fi " + bar.wifiBars + "/3");
  if (bar.cellularBars != null) parts.push("cell " + bar.cellularBars + "/4");
  if (bar.operatorName) parts.push(bar.operatorName);
  if (bar.batteryLevel != null) parts.push(bar.batteryLevel + "%" + (bar.batteryState ? " " + bar.batteryState : ""));
  return parts.length ? parts.join(" · ") : "no overrides";
}

function locationSummary(location) {
  const points = location.waypoints || [];
  if (points.length === 1) return points[0].latitude + ", " + points[0].longitude;
  return "a route of " + points.length + " points" + (location.speed ? " at " + location.speed + " m/s" : "");
}

tabHandlers.device = { show() { syncDeviceSettings(); loadDeviceSettings(); } };
syncDeviceSettings();
