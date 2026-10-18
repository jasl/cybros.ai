import { el } from "../kernel/dom.js";
import { icon } from "./button.js";

const TONES = ["info", "success", "error"];
const HOLD = 3000;
const FADE = 1000;
const LIMIT = 3;

// Transient notices in the top layer: at most three, the oldest leaves first.
// An error toast is announced; the others are polite.
export function createToasts({ hold = HOLD, fade = FADE } = {}) {
  const element = el("div", { class: "toasts", popover: "manual" });
  const live = new Set();
  const sync = () => {
    if (live.size && !element.isConnected) document.body.append(element);
    try { if (live.size) element.showPopover(); else element.hidePopover(); } catch { /* unchanged */ }
  };
  function remove(entry) {
    if (!live.has(entry)) return;
    live.delete(entry);
    clearTimeout(entry.timer);
    entry.node.remove();
    sync();
  }
  function toast(text, { tone = "info", action, duration = hold } = {}) {
    if (!TONES.includes(tone)) throw new Error(`Unknown toast tone ${tone}`);
    const entry = { timer: null };
    entry.node = el("div", { class: `toast toast--${tone}`, role: tone === "error" ? "alert" : "status" },
      icon(tone === "error" ? "warning" : tone === "success" ? "success" : "info"),
      el("span", { class: "toast__text", text }),
      action ? el("button", { type: "button", class: "toast__action", text: action.label, onclick: () => { remove(entry); action.onClick(); } }) : null);
    live.add(entry);
    element.append(entry.node);
    for (const old of [...live].slice(0, Math.max(0, live.size - LIMIT))) remove(old);
    sync();
    if (duration !== null) {
      entry.timer = setTimeout(() => {
        entry.node.classList.add("toast--leaving");
        entry.timer = setTimeout(() => remove(entry), fade);
      }, duration);
    }
    return () => remove(entry);
  }
  return { element, toast, dispose() { for (const entry of [...live]) remove(entry); element.remove(); } };
}
