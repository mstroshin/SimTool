// The Device tab: the simulator's settings and debug switches as the device
// reports them — appearance, text size, accessibility, orientation, the render
// server's debug colours, slow animations, Face ID or Touch ID, the status
// bar, the location — with the controls that change them, the actions
// Simulator.app kept in its menus (a memory warning, a push), the camera
// SimTool gives the apps it launches, and the app under test: its card, its
// permissions, the keychain. A change goes to POST /api/v1/device (a turn to
// /api/v1/input, the camera to /api/v1/camera) and lands in Activity like any
// other action; the tab reads the device again after it, while it is open,
// and when Activity says something else changed a setting.

const deviceSettings = { data: null, error: "", loaded: false, loading: null };
// Activity kinds that change what this tab shows.
const DEVICE_SETTING_KINDS = new Set(["appearance", "text-size", "contrast", "debug", "biometrics", "status-bar", "location", "accessibility", "rotate", "permission", "install", "keychain", "camera"]);
// The camera: its source, the apps that have it, the Mac's cameras.
const camera = { data: null, error: "" };
const AX_SWITCHES = [
  ["reduce-motion", "reduceMotion", "Reduce Motion", "Apps replace zooms and slides with fades"],
  ["reduce-transparency", "reduceTransparency", "Reduce Transparency", "Blurs and translucent materials turn opaque"],
  ["button-shapes", "buttonShapes", "Button Shapes", "Text buttons are underlined"],
  ["voiceover", "voiceOver", "VoiceOver", "The screen reader: a tap selects, a double-tap activates — the first time, iOS shows its gestures sheet"]
];
const COLOR_FILTERS = [["none", "None"], ["grayscale", "Grayscale"], ["protanopia", "Red/Green — protanopia"], ["deuteranopia", "Green/Red — deuteranopia"], ["tritanopia", "Blue/Yellow — tritanopia"]];
const ORIENTATIONS = [["portrait", "Portrait"], ["landscape-left", "Landscape left"], ["landscape-right", "Landscape right"], ["upside-down", "Upside down"]];
const PERMISSIONS = [
  ["notifications", "Notifications"], ["location", "Location"], ["camera", "Camera"], ["microphone", "Microphone"], ["photos", "Photos"],
  ["photos-add", "Add to Photos"], ["contacts", "Contacts"], ["calendar", "Calendars"], ["reminders", "Reminders"], ["motion", "Motion & Fitness"],
  ["media-library", "Media & Apple Music"], ["siri", "Siri"], ["speech", "Speech Recognition"], ["faceid", "Face ID"],
  ["user-tracking", "Tracking (ATT)"], ["pasteboard", "Paste from Other Apps"]
];
const appCard = { data: null, error: "", shown: "" };
// The sections a person unfolded, by name; every section starts folded.
const deviceSections = stored("device.sections", {});
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
  loadAppCard();
  loadCamera();
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
  if (!activeTab("device")) return;
  const done = entries.filter((entry) => entry.status !== "running");
  if (done.some((entry) => DEVICE_SETTING_KINDS.has(entry.kind))) loadDeviceSettings();
  // An app that starts or ends takes the camera with it.
  else if (done.some((entry) => entry.kind === "launch" || entry.kind === "terminate")) loadCamera();
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

function setAccessibility(option, value, label) { return postDevice({ action: "accessibility", option, value }, label); }

function rotateDevice(name) {
  if (screenState.foldable) { toast("A foldable turns its picture as it folds — pick a pose instead", { error: true }); return; }
  const label = name === "left" || name === "right" ? "Rotate " + name : "Rotate to " + ((ORIENTATIONS.find(([value]) => value === name) || [name, name])[1]).toLowerCase();
  deviceAction(label, { action: "rotate", name }, label).then(() => loadDeviceSettings());
}

