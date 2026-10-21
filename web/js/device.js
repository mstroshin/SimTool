// Everything that acts on the device: the toolbar, the clipboard and Photos,
// the live finger on the screen, wheel scrolling, and the Mac keyboard.

const deviceInfo = { name: "", udid: "", app: "" };

// ---- Toolbar actions: each one confirms what it did ----

async function deviceAction(label, payload, done) {
  if (!manualInputAllowed(() => deviceAction(label, payload, done))) return;
  try {
    await postInput(payload);
    toast(done || label);
  } catch (error) {
    fail(label + " failed", error);
  }
}

function pressHome() { deviceAction("Home", { action: "button", name: "home" }, "Home"); }

// ---- A foldable's fold ----
// The server sweeps the hinge and answers once the device reports the pose,
// with where it came to rest.

let foldInFlight = false;
async function foldTo(pose) {
  if (foldInFlight || !screenState.foldable) return;
  if (!manualInputAllowed(() => foldTo(pose))) return;
  foldInFlight = true;
  renderFold();
  try {
    const result = await (await postInput({ action: "pose", name: pose })).json();
    toast(result && result.stdout ? "Folded: " + result.stdout : "Folded " + pose);
  } catch (error) {
    fail("Fold " + pose + " failed", error);
  } finally {
    foldInFlight = false;
    renderFold();
  }
}

// Shown only for a foldable: the pose it rests at pressed, the hinge beside it.
function renderFold() {
  $("foldGroup").hidden = !screenState.foldable;
  const fold = screenState.fold || {};
  for (const button of $("foldGroup").querySelectorAll("[data-pose]")) {
    button.setAttribute("aria-pressed", String(fold.pose === button.dataset.pose));
    button.disabled = foldInFlight || screenState.connection !== "live" || app.dataset.mode === "replay";
  }
  // Under the device, beside its size: how it is folded, as it reports it.
  $("readFold").hidden = !screenState.foldable;
  $("readFold").textContent = foldReadout(fold);
}

function applyFold(fold) {
  screenState.fold = fold || null;
  renderFold();
}
function pressShake() { deviceAction("Shake", { action: "shake" }, "Shake sent"); }
function toggleSoftwareKeyboard() { deviceAction("Software keyboard", { action: "software-keyboard" }, "Software keyboard toggled"); }

async function terminateApp() {
  if (!deviceInfo.app) { toast("No app attached — start the server with --app <bundle-id>", { error: true }); return; }
  deviceAction("Terminate", { action: "terminate" }, deviceInfo.app + " terminated");
}

async function relaunchApp() {
  if (!deviceInfo.app) { toast("No app attached — start the server with --app <bundle-id>", { error: true }); return; }
  deviceAction("Relaunch", { action: "launch" }, deviceInfo.app + " relaunched");
}

function screenshotName() {
  const now = new Date();
  const date = now.getFullYear() + "-" + pad2(now.getMonth() + 1) + "-" + pad2(now.getDate());
  const time = pad2(now.getHours()) + "." + pad2(now.getMinutes()) + "." + pad2(now.getSeconds());
  const device = (deviceInfo.name || "simulator").replace(/[^A-Za-z0-9._-]+/g, "-");
  return "simtool-" + device + "-" + date + "-" + time + ".png";
}

async function screenshotBlob() {
  return (await api("/api/v1/screenshot")).blob();
}

async function saveScreenshot() {
  try {
    const blob = await screenshotBlob();
    const url = URL.createObjectURL(blob);
    const name = screenshotName();
    const link = el("a", { href: url, download: name });
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    toast("Saved " + name, { icon: "camera" });
  } catch (error) {
    fail("Screenshot failed", error);
  }
}

