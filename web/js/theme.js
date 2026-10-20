// Theme: drafting film (light) or graphite sheet (dark). The page follows the
// system's appearance until a theme is picked here; the pick is kept per
// browser. This file runs in <head>, so a pinned theme is set before anything
// is drawn and the page never flashes the other one.

const THEME_KEY = "simtool.theme";  // the key store("theme", …) writes

// "light" | "dark" from a stored value; anything else means "follow the system".
function pinnedTheme(raw) {
  try {
    const value = JSON.parse(raw);
    return value === "light" || value === "dark" ? value : null;
  } catch (_) { return null; }
}

const theme = {
  pinned: (() => { try { return pinnedTheme(localStorage.getItem(THEME_KEY)); } catch (_) { return null; } })(),
  systemDark: matchMedia("(prefers-color-scheme: dark)")
};

const systemTheme = () => (theme.systemDark.matches ? "dark" : "light");
const shownTheme = () => theme.pinned || systemTheme();

function applyTheme() {
  if (theme.pinned) document.documentElement.dataset.theme = theme.pinned;
  else delete document.documentElement.dataset.theme;
}
applyTheme();

// Everything below runs once the page is up: it uses the toolbar and core.js.

function setTheme(pinned) {
  theme.pinned = pinned;
  if (pinned) store("theme", pinned);
  else try { localStorage.removeItem(THEME_KEY); } catch (_) {}
  applyTheme();
  renderTheme();
}

function toggleTheme() {
  setTheme(themeAfterToggle(shownTheme(), systemTheme()));
}

function renderTheme() {
  const next = shownTheme() === "dark" ? "light" : "dark";
  const button = $("themeButton");
  button.setAttribute("aria-label", "Switch to the " + next + " theme");
  button.dataset.tip = "Switch to the " + next + " theme";
  button.querySelector("use").setAttribute("href", next === "light" ? "#i-sun" : "#i-moon");
  // The browser's own chrome takes the toolbar's colour.
  document.querySelector('meta[name="theme-color"]').content = getComputedStyle(document.querySelector(".toolbar")).backgroundColor;
}

// A system that changes its appearance moves an unpinned page by itself (CSS);
// the button follows. A pick made in another tab of this viewer applies here too.
theme.systemDark.addEventListener("change", () => { if (document.body) renderTheme(); });
window.addEventListener("storage", (event) => {
  if (event.key !== THEME_KEY) return;
  theme.pinned = pinnedTheme(event.newValue);
  applyTheme();
  renderTheme();
});