// A permission's choice as the select offers it: what the app reads.
function setPermission(permission, choice) {
  const app = deviceInfo.app;
  if (!app) { toast("No app attached — start the server with --app <bundle-id>", { error: true }); return; }
  const value = { granted: "grant", denied: "deny", always: "always", "not-determined": "reset" }[choice];
  const title = (PERMISSIONS.find(([name]) => name === permission) || [permission, permission])[1];
  const run = () => postDevice({ action: "permission", option: permission, value, bundleId: app }, title + ": " + choice.replace("-", " ")).then(() => loadAppCard());
  if (permission !== "notifications") { run(); return; }
  // SpringBoard reads notification permission only as it starts.
  confirmDestructive("Respring the simulator?", "SpringBoard reads notification permission only as it starts, so the simulator resprings — the screen goes dark for a few seconds and running apps end.", "Respring").then((yes) => { if (yes) run(); else syncAppCard(true); });
}

async function loadAppCard() {
  if (!deviceInfo.app) { appCard.data = null; appCard.error = ""; syncAppCard(); return; }
  try {
    appCard.data = await apiJSON("/api/v1/app?bundleId=" + encodeURIComponent(deviceInfo.app));
    appCard.error = "";
  } catch (error) {
    appCard.error = error.message || String(error);
  }
  syncAppCard();
}

async function revealApp(what) {
  try {
    const result = await apiJSON("/api/v1/app/reveal", { method: "POST", body: JSON.stringify({ bundleId: deviceInfo.app, what }) });
    toast("Shown in the Finder: " + result.stdout.split("/").slice(-2).join("/"));
  } catch (error) {
    fail("Reveal in Finder failed", error);
  }
}

function addRootCertificate(file) {
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    const base64 = String(reader.result).split(",")[1] || "";
    postDevice({ action: "keychain", value: "add-root-cert", certificate: base64 }, file.name + " trusted as a root");
  };
  reader.readAsDataURL(file);
}

function resetKeychain() {
  confirmDestructive("Reset the keychain?", "Every password, key and certificate on this simulator is deleted, for every app.", "Reset").then((yes) => {
    if (yes) postDevice({ action: "keychain", value: "reset" }, "Keychain reset");
  });
}

async function loadCamera() {
  try {
    camera.data = await apiJSON("/api/v1/camera");
    camera.error = "";
  } catch (error) {
    camera.error = error.message || String(error);
  }
  syncCamera();
}

// Sets the camera's picture: a file, the Mac's camera, or nothing.
async function changeCamera(label, path, options) {
  if (!manualInputAllowed(() => changeCamera(label, path, options))) return;
  try {
    const headers = { "X-SimTool-Source": "viewer", ...(options.headers || {}) };
    camera.data = await apiJSON(path, { ...options, headers });
    camera.error = "";
    toast(label + (camera.data.source !== "none" && !camera.data.apps.length && deviceInfo.app ? " — relaunch " + deviceInfo.app + " to give it the camera" : ""));
  } catch (error) {
    fail(label + " failed", error);
  }
  syncCamera();
}

function setCameraFile(file) {
  if (!file) return;
  changeCamera("Camera: " + file.name, "/api/v1/camera", { method: "POST", body: file, headers: { "Content-Type": file.type || "application/octet-stream", "X-SimTool-Filename": encodeURIComponent(file.name) } });
}

function useMacCamera(id) {
  toast("Starting the Mac's camera — macOS may ask to allow it");
  changeCamera("Camera: the Mac's camera", "/api/v1/camera/webcam", { method: "POST", body: JSON.stringify(id ? { camera: id } : {}) });
}

function cameraOff() { changeCamera("Camera off", "/api/v1/camera", { method: "DELETE" }); }

function cameraSummary(data) {
  if (!data || data.source === "none") return "Off";
  if (data.source === "webcam") return "Shows the Mac's " + (data.name || "camera");
  return "Shows " + (data.name || "a file") + (data.source === "video" ? ", in a loop" : "");
}

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

