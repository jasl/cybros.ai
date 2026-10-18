import { observable } from "./observable.js";

export const APPEARANCES = Object.freeze(["system", "light", "dark"]);
export const CONTENT_SIZE = Object.freeze({ min: 10, max: 22, default: 14 });
const APPEARANCE_KEY = "rho.appearance";
const SIZE_KEY = "rho.content_size";

// Appearance and content size are display preferences of this browser, not
// account state, so they live in localStorage (never a credential there).
export function createTheme({ storage = globalThis.localStorage, root = document.documentElement,
  media = globalThis.matchMedia?.("(prefers-color-scheme: dark)") } = {}) {
  const read = (key) => { try { return storage?.getItem(key); } catch { return null; } };
  const write = (key, value) => {
    try { if (value === null) storage?.removeItem(key); else storage?.setItem(key, value); } catch { /* private mode */ }
  };
  const clampSize = (value) => {
    const number = Number.parseInt(value, 10);
    if (!Number.isFinite(number)) return CONTENT_SIZE.default;
    return Math.min(CONTENT_SIZE.max, Math.max(CONTENT_SIZE.min, number));
  };

  const appearance = observable(APPEARANCES.includes(read(APPEARANCE_KEY)) ? read(APPEARANCE_KEY) : "system");
  const contentSize = observable(clampSize(read(SIZE_KEY)));

  function applyAppearance(value) {
    if (value === "system") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", value);
  }
  function applySize(value) { root.style.setProperty("--content-size", `${value}px`); }

  appearance.subscribe(applyAppearance, { immediate: true });
  contentSize.subscribe(applySize, { immediate: true });

  return {
    appearance,
    contentSize,
    setAppearance(value) {
      if (!APPEARANCES.includes(value)) throw new Error(`Unknown appearance ${value}`);
      appearance.set(value);
      write(APPEARANCE_KEY, value === "system" ? null : value);
    },
    setContentSize(value) {
      const size = clampSize(value);
      contentSize.set(size);
      write(SIZE_KEY, size === CONTENT_SIZE.default ? null : String(size));
    },
    // The theme the page is painted in right now.
    effective() {
      const chosen = appearance.get();
      if (chosen !== "system") return chosen;
      return media?.matches ? "dark" : "light";
    },
  };
}
