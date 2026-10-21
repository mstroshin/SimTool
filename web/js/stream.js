// The device screen: H.264/AVCC over one long fetch, decoded with WebCodecs,
// painted on a canvas. The stream reconnects with backoff when the server goes
// away, and the page says what is happening instead of showing a frozen frame
// as "live".

const canvas = $("screenCanvas");
const canvasContext = canvas.getContext("2d", { alpha: false, desynchronized: true });
const maxCanvasDPR = 1.5;

const screenState = {
  width: 0,         // the picture's size in pixels (the stream's frame, turned as the screen reads)
  height: 0,
  points: null,     // screen size in points, once known (/config, else the AX root frame)
  display: null,    // the lit screen as /config describes it: id, rotation, points, cornerRadii
  fold: null,       // a foldable's fold as the device reports it: hingeDegrees, posture, panel, pose
  foldable: false,  // more than one screen: touches name the one shown
  rotation: 0,      // degrees the frame on the canvas is turned (the lit screen's, once frames match it)
  connection: "connecting",  // connecting | live | reconnecting | offline
  attempt: 0,
  retryAt: 0,
  changedAt: 0,     // performance.now() of the last frame that changed the picture
  stillBytes: Infinity   // the smallest frame so far: what an unchanged screen costs
};
const connectionListeners = [];
function onConnection(listener) { connectionListeners.push(listener); }

function setConnection(state, detail) {
  const changed = screenState.connection !== state;
  screenState.connection = state;
  app.dataset.conn = state;
  renderConnectionLabel();
  $("placeholder").hidden = state !== "connecting" || screenState.width > 0;
  if (detail) $("placeholder").textContent = detail;
  if (changed) for (const listener of connectionListeners) listener(state);
}

// A replay says Replay — and still says when the server is out of reach.
const CONNECTION_LABELS = { connecting: "Connecting…", live: "Live", reconnecting: "Reconnecting…", offline: "Offline" };
function renderConnectionLabel() {
  const link = CONNECTION_LABELS[screenState.connection];
  const label = app.dataset.mode === "replay" ? "Replay" + (screenState.connection === "live" ? "" : " · " + link) : link;
  $("connLabel").textContent = label;
  $("connLabel").parentElement.title = label;
  $("sbConn").textContent = label.replace(/…/g, "");
}

// ---- AVCC envelopes ----

const avccTags = { 1: "description", 2: "keyframe", 3: "delta" };
class Demuxer {
  constructor() { this.buffer = new Uint8Array(0); }
  push(bytes) {
    const merged = new Uint8Array(this.buffer.length + bytes.length);
    merged.set(this.buffer);
    merged.set(bytes, this.buffer.length);
    this.buffer = merged;
    const chunks = [];
    let offset = 0;
    while (this.buffer.length - offset >= 4) {
      const length = new DataView(this.buffer.buffer, this.buffer.byteOffset + offset, 4).getUint32(0, false);
      if (length < 1) { offset += 4; continue; }
      if (this.buffer.length - offset - 4 < length) break;
      const type = avccTags[this.buffer[offset + 4]];
      if (type) chunks.push({ type, payload: this.buffer.slice(offset + 5, offset + 4 + length) });
      offset += 4 + length;
    }
    if (offset > 0) this.buffer = this.buffer.slice(offset);
    return chunks;
  }
}

function avcCodecString(description) {
  if (description.length < 4) return "avc1.42E01E";
  const hex = (byte) => byte.toString(16).padStart(2, "0");
  return "avc1." + hex(description[1]) + hex(description[2]) + hex(description[3]);
}

// ---- Painting ----

let frameTimes = [];
let backing = { width: 0, height: 0 };

function updateBacking() {
  const rect = canvas.getBoundingClientRect();
  if (!rect.width || !screenState.width) return;
  const dpr = Math.min(window.devicePixelRatio || 1, maxCanvasDPR);
  backing = {
    width: Math.max(1, Math.min(screenState.width, Math.round(rect.width * dpr))),
    height: Math.max(1, Math.min(screenState.height, Math.round(rect.height * dpr)))
  };
}