async function copyScreenshot() {
  try {
    if (!window.ClipboardItem || !navigator.clipboard || !navigator.clipboard.write) throw new Error("this browser cannot put images on the clipboard");
    await navigator.clipboard.write([new ClipboardItem({ "image/png": screenshotBlob() })]);
    toast("Screenshot copied", { icon: "copy" });
  } catch (error) {
    fail("Copy screenshot failed", error);
  }
}

// ---- Mac clipboard → simulator ----
// The server puts the text or image on the simulator's clipboard and presses
// ⌘V there, so any text arrives intact (typing reaches only US-keyboard characters).

let pasteInFlight = false;
async function runPaste(label, send, failureHint) {
  if (pasteInFlight) return;
  if (!manualInputAllowed(() => runPaste(label, send, failureHint))) return;
  pasteInFlight = true;
  setMessage(label);
  try {
    const result = await send();
    toast(result && result.stdout ? result.stdout : "Pasted", { icon: "paste" });
  } catch (error) {
    fail("Paste failed", { message: error.message + (failureHint || "") });
  } finally {
    pasteInFlight = false;
  }
}

function pasteIntoSimulator(text) {
  if (!text) { toast("The clipboard holds no text or image", { error: true }); return; }
  runPaste("Pasting…", async () => (await postInput({ action: "paste", text })).json());
}

async function postFile(path, blob) {
  const headers = { "Content-Type": blob.type || "application/octet-stream", "X-SimTool-Source": "viewer" };
  if (blob.name) headers["X-SimTool-Filename"] = encodeURIComponent(blob.name);
  return (await api(path, { method: "POST", headers, body: blob })).json();
}

function pasteImageIntoSimulator(image) {
  runPaste("Pasting image…", () => postFile("/api/v1/input/paste-image", image), " — or add it to Photos from the screen's menu");
}

// Text when the clipboard has some, else its image; null when it holds neither.
async function readClipboard() {
  if (!navigator.clipboard.read) {
    const text = await navigator.clipboard.readText();
    return text ? { text } : null;
  }
  let image = null;
  for (const item of await navigator.clipboard.read()) {
    if (item.types.includes("text/plain")) {
      const text = await (await item.getType("text/plain")).text();
      if (text) return { text };
    }
    const imageType = item.types.find((type) => type.startsWith("image/"));
    if (imageType && !image) image = await item.getType(imageType);
  }
  return image ? { image } : null;
}

async function pasteFromClipboard() {
  if (!navigator.clipboard || !(navigator.clipboard.read || navigator.clipboard.readText)) {
    toast("This page cannot read the clipboard — press ⌘V instead", { error: true });
    return;
  }
  let content;
  try { content = await readClipboard(); } catch (_) {
    toast("Clipboard access was denied — press ⌘V instead", { error: true });
    return;
  }
  if (content && content.image) pasteImageIntoSimulator(content.image);
  else pasteIntoSimulator(content ? content.text : "");
}

// ---- Photos: the clipboard image or files from the Mac, where a photo picker offers them ----

let photosInFlight = false;
async function addToPhotos(files) {
  if (photosInFlight || !files.length) return;
  photosInFlight = true;
  try {
    for (const [index, file] of files.entries()) {
      setMessage(files.length > 1 ? "Adding to Photos… " + (index + 1) + "/" + files.length : "Adding to Photos…");
      await postFile("/api/v1/photos", file);
    }
    toast(files.length > 1 ? "Added " + files.length + " files to Photos" : "Added to Photos", { icon: "photo" });
  } catch (error) {
    fail("Add to Photos failed", error);
  } finally {
    photosInFlight = false;
  }
}

async function addClipboardImageToPhotos() {
  let image = null;
  try {
    if (navigator.clipboard && navigator.clipboard.read) {
      for (const item of await navigator.clipboard.read()) {
        const imageType = item.types.find((type) => type.startsWith("image/"));
        if (imageType) { image = await item.getType(imageType); break; }
      }
    }
  } catch (_) {
    toast("Clipboard access was denied — use Add files to Photos…", { error: true });
    return;
  }
  if (image) addToPhotos([image]);
  else toast("The clipboard holds no image — use Add files to Photos…", { error: true });
}

