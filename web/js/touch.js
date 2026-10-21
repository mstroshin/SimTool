// Live touch: one WebSocket carries the viewer's finger — and its keys —
// to the device. Moves coalesce to one per animation frame; downs, ups and
// keys are never dropped, and a move still waiting goes out first.
// While the socket reconnects, the newest 32 messages of the last 1.5 s
// wait for it — older ones would replay a gesture the user has finished.
function createTouchStream(options) {
  const makeSocket = options.makeSocket || ((url) => new WebSocket(url));
  const now = options.now || (() => performance.now());
  const nextFrame = options.nextFrame || ((fn) => requestAnimationFrame(fn));
  const later = options.later || ((fn, ms) => setTimeout(fn, ms));
  const maxQueued = 32;
  const maxAgeMs = 1500;
  let socket = null;
  let open = false;
  let queue = [];
  let pendingMove = null;
  let frameScheduled = false;
  let retryMs = 250;
  let closed = false;
  let display = null;   // the screen shown, on a device with several

  function connect() {
    if (closed) return;
    const next = makeSocket(options.url);
    socket = next;
    next.onopen = () => {
      if (socket !== next) return;
      open = true;
      retryMs = 250;
      const at = now();
      for (const item of queue) if (at - item.at <= maxAgeMs) next.send(item.text);
      queue = [];
    };
    next.onclose = () => {
      if (socket !== next) return;
      open = false;
      socket = null;
      if (closed) return;
      later(connect, retryMs);
      retryMs = Math.min(2000, retryMs * 2);
    };
    next.onerror = () => {}; // onclose follows and reconnects
  }

  function send(message) {
    const text = JSON.stringify(message);
    if (open && socket) { socket.send(text); return; }
    const at = now();
    queue.push({ text, at });
    queue = queue.filter((item) => at - item.at <= maxAgeMs).slice(-maxQueued);
  }

  const round = (v) => Math.round(Math.min(1, Math.max(0, v)) * 100000) / 100000;
  function message(t, first, second) {
    const m = { t, x: round(first.x), y: round(first.y) };
    if (second) { m.x2 = round(second.x); m.y2 = round(second.y); }
    if (display) m.d = display;
    return m;
  }

  function flushMove() {
    if (!pendingMove) return;
    const m = pendingMove;
    pendingMove = null;
    send(m);
  }

  connect();
  return {
    down(first, second) { flushMove(); send(message("down", first, second)); },
    move(first, second) {
      pendingMove = message("move", first, second);
      if (frameScheduled) return;
      frameScheduled = true;
      nextFrame(() => { frameScheduled = false; flushMove(); });
    },
    up(first, second) { flushMove(); send(message("up", first, second)); },
    key(message) { flushMove(); send(message); },
    // A foldable's viewer names the panel it shows; touches go there.
    setDisplay(id) { display = id || null; },
    get connected() { return open; },
    close() { closed = true; if (socket) socket.close(); }
  };
}