function paint(frame) {
  // The stream carries the lit screen's framebuffer; a picture turned on it
  // (the open inner panel of an iPhone Duo) is turned back upright here.
  const rotation = frameRotation(frame.displayWidth, frame.displayHeight, screenState.display);
  const quarter = rotation % 180 !== 0;
  const width = quarter ? frame.displayHeight : frame.displayWidth, height = quarter ? frame.displayWidth : frame.displayHeight;
  if (width !== screenState.width || height !== screenState.height || rotation !== screenState.rotation) {
    screenState.width = width;
    screenState.height = height;
    screenState.rotation = rotation;
    $("placeholder").hidden = true;
    fitDevice();
    updateBacking();
  }
  if (!backing.width) updateBacking();
  if (canvas.width !== backing.width || canvas.height !== backing.height) {
    canvas.width = backing.width;
    canvas.height = backing.height;
  }
  if (rotation === 0) {
    canvasContext.drawImage(frame, 0, 0, backing.width, backing.height);
  } else {
    const turn = canvasTurn(rotation, backing.width, backing.height);
    canvasContext.setTransform(turn.a, turn.b, turn.c, turn.d, turn.e, turn.f);
    canvasContext.drawImage(frame, 0, 0, turn.width, turn.height);
    canvasContext.setTransform(1, 0, 0, 1, 0, 0);
  }
  const now = performance.now();
  frameTimes.push(now);
}

function makeFramePainter() {
  let pending = null;
  let scheduled = false;
  function draw() {
    scheduled = false;
    const frame = pending;
    pending = null;
    if (!frame) return;
    try { paint(frame); } finally { frame.close(); }
  }
  return {
    drawDecoded(frame) {
      if (pending) pending.close();
      pending = frame;
      if (!scheduled) { scheduled = true; requestAnimationFrame(draw); }
    }
  };
}

// fps as measured: frames painted in the last second. A still screen sends no
// frames, which reads "idle", not a made-up number.
setInterval(() => {
  const now = performance.now();
  frameTimes = frameTimes.filter((time) => now - time < 1000);
  const text = screenState.connection !== "live" ? "— fps" : frameTimes.length ? frameTimes.length + " fps" : "idle";
  $("readFps").textContent = text;
}, 500);

// ---- Connection loop ----

let streamAbort = null;
let retryTimer = null;
let streamGeneration = 0;   // a newer run makes an older one's errors irrelevant
const reconnectListeners = [];
function onReconnect(listener) { reconnectListeners.push(listener); }

async function runStream() {
  if (typeof VideoDecoder === "undefined") {
    setConnection("offline", "This browser cannot decode the stream (WebCodecs VideoDecoder is unavailable). Use a current Chrome or Safari.");
    $("veilTitle").textContent = "This browser cannot show the stream";
    $("veilText").textContent = "WebCodecs VideoDecoder is unavailable — open the viewer in a current Chrome or Safari.";
    $("reconnectNow").hidden = true;
    return;
  }
  clearTimeout(retryTimer);
  const generation = ++streamGeneration;
  streamAbort = new AbortController();
  const wasReconnecting = screenState.attempt > 0;
  if (!wasReconnecting) setConnection("connecting");
  let decoder = null;
  try {
    const controller = streamAbort;
    const response = await fetch("/stream.avcc", { signal: controller.signal, cache: "no-store" });
    if (!response.ok || !response.body) throw new Error("the server answered " + response.status);
    const demuxer = new Demuxer();
    screenState.stillBytes = Infinity;
    const painter = makeFramePainter();
    let timestamp = 0;
    decoder = new VideoDecoder({
      output(frame) { painter.drawDecoded(frame); },
      error(error) { setMessage("Video decoder error: " + error.message + " — reconnecting", "err"); controller.abort(); }
    });
    const reader = response.body.getReader();
    screenState.attempt = 0;
    setConnection("live");
    if (wasReconnecting) for (const listener of reconnectListeners) listener();
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value) continue;
      for (const chunk of demuxer.push(value)) {
        if (chunk.type === "description") {
          if (decoder.state === "closed") throw new Error("the decoder closed");
          decoder.configure({ codec: avcCodecString(chunk.payload), description: chunk.payload, optimizeForLatency: true, hardwareAcceleration: "prefer-hardware" });
        } else if (decoder.state === "configured") {
          screenState.stillBytes = Math.min(screenState.stillBytes, chunk.payload.byteLength);
          if (frameChangesScreen(chunk.type, chunk.payload.byteLength, screenState.stillBytes)) screenState.changedAt = performance.now();
          try {
            decoder.decode(new EncodedVideoChunk({ type: chunk.type === "keyframe" ? "key" : "delta", timestamp, data: chunk.payload }));
            timestamp += 16667;
          } catch (_) {}
        }
      }
    }
    throw new Error("the stream ended");
  } catch (error) {
    if (decoder && decoder.state !== "closed") { try { decoder.close(); } catch (_) {} }
    if (generation === streamGeneration) scheduleReconnect(error);
  }
}

