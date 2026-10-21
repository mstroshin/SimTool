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

// Shown only for a foldable: the pose it rests at pressed, the hinge beside it,
// and the 3D preview's switch — off, with the reason, when there is none.
function renderFold() {
  $("foldGroup").hidden = !screenState.foldable;
  const view = $("view3dButton");
  view.setAttribute("aria-pressed", String(screenState.view3d));
  view.disabled = !!screenState.view3dUnavailable || app.dataset.mode === "replay";
  view.dataset.tip = screenState.view3dUnavailable ? "3D preview unavailable — " + screenState.view3dUnavailable : (screenState.view3d ? "Show the screen" : "Show the device in 3D");
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

function applyView3D(view) {
  screenState.view3dUnavailable = view && !view.available ? (view.reason || "unavailable") : "";
  if (screenState.view3dUnavailable && screenState.view3d) leave3D(screenState.view3dUnavailable);
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

// ---- Screenshots and recordings ----
// Both show the screen alone or, with the bezel option, inside the device as
// Simulator draws it; the option is this browser's. A recording runs on the
// server — it survives a reload, and every viewer shows it — and is saved
// when stopped, then downloaded by the viewer that stopped it.

const capture = {
  bezel: stored("capture.bezel", false),
  recording: null,   // the server's recording in progress: recording | saving
  last: null,        // the newest one saved
  stoppingHere: null,
  clock: null
};

function captureName(extension, at) {
  const when = at ? new Date(at) : new Date();
  const date = when.getFullYear() + "-" + pad2(when.getMonth() + 1) + "-" + pad2(when.getDate());
  const time = pad2(when.getHours()) + "." + pad2(when.getMinutes()) + "." + pad2(when.getSeconds());
  const device = (deviceInfo.name || "simulator").replace(/[^A-Za-z0-9._-]+/g, "-");
  return "simtool-" + device + "-" + date + "-" + time + "." + extension;
}

async function screenshotBlob() {
  return (await api("/api/v1/screenshot" + (capture.bezel ? "?bezel=1" : ""))).blob();
}

function saveFile(href, name) {
  el("a", { href, download: name }).click();
}

async function saveScreenshot() {
  try {
    const blob = await screenshotBlob();
    const url = URL.createObjectURL(blob);
    const name = captureName("png");
    saveFile(url, name);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    toast("Saved " + name + (capture.bezel ? " — with the bezel" : ""), { icon: "camera" });
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

function setCaptureBezel(on) {
  capture.bezel = on;
  store("capture.bezel", on);
  renderCapture();
}

function toggleRecording() {
  if (capture.recording) stopRecording();
  else startRecording();
}

async function startRecording() {
  if (capture.recording) return;
  try {
    const recording = await apiJSON("/api/v1/recording", { method: "POST", body: JSON.stringify({ bezel: capture.bezel }) });
    capture.recording = recording;
    renderCapture();
    toast("Recording the screen" + (capture.bezel ? " with the bezel" : "") + " — ⌘R stops and saves it", { icon: "record" });
  } catch (error) {
    fail("Recording did not start", error);
  }
}

async function stopRecording() {
  const recording = capture.recording;
  if (!recording || recording.state !== "recording") return;
  capture.stoppingHere = recording.id;
  capture.recording = { ...recording, state: "saving" };
  renderCapture();
  try {
    const saved = await apiJSON("/api/v1/recording/stop", { method: "POST" });
    capture.recording = null;
    capture.last = saved;
    renderCapture();
    if (saved.state === "ready") downloadRecording(saved);
    else fail("The video was not saved", { message: saved.error || "unknown error" });
  } catch (error) {
    capture.recording = null;
    renderCapture();
    fail("Stopping the recording failed", error);
  }
}

function downloadRecording(recording) {
  const name = captureName("mp4", recording.startedAt);
  saveFile("/api/v1/recording/" + encodeURIComponent(recording.id) + "/video", name);
  toast("Saved " + name + (recording.bezel ? " — with the bezel" : "") + (recording.byteCount ? " · " + formatBytes(recording.byteCount) : ""), { icon: "download" });
}

// The server's word on its recording: pushed on the event stream, read at start.
function applyRecordingTopic(payload) {
  const previous = capture.recording;
  capture.recording = payload.current || null;
  capture.last = payload.last || null;
  // Saved after a stop from another viewer: offered here too.
  const last = capture.last;
  if (previous && !capture.recording && last && last.id === previous.id && capture.stoppingHere !== last.id) {
    if (last.state === "ready") toast("Another viewer stopped the recording", { icon: "record", duration: 8000, action: { label: "Download", run: () => downloadRecording(last) } });
    else if (last.state === "failed") fail("The recording was not saved", { message: last.error || "unknown error" });
  }
  renderCapture();
}

async function loadRecording() {
  applyRecordingTopic(await apiJSON("/api/v1/recording"));
}

function renderCapture() {
  const recording = capture.recording;
  const button = $("recordButton");
  const live = recording && recording.state === "recording";
  button.classList.toggle("recording", !!live);
  button.classList.toggle("saving", !!recording && !live);
  const label = live ? "Stop recording and save the video" : recording ? "Saving the video…" : "Record video" + (capture.bezel ? " with the bezel" : "");
  button.setAttribute("aria-label", label);
  button.dataset.tip = label;
  $("screenshotButton").dataset.tip = "Save screenshot" + (capture.bezel ? " with the bezel" : "");
  $("captureMenuButton").classList.toggle("on", capture.bezel);
  $("captureMenuButton").setAttribute("aria-label", "Screenshot and video options — " + (capture.bezel ? "with the device bezel" : "the screen only"));
  clearInterval(capture.clock);
  capture.clock = null;
  const tick = () => {
    const seconds = Math.max(0, (Date.now() - Date.parse(recording.startedAt)) / 1000);
    $("recordTime").textContent = live ? formatOffset(seconds) : "Saving…";
  };
  if (recording) {
    tick();
    if (live) capture.clock = setInterval(tick, 1000);
  } else {
    $("recordTime").textContent = "";
  }
  updateDeviceButtons();
}

function captureMenuItems() {
  const usable = screenState.connection === "live" && app.dataset.mode !== "replay";
  const recording = capture.recording;
  return [
    { icon: "camera", label: "Save screenshot", kbd: "⌘S", disabled: !usable, run: saveScreenshot },
    { icon: "copy", label: "Copy screenshot", disabled: !usable, run: copyScreenshot },
    recording
      ? { icon: "stop", label: recording.state === "recording" ? "Stop recording and save the video" : "Saving the video…", kbd: "⌘R", disabled: recording.state !== "recording", run: stopRecording }
      : { icon: "record", label: "Record video", kbd: "⌘R", disabled: !usable, run: startRecording },
    capture.last && capture.last.state === "ready" ? { icon: "download", label: "Download the last video again", run: () => downloadRecording(capture.last) } : null,
    "-",
    { caption: recording ? "Screenshots and videos — this recording is " + (recording.bezel ? "with the bezel" : "the screen only") : "Screenshots and videos" },
    { label: "Screen only", radio: true, checked: !capture.bezel, run: () => setCaptureBezel(false) },
    { label: "With the device bezel", radio: true, checked: capture.bezel, run: () => setCaptureBezel(true) }
  ].filter(Boolean);
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
    { icon: "copy", label: "Copy screenshot", run: copyScreenshot },
    capture.recording ? { icon: "stop", label: "Stop recording and save the video", kbd: "⌘R", disabled: capture.recording.state !== "recording", run: stopRecording } : { icon: "record", label: "Record video", kbd: "⌘R", run: startRecording }
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

// The finger(s) as the device takes them: the canvas point itself, or in 3D
// the point of the lit panel's picture under it — null off its screen.
function deviceFingers(point, second) {
  if (!screenState.view3d) return { first: point, second: second || null };
  const map = (at) => {
    const raw = at && pointOnDuoScreen(screenState.projection, at.x, at.y);
    return raw && screenState.display ? pictureRatio(raw, screenState.display.rotation || 0) : null;
  };
  const first = map(point);
  return first ? { first, second: second ? map(second) : null } : null;
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
  const sent = deviceFingers(ending.point, ending.second) || ending.sent;
  touchStream.up(sent.first, sent.second);
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
  // In 3D a press beside the device's screen touches nothing.
  const sent = deviceFingers(point, second);
  if (!sent) return;
  touch = {
    pointerId: event.pointerId, mode, point, second, sent,
    offset: second ? { x: second.x - point.x, y: second.y - point.y } : null,
    startX: event.clientX, startY: event.clientY, held: false, holdTimer: null
  };
  touchStream.down(sent.first, sent.second);
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
  // A finger dragged off the 3D screen stays where it last touched it.
  touch.sent = deviceFingers(touch.point, touch.second) || touch.sent;
  touchStream.move(touch.sent.first, touch.sent.second);
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
  // Each wheel finger position goes to the device as the canvas maps it (3D: onto the lit panel).
  const send = (kind, at) => {
    const sent = deviceFingers(at);
    if (sent) wheel.sent = sent.first;
    if (sent || kind !== "down") touchStream[kind](wheel.sent);
  };
  if (!wheel) {
    const start = anchor();
    if (!deviceFingers(start)) return;
    wheel = { point: start, timer: null, sent: null };
    send("down", wheel.point);
  }
  let next = { x: wheel.point.x + dx, y: wheel.point.y + dy };
  const inside = (value) => value >= WHEEL_INSET / 2 && value <= 1 - WHEEL_INSET / 2;
  if (!inside(next.x) || !inside(next.y)) {
    send("up", wheel.point);
    const start = anchor();
    send("down", start);
    next = { x: clamp01(start.x + dx), y: clamp01(start.y + dy) };
  }
  wheel.point = next;
  send("move", next);
  showDots(next, null, "wheel");
  clearTimeout(wheel.timer);
  wheel.timer = setTimeout(endWheelDrag, WHEEL_IDLE_MS);
}, { passive: false });

function endWheelDrag() {
  if (!wheel) return;
  const ending = wheel;
  wheel = null;
  clearTimeout(ending.timer);
  const sent = deviceFingers(ending.point);
  touchStream.up(sent ? sent.first : ending.sent);
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

// One toolbar button for both keyboards: its menu shows or hides the software
// keyboard and connects the Mac keyboard, with a switch that says whether it is
// connected; the button itself turns course ink while it is.
function keyboardMenuItems() {
  const usable = screenState.connection === "live" && app.dataset.mode !== "replay";
  return [
    { icon: "keyboard", label: "Show or hide the software keyboard", kbd: keyboardBridge.enabled ? "⌘K" : "", disabled: !usable, run: toggleSoftwareKeyboard },
    { icon: "laptop", label: "Connect the Mac keyboard", kbd: "⇧⌘K", checked: keyboardBridge.enabled, run: () => setKeyboardMode(!keyboardBridge.enabled) }
  ];
}

function updateKeyboardIndicator() {
  const on = keyboardBridge.enabled;
  const live = on && document.hasFocus() && !isEditableTarget(document.activeElement);
  const button = $("keyboardButton");
  button.classList.toggle("on", on);
  button.setAttribute("aria-label", on ? "Keyboard — the Mac keyboard is connected" : "Keyboard");
  button.dataset.tip = on ? "The Mac keyboard types into the simulator — ⇧⌘K releases it" : "Keyboard — the software keyboard and the Mac keyboard";
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
$("view3dButton").addEventListener("click", () => setView3D(!screenState.view3d));
$("screenshotButton").addEventListener("click", saveScreenshot);
$("recordButton").addEventListener("click", toggleRecording);
wireMenuButton($("captureMenuButton"), captureMenuItems);
$("shakeButton").addEventListener("click", pressShake);
wireMenuButton($("keyboardButton"), keyboardMenuItems);
$("terminateButton").addEventListener("click", terminateApp);
$("relaunchButton").addEventListener("click", relaunchApp);
$("sbUdid").addEventListener("click", () => { if (deviceInfo.udid) copyText(deviceInfo.udid, "UDID copied"); });

// Device actions act on the live device: off while it is unreachable or a recording plays.
function updateDeviceButtons() {
  const usable = screenState.connection === "live" && app.dataset.mode !== "replay";
  for (const id of ["homeButton", "screenshotButton", "shakeButton", "terminateButton", "relaunchButton"]) $(id).disabled = !usable;
  // A recording in progress can always be stopped; one being saved cannot.
  $("recordButton").disabled = capture.recording ? capture.recording.state !== "recording" : !usable;
  renderFold();
}

onConnection((state) => {
  updateDeviceButtons();
  if (state !== "live") { endTouch(); endWheelDrag(); }
});
