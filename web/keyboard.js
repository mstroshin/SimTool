// Mac keyboard → simulator. While on, keys reach the device as a hardware
// keyboard's, by physical key (KeyboardEvent.code): the device's own
// layout picks the character, as in Simulator.app. The device repeats a
// held key itself, so the browser's repeats are dropped. Every key sent
// down goes up again — on release, when the mode goes off, or when the page
// loses the keyboard — and a modifier pressed while the page did not have
// the keyboard catches up with the next key.
function createKeyboardBridge(options) {
  const send = options.send;
  const isMac = !!options.isMac;
  const modifiers = [
    ["shiftKey", "ShiftLeft", "ShiftRight"],
    ["ctrlKey", "ControlLeft", "ControlRight"],
    ["altKey", "AltLeft", "AltRight"],
    ["metaKey", "MetaLeft", "MetaRight"]
  ];
  const isModifier = (code) => modifiers.some(([, left, right]) => code === left || code === right);
  const held = [];
  let enabled = false;

  function down(code) { held.push(code); send({ t: "keydown", code }); }
  function up(code) { held.splice(held.indexOf(code), 1); send({ t: "keyup", code }); }
  function press(code) { send({ t: "keydown", code }); send({ t: "keyup", code }); }
  function releaseAll() { while (held.length) up(held[held.length - 1]); }

  function syncModifiers(event) {
    for (const [flag, left, right] of modifiers) {
      if (event.code === left || event.code === right) continue;
      const pressed = held.filter((code) => code === left || code === right);
      if (event[flag] && !pressed.length) down(left);
      if (!event[flag]) pressed.forEach(up);
    }
  }

  return {
    get enabled() { return enabled; },
    setEnabled(on) { if (!on) releaseAll(); enabled = !!on; },
    // Each returns whether the key went to the device; the page then keeps it to itself.
    keydown(event) {
      const code = event.code;
      if (!enabled || !code || code === "Unidentified") return false;
      // Mac browsers report Caps Lock turning on and off rather than the key: each event is a press.
      if (code === "CapsLock") { press(code); return true; }
      if (event.repeat || held.includes(code)) return true;
      syncModifiers(event);
      // macOS reports no keyup for a key released while ⌘ is down, so under ⌘ a key is a press.
      if (isMac && event.metaKey && !isModifier(code)) { press(code); return true; }
      down(code);
      return true;
    },
    keyup(event) {
      const code = event.code;
      if (code === "CapsLock") { if (enabled && isMac) press(code); return enabled; }
      if (!held.includes(code)) return false;
      up(code);
      return true;
    },
    releaseAll
  };
}