$("photosFile").addEventListener("change", () => {
  const files = Array.from($("photosFile").files || []);
  $("photosFile").value = "";
  addToPhotos(files);
});

function deviceMenuItems() {
  return [
    { icon: "paste", label: "Paste", kbd: "⌘V", run: pasteFromClipboard },
    { icon: "photo", label: "Add clipboard image to Photos", run: addClipboardImageToPhotos },
    { icon: "photo", label: "Add files to Photos…", run: () => $("photosFile").click() },
    "-",
    { icon: "camera", label: "Save screenshot", kbd: "⌘S", run: saveScreenshot },
    { icon: "copy", label: "Copy screenshot", run: copyScreenshot }
  ];
}

// ⌘V anywhere on the page outside an editable field pastes into the simulator;
// the paste event hands over the clipboard without a permission prompt.
document.addEventListener("paste", (event) => {
  if (isEditableTarget(event.target)) return;
  event.preventDefault();
  const data = event.clipboardData;
  const text = data ? data.getData("text/plain") : "";
  const image = data ? Array.from(data.files || []).find((file) => file.type.startsWith("image/")) : null;
  // A Finder copy of an image file brings the file name as its text; the file is what was meant.
  if (image && (!text || text === image.name)) pasteImageIntoSimulator(image);
  else pasteIntoSimulator(text);
});

// ---- The live finger ----
// Down, every move and up stream to the device as they happen; nothing waits for a reply.