// A section that folds; it starts folded and stays as a person leaves it.
// `title` is its heading's words, or the heading itself when they change.
function devSection(name, title, ...children) {
  const heading = typeof title === "string" ? el("h3", { text: title }) : title;
  return el("details", { class: "dev-sec", "data-sec": name, open: deviceSections[name] === true }, el("summary", {}, heading), ...children);
}

// Unfolds a section, for a command that leads into it.
function openDeviceSection(name) {
  const section = deviceBody.querySelector('details.dev-sec[data-sec="' + name + '"]');
  if (section) section.open = true;
  return section;
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

const axSwitches = {};
for (const [option, key, title, description] of AX_SWITCHES) axSwitches[key] = switchButton(title, description, (on) => setAccessibility(option, on ? "on" : "off", title + (on ? " on" : " off")));
const colorFilterSelect = select(COLOR_FILTERS, "Color filter");
colorFilterSelect.addEventListener("change", () => setAccessibility("color-filter", colorFilterSelect.value, "Color filter: " + colorFilterSelect.selectedOptions[0].textContent));
const glassSeg = segmented("Liquid Glass", [["clear", "Clear"], ["tinted", "Tinted"]], () => deviceSettings.data && deviceSettings.data.accessibility && deviceSettings.data.accessibility.liquidGlass, (value) => setAccessibility("liquid-glass", value, "Liquid Glass " + value));
const glassRow = settingRow("Liquid Glass", glassSeg);
const orientationSeg = segmented("Orientation", ORIENTATIONS, () => deviceSettings.data && deviceSettings.data.orientation, rotateDevice);

const appBody = el("div", { class: "dev-app" });
const permissionRows = el("div", { class: "dev-perms", role: "group", "aria-label": "Permissions" });
const certificateFile = el("input", { type: "file", accept: ".pem,.cer,.crt,.der", hidden: true });
certificateFile.addEventListener("change", () => { const file = certificateFile.files && certificateFile.files[0]; certificateFile.value = ""; addRootCertificate(file); });
const certificateAdd = el("button", { class: "btn btn-sm", type: "button", text: "Add a root certificate…", title: "Trust a proxy's CA (Proxyman, Charles, mitmproxy) for TLS" });
certificateAdd.addEventListener("click", () => certificateFile.click());
const keychainReset = el("button", { class: "btn btn-sm btn-danger", type: "button", text: "Reset the keychain" });
keychainReset.addEventListener("click", resetKeychain);

const cameraNow = el("div", { class: "dev-row" });
const cameraApps = el("div", { class: "dev-now" });
const cameraFile = el("input", { type: "file", accept: "image/*,video/mp4,video/quicktime,.mov,.mp4,.m4v,.heic", hidden: true });
cameraFile.addEventListener("change", () => { const file = cameraFile.files && cameraFile.files[0]; cameraFile.value = ""; setCameraFile(file); });
const cameraPick = el("button", { class: "btn btn-sm", type: "button", text: "Image or video…", title: "The camera shows an image, or a video in a loop — a QR code, a document, a face" });
cameraPick.addEventListener("click", () => cameraFile.click());
const cameraMac = select([], "Mac camera");
const cameraWebcam = el("button", { class: "btn btn-sm", type: "button", text: "Use the Mac's camera", title: "The server captures the Mac's camera; macOS asks once" });
cameraWebcam.addEventListener("click", () => useMacCamera(cameraMac.value));
const cameraOffButton = el("button", { class: "btn btn-sm", type: "button", text: "Turn off" });
cameraOffButton.addEventListener("click", cameraOff);
const cameraRelaunch = el("button", { class: "btn btn-sm btn-primary", type: "button", text: "Relaunch the app" });
cameraRelaunch.addEventListener("click", () => relaunchApp());

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
  devSection("appearance", "Appearance and text",
    settingRow("Appearance", appearanceSeg),
    settingRow("Text size", el("span", { class: "dev-inline" }, textSmaller, textSizeSelect, textLarger)),
    settingRow("Increase Contrast", contrastSwitch)),
  devSection("accessibility", "Accessibility",
    ...AX_SWITCHES.map(([, key, title]) => settingRow(title, axSwitches[key])),
    settingRow("Color filter", colorFilterSelect),
    el("div", { class: "dev-now", text: "Apps read the filter; the simulator's screen shows none." }),
    glassRow),
  devSection("orientation", "Orientation",
    el("div", { class: "dev-row" }, orientationSeg)),
  devSection("rendering", "Rendering",
    ...DEBUG_OPTIONS.map(([option, title]) => settingRow(title, debugSwitches[option])),
    el("div", { class: "dev-actions" }, memoryButton)),
  devSection("biometrics", biometryTitle,
    settingRow("Enrolled", enrolledSwitch),
    el("div", { class: "dev-actions" }, matchButton, noMatchButton)),
  devSection("status-bar", "Status bar",
    el("div", { class: "dev-row" }, statusNow),
    el("div", { class: "dev-grid" },
      field("Time", statusTime), field("Battery %", statusBattery), field("Battery", statusBatteryState),
      field("Data network", statusNetwork), field("Wi-Fi bars", statusWifi), field("Cellular bars", statusCell), field("Operator", statusOperator)),
    el("div", { class: "dev-actions" }, statusApply, statusClean, statusClear)),
  devSection("location", "Location",
    el("div", { class: "dev-row" }, locationNow),
    el("div", { class: "dev-inline" }, locationPoint, locationSet),
    field("Route", locationRoute),
    el("div", { class: "dev-actions" }, field("Speed, m/s", locationSpeed), locationStart, locationClear)),
  devSection("camera", "Camera",
    cameraNow,
    cameraApps,
    el("div", { class: "dev-actions" }, cameraPick, cameraOffButton, cameraRelaunch, cameraFile),
    el("div", { class: "dev-inline" }, cameraMac, cameraWebcam)),
  devSection("push", "Push notification",
    field("App", pushApp),
    field("Payload", pushPayload),
    el("div", { class: "dev-actions" }, pushSend)),
  devSection("app", "App", appBody),
  devSection("permissions", "Permissions", permissionRows),
  devSection("keychain", "Keychain",
    el("div", { class: "dev-actions" }, certificateAdd, keychainReset, certificateFile))
);
devicePanel.append(el("div", { class: "ptool" }, deviceRead, el("span", { class: "ptool-spacer" }), deviceRefresh), deviceBody);
deviceBody.addEventListener("toggle", (event) => {
  const section = event.target;
  if (!section.matches || !section.matches("details.dev-sec")) return;
  deviceSections[section.dataset.sec] = section.open;
  store("device.sections", deviceSections);
}, true);

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
  const ax = data.accessibility || {};
  for (const [, key] of AX_SWITCHES) setSwitch(axSwitches[key], data.accessibility ? ax[key] : null);
  colorFilterSelect.disabled = !ax.colorFilter;
  if (ax.colorFilter) colorFilterSelect.value = ax.colorFilter;
  glassRow.hidden = !ax.liquidGlass;
  glassSeg.sync();
  orientationSeg.sync();
  for (const button of orientationSeg.children) button.disabled = !!screenState.foldable;
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