function scheduleReconnect(error) {
  screenState.attempt += 1;
  const delay = Math.min(5000, 500 * Math.pow(2, screenState.attempt - 1));
  screenState.retryAt = performance.now() + delay;
  setConnection(screenState.attempt > 6 ? "offline" : "reconnecting");
  $("veilTitle").textContent = screenState.attempt > 6 ? "simtool is not answering" : "Connection to simtool lost";
  updateVeilCountdown();
  if (error && screenState.attempt === 1) setMessage("Video stream lost (" + error.message + ") — reconnecting", "err");
  retryTimer = setTimeout(runStream, delay);
}

function updateVeilCountdown() {
  if (screenState.connection !== "reconnecting" && screenState.connection !== "offline") return;
  const seconds = Math.max(0, Math.ceil((screenState.retryAt - performance.now()) / 1000));
  $("veilText").textContent = "Showing the last frame · retrying in " + seconds + " s (attempt " + screenState.attempt + ")";
}
setInterval(updateVeilCountdown, 500);

function restartStream() {
  clearTimeout(retryTimer);
  if (streamAbort) streamAbort.abort();
  runStream();
}

$("reconnectNow").addEventListener("click", restartStream);

// The page went to sleep with the tab hidden for long: a stale socket can sit
// half-open. Coming back, make sure the stream is still flowing.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && screenState.connection !== "live" && screenState.connection !== "connecting") restartStream();
});

// ---- Fitting the device into the stage ----

function fitDevice() {
  const area = $("deviceArea").getBoundingClientRect();
  const aspect = screenState.width && screenState.height ? screenState.width / screenState.height : 402 / 874;
  const maxW = Math.max(120, area.width - 64), maxH = Math.max(160, area.height - 48);
  let height = maxH, width = height * aspect;
  if (width > maxW) { width = maxW; height = width / aspect; }
  const device = $("device");
  device.style.setProperty("--dev-w", Math.floor(width) + "px");
  device.style.setProperty("--dev-h", Math.floor(height) + "px");
  // The screen's own corner radii from its device type, in proportion — the
  // Duo's cover is tight on the hinge side; else ~55 pt on a 402 pt wide phone.
  device.style.setProperty("--dev-radius", screenRadius(screenState.display, width) || Math.round(width * 0.137) + "px");
  updateBacking();
  updateReadoutSize();
  if (typeof drawRulers === "function") drawRulers();
}

function updateReadoutSize() {
  const points = screenState.points;
  if (points) $("readSize").textContent = Math.round(points.width) + " × " + Math.round(points.height) + " pt";
  else if (screenState.width) $("readSize").textContent = screenState.width + " × " + screenState.height + " px";
}

new ResizeObserver(fitDevice).observe($("deviceArea"));

// The device's screens from /config or the event stream's `device` topic: the
// lit one sets the points, the corners and how its frames turn.
function applyDisplays(displays, activeDisplay) {
  if (!Array.isArray(displays) || !displays.length) return;
  const lit = displays.find((display) => display.id === activeDisplay) || displays.find((display) => display.active) || displays[0];
  screenState.foldable = displays.length > 1;
  screenState.display = lit;
  if (lit.points && lit.points.width && lit.points.height) screenState.points = { x: 0, y: 0, width: lit.points.width, height: lit.points.height };
  touchStream.setDisplay(screenState.foldable ? lit.id : null);
  fitDevice();
  updateReadoutSize();
  if (typeof renderFold === "function") renderFold();
}

// Pointer position in points (or pixels until the point size is known).
function pointerReadout(clientX, clientY) {
  const rect = canvas.getBoundingClientRect();
  const fx = (clientX - rect.left) / rect.width, fy = (clientY - rect.top) / rect.height;
  if (fx < 0 || fy < 0 || fx > 1 || fy > 1) return "";
  if (screenState.points) return "x " + Math.round(fx * screenState.points.width) + "  y " + Math.round(fy * screenState.points.height) + " pt";
  if (screenState.width) return "x " + Math.round(fx * screenState.width) + "  y " + Math.round(fy * screenState.height) + " px";
  return "";
}