const touchStream = createTouchStream({
  url: (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/api/v1/input/stream"
});
const LONG_PRESS_MS = 500;   // UIKit's long-press delay: the ring says it has passed
const HOLD_SLOP_PX = 8;      // CSS px of movement that rules a long press out
const WHEEL_IDLE_MS = 100;   // a wheel scroll lifts its finger after this much silence
const WHEEL_INSET = 0.08;    // wheel fingers stay this far inside, clear of the edge gestures
let touch = null;            // the live finger(s) under the pointer
let axPickPointer = null;    // a press in pick mode, which never touches the device
let wheel = null;            // the finger a wheel or trackpad scroll is dragging

const clamp01 = (value) => Math.min(1, Math.max(0, value));

function canvasRatio(event) {
  const rect = canvas.getBoundingClientRect();
  return { x: clamp01((event.clientX - rect.left) / rect.width), y: clamp01((event.clientY - rect.top) / rect.height) };
}

// Alt adds a second finger mirrored through the screen center, so spreading
// or circling the pointer pinches or rotates. Alt+Shift keeps the pair's
// offset instead: a two-finger pan.
function secondFinger(mode, point, offset) {
  if (mode === "pinch") return { x: clamp01(1 - point.x), y: clamp01(1 - point.y) };
  if (mode === "pan2") return { x: clamp01(point.x + offset.x), y: clamp01(point.y + offset.y) };
  return null;
}

const touchDots = [0, 1].map(() => {
  const dot = el("div", { class: "touch-dot", hidden: true });
  $("touchLayer").append(dot);
  return dot;
});

function showDots(first, second, state) {
  [first, second].forEach((point, index) => {
    const dot = touchDots[index];
    if (!point) { dot.hidden = true; return; }
    dot.hidden = false;
    dot.className = "touch-dot" + (state ? " " + state : "");
    dot.style.left = point.x * 100 + "%";
    dot.style.top = point.y * 100 + "%";
  });
}

function hideDots() { for (const dot of touchDots) dot.hidden = true; }

// Touches only go out while the screen is live: clicks on a frozen frame
// would land on whatever the device shows now.
function canTouch() {
  if (app.dataset.mode === "replay") return false;
  if (screenState.connection !== "live") {
    setMessage("Not connected — touches are not sent until the stream is back", "err");
    return false;
  }
  return screenState.width > 0;
}

function endTouch() {
  if (!touch) return;
  const ending = touch;
  touch = null;
  clearTimeout(ending.holdTimer);
  touchStream.up(ending.point, ending.second);
  hideDots();
}

canvas.addEventListener("pointerdown", (event) => {
  if (event.button !== 0) return;
  // A click that dismisses a menu must not also tap the device.
  if (closeMenu()) { event.preventDefault(); return; }
  if (keyboardBridge.enabled && isEditableTarget(document.activeElement)) document.activeElement.blur();
  if (axPickActive()) {
    try { canvas.setPointerCapture(event.pointerId); } catch (_) {}
    axPickPointer = event.pointerId;
    event.preventDefault();
    return;
  }
  if (!canTouch()) return;
  // A run or an agent is driving: the first touch asks instead of landing.
  if (!manualInputAllowed()) { event.preventDefault(); return; }
  try { canvas.setPointerCapture(event.pointerId); } catch (_) {}
  event.preventDefault();
  endWheelDrag();
  endTouch();
  const point = canvasRatio(event);
  const mode = event.altKey ? (event.shiftKey ? "pan2" : "pinch") : "one";
  const second = mode === "one" ? null : { x: clamp01(1 - point.x), y: clamp01(1 - point.y) };
  touch = {
    pointerId: event.pointerId, mode, point, second,
    offset: second ? { x: second.x - point.x, y: second.y - point.y } : null,
    startX: event.clientX, startY: event.clientY, held: false, holdTimer: null
  };
  touchStream.down(point, second);
  showDots(point, second, "");
  touch.holdTimer = setTimeout(() => {
    if (!touch) return;
    touch.held = true;
    showDots(touch.point, touch.second, "held");
  }, LONG_PRESS_MS);
});

canvas.addEventListener("pointermove", (event) => {
  $("readPointer").textContent = pointerReadout(event.clientX, event.clientY);
  if (axPickActive()) { axHoverAt(event.clientX, event.clientY); return; }
  if (!touch) {
    // With Alt held, show where the two fingers would land.
    if (event.altKey && !wheel && screenState.width) {
      const point = canvasRatio(event);
      showDots(point, event.shiftKey ? null : secondFinger("pinch", point), "preview");
    } else if (!wheel) {
      hideDots();
    }
    return;
  }
  if (event.pointerId !== touch.pointerId) return;
  touch.point = canvasRatio(event);
  touch.second = secondFinger(touch.mode, touch.point, touch.offset);
  if (touch.holdTimer && Math.hypot(event.clientX - touch.startX, event.clientY - touch.startY) > HOLD_SLOP_PX) {
    clearTimeout(touch.holdTimer);
    touch.holdTimer = null;
  }
  touchStream.move(touch.point, touch.second);
  showDots(touch.point, touch.second, touch.held ? "held" : "");
});

canvas.addEventListener("pointerup", (event) => {
  try { canvas.releasePointerCapture(event.pointerId); } catch (_) {}
  if (axPickPointer === event.pointerId) {
    axPickPointer = null;
    axPickAt(event.clientX, event.clientY);
    return;
  }
  if (!touch || event.pointerId !== touch.pointerId) return;
  // The finger lifts where the pointer is now.
  touch.point = canvasRatio(event);
  touch.second = secondFinger(touch.mode, touch.point, touch.offset);
  endTouch();
});

for (const type of ["pointercancel", "lostpointercapture"]) {
  canvas.addEventListener(type, (event) => {
    if (axPickPointer === event.pointerId) axPickPointer = null;
    if (touch && event.pointerId === touch.pointerId) endTouch();
  });
}
canvas.addEventListener("pointerleave", () => {
  $("readPointer").textContent = "";
  if (!touch && !wheel) hideDots();
  if (axPickActive()) axHoverAt(null);
});
// A finger never outlives the page's attention.
window.addEventListener("blur", () => { endTouch(); endWheelDrag(); });
document.addEventListener("visibilitychange", () => { if (document.hidden) { endTouch(); endWheelDrag(); } });

// iOS drops synthetic scroll events, so a wheel or trackpad scroll drags a
// finger instead: down under the cursor, moved by each (inverted) delta,
// put back down near the cursor when it runs into an edge, lifted after
// 100 ms of quiet. The trackpad's own momentum carries the content.
canvas.addEventListener("wheel", (event) => {
  if (!screenState.width) return;
  event.preventDefault();
  if (event.ctrlKey || touch || axPickActive() || !canTouch() || (!wheel && !manualInputAllowed())) return;
  const rect = canvas.getBoundingClientRect();
  const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? rect.height : 1;
  const dx = -event.deltaX * unit / rect.width;
  const dy = -event.deltaY * unit / rect.height;
  const anchor = () => {
    const point = canvasRatio(event);
    return { x: Math.min(1 - WHEEL_INSET, Math.max(WHEEL_INSET, point.x)), y: Math.min(1 - WHEEL_INSET, Math.max(WHEEL_INSET, point.y)) };
  };
  if (!wheel) {
    wheel = { point: anchor(), timer: null };
    touchStream.down(wheel.point);
  }
  let next = { x: wheel.point.x + dx, y: wheel.point.y + dy };
  const inside = (value) => value >= WHEEL_INSET / 2 && value <= 1 - WHEEL_INSET / 2;
  if (!inside(next.x) || !inside(next.y)) {
    touchStream.up(wheel.point);
    const start = anchor();
    touchStream.down(start);
    next = { x: clamp01(start.x + dx), y: clamp01(start.y + dy) };
  }
  wheel.point = next;
  touchStream.move(next);
  showDots(next, null, "wheel");
  clearTimeout(wheel.timer);
  wheel.timer = setTimeout(endWheelDrag, WHEEL_IDLE_MS);
}, { passive: false });

function endWheelDrag() {
  if (!wheel) return;
  const ending = wheel;
  wheel = null;
  clearTimeout(ending.timer);
  touchStream.up(ending.point);
  if (!touch) hideDots();
}

// Right-click on the screen: the element's menu while picking, the clipboard menu otherwise.
canvas.addEventListener("contextmenu", (event) => {
  event.preventDefault();
  if (axPickActive()) { axMenuAt(event.clientX, event.clientY); return; }
  openMenu(event.clientX, event.clientY, deviceMenuItems(), canvas);
});

// ---- Mac keyboard → simulator ----
// Off, the keyboard is the page's: SimTool's shortcuts and the browser's.
// On, keys go to the device, except into SimTool's own text fields, ⇧⌘K
// (which turns the mode off — Esc is a key iOS uses), ⌘K (Simulator.app's
// Toggle Software Keyboard), ⌘V (the paste event pastes the Mac clipboard
// as text), SimTool's own chords, every key while a SimTool menu, dialog or
// the palette is open, and Esc while a popover is.
const keyboardBridge = createKeyboardBridge({
  send: (message) => touchStream.key(message),
  isMac: /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent)
});
let hardwareKeyboardRequests = Promise.resolve();