// The app card and its permissions, redrawn only when what the server says changed.
function syncAppCard(force) {
  const shown = JSON.stringify([deviceInfo.app, appCard.data, appCard.error]);
  if (!force && shown === appCard.shown) return;
  appCard.shown = shown;
  appBody.innerHTML = "";
  permissionRows.innerHTML = "";
  const info = appCard.data;
  if (!deviceInfo.app) {
    appBody.append(el("div", { class: "dev-now", text: "No app attached — start the server with --app <bundle-id>. Drop an .app or an .ipa on the screen to install one." }));
    permissionRows.append(el("div", { class: "dev-now", text: "Permissions belong to an app: attach one." }));
    return;
  }
  if (appCard.error) appBody.append(el("div", { class: "callout warn", html: icon("warn") + "<span>" + escapeHTML(appCard.error) + "</span>" }));
  if (!info) return;
  if (!info.installed) {
    appBody.append(el("div", { class: "dev-now", text: deviceInfo.app + " is not installed on this simulator. Drop its .app or .ipa on the screen to install it." }));
    return;
  }
  const path = (value, what) => value ? el("span", { class: "dev-path" }, el("span", { class: "mono", title: value, text: value }),
    el("button", { class: "btn btn-sm", type: "button", text: "Reveal", title: "Show it in the Finder", onclick: () => revealApp(what) }),
    el("button", { class: "btn btn-sm", type: "button", text: "Copy", onclick: () => copyText(value, "Path copied") })) : el("span", { text: "—" });
  const rows = [
    ["App", (info.name ? info.name + " — " : "") + info.bundleId],
    ["Version", [info.version, info.build ? "(" + info.build + ")" : ""].filter(Boolean).join(" ") || "—"],
    ["Minimum iOS", info.minimumOS || "—"],
    ["Process", info.pid ? "pid " + info.pid : "not running"]
  ];
  const list = el("dl", { class: "kv" });
  for (const [name, value] of rows) list.append(el("dt", { text: name }), el("dd", { text: value }));
  list.append(el("dt", { text: "Bundle" }), el("dd", {}, path(info.bundlePath, "bundle")), el("dt", { text: "Data" }), el("dd", {}, path(info.dataContainer, "data")));
  appBody.append(list, el("div", { class: "dev-now", text: "Drop an .app or an .ipa on the screen to install a build; images and videos go to Photos." }));
  const states = info.permissions || {};
  for (const [name, title] of PERMISSIONS) {
    const state = states[name] || "not-determined";
    const options = [["not-determined", "Not asked"], ["granted", name === "location" ? "While using" : "Granted"], ["denied", "Denied"]];
    if (name === "location") options.push(["always", "Always"]);
    if (!options.some(([value]) => value === state)) options.push([state, state.replace("-", " ")]);
    const choice = select(options, title);
    choice.value = state;
    choice.addEventListener("change", () => setPermission(name, choice.value));
    permissionRows.append(settingRow(title, choice));
  }
}