const isKeyboardModeChord = (event) => event.code === "KeyK" && event.shiftKey && (event.metaKey || event.ctrlKey) && !event.altKey;
const isSoftKeyboardChord = (event) => event.code === "KeyK" && event.metaKey && !event.shiftKey && !event.ctrlKey && !event.altKey;
const isPasteChord = (event) => event.code === "KeyV" && event.metaKey && !event.ctrlKey && !event.altKey;

function modalOpen() {
  return !$("menu").hidden || !$("paletteScrim").hidden || !$("dialogScrim").hidden;
}

function popupOpen() {
  return modalOpen() || !$("popover").hidden;
}

function updateKeyboardIndicator() {
  const on = keyboardBridge.enabled;
  const live = on && document.hasFocus() && !isEditableTarget(document.activeElement);
  $("keyboardToggle").setAttribute("aria-pressed", String(on));
  app.classList.toggle("keys-on", on);
  app.classList.toggle("keys-paused", on && !live);
  $("sbKeys").textContent = !on ? "Keys → page" : live ? "Keys → device · ⇧⌘K releases" : "Keys paused · click the screen";
}

function setKeyboardMode(on) {
  if (keyboardBridge.enabled === on) return;
  keyboardBridge.setEnabled(on);
  updateKeyboardIndicator();
  // Simulator.app's Connect Hardware Keyboard goes with it, in the order the toggle flips.
  hardwareKeyboardRequests = hardwareKeyboardRequests.then(async () => {
    try {
      await postInput({ action: "hardware-keyboard", enabled: on });
    } catch (error) {
      fail("Hardware keyboard " + (on ? "connect" : "disconnect") + " failed", error);
    }
  });
}

function keepFromPage(event) { event.preventDefault(); event.stopPropagation(); }

// Capture phase: ahead of the page's own key handlers.
window.addEventListener("keydown", (event) => {
  if (isKeyboardModeChord(event)) {
    keepFromPage(event);
    if (!event.repeat) setKeyboardMode(!keyboardBridge.enabled);
    return;
  }
  if (!keyboardBridge.enabled || isEditableTarget(event.target)) return;
  if (modalOpen()) return;
  if (event.code === "Escape" && popupOpen()) return;
  if (isPasteChord(event)) return;
  if (isViewerChord(event)) return;
  if (isSoftKeyboardChord(event)) {
    keepFromPage(event);
    if (!event.repeat) toggleSoftwareKeyboard();
    return;
  }
  if (!manualInputAllowed()) { keepFromPage(event); return; }
  if (keyboardBridge.keydown(event)) keepFromPage(event);
}, true);
window.addEventListener("keyup", (event) => {
  if (event.code === "CapsLock" && isEditableTarget(event.target)) return;
  if (keyboardBridge.keyup(event)) keepFromPage(event);
}, true);
window.addEventListener("focus", updateKeyboardIndicator);
window.addEventListener("blur", () => { keyboardBridge.releaseAll(); updateKeyboardIndicator(); });
document.addEventListener("visibilitychange", () => { if (document.hidden) keyboardBridge.releaseAll(); });
document.addEventListener("focusin", (event) => {
  if (isEditableTarget(event.target)) keyboardBridge.releaseAll();
  updateKeyboardIndicator();
});
document.addEventListener("focusout", () => setTimeout(updateKeyboardIndicator, 0));

// ---- Wiring ----

$("homeButton").addEventListener("click", pressHome);
for (const button of $("foldGroup").querySelectorAll("[data-pose]")) button.addEventListener("click", () => foldTo(button.dataset.pose));
$("screenshotButton").addEventListener("click", saveScreenshot);
$("shakeButton").addEventListener("click", pressShake);
$("softKeyboardButton").addEventListener("click", toggleSoftwareKeyboard);
$("terminateButton").addEventListener("click", terminateApp);
$("relaunchButton").addEventListener("click", relaunchApp);
$("keyboardToggle").addEventListener("click", () => setKeyboardMode(!keyboardBridge.enabled));
$("sbUdid").addEventListener("click", () => { if (deviceInfo.udid) copyText(deviceInfo.udid, "UDID copied"); });

// Device actions act on the live device: off while it is unreachable or a recording plays.
function updateDeviceButtons() {
  const usable = screenState.connection === "live" && app.dataset.mode !== "replay";
  for (const id of ["homeButton", "screenshotButton", "shakeButton", "softKeyboardButton", "terminateButton", "relaunchButton"]) $(id).disabled = !usable;
  renderFold();
}

onConnection((state) => {
  updateDeviceButtons();
  if (state !== "live") { endTouch(); endWheelDrag(); }
});