// The camera SimTool gives the apps it launches: what it shows, who has it.
function syncCamera() {
  const data = camera.data;
  cameraNow.textContent = camera.error ? "Could not read the camera: " + camera.error : cameraSummary(data);
  const on = !!data && data.source !== "none";
  const apps = (data && data.apps) || [];
  const holders = apps.map((client) => client.bundleId + (client.running ? " (capturing)" : "")).join(", ");
  cameraApps.textContent = !on
    ? apps.length
      ? holders + (apps.length === 1 ? " sees" : " see") + " black until the camera shows something again."
      : "The apps SimTool launches get a back and a front camera showing an image, a video or the Mac's camera — previews, photos, code scanning."
    : apps.length
      ? holders + (apps.length === 1 ? " has it." : " have it.")
      : "No app has it yet: an app gets the camera when SimTool launches it.";
  cameraRelaunch.hidden = !on || !deviceInfo.app || apps.some((client) => client.bundleId === deviceInfo.app);
  cameraOffButton.disabled = !on;
  const cameras = (data && data.macCameras) || [];
  const shown = JSON.stringify(cameras);
  if (cameraMac.dataset.shown !== shown) {
    cameraMac.dataset.shown = shown;
    cameraMac.innerHTML = "";
    for (const mac of cameras) cameraMac.append(el("option", { value: mac.id, text: mac.name }));
    if (!cameras.length) cameraMac.append(el("option", { value: "", text: "This Mac has no camera" }));
  }
  cameraMac.disabled = cameraWebcam.disabled = !cameras.length;
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

tabHandlers.device = { show() { syncDeviceSettings(); syncCamera(); loadDeviceSettings(); } };
syncDeviceSettings();
syncCamera();
