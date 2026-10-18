import { el } from "../kernel/dom.js";
import { placePopover } from "./menu.js";

const HOVER_DELAY = 400;

// One tooltip for the page, shown for any element with `data-tip` — after a
// short hover delay, or at once on keyboard focus — and hidden on leave,
// blur or Escape. A disabled control cannot show one (it receives no events).
export function installTooltips(root = document) {
  const node = el("div", { class: "tooltip", role: "tooltip", popover: "manual" });
  let timer = null;
  let anchor = null;
  const hide = () => {
    clearTimeout(timer); timer = null;
    if (!anchor) return;
    anchor = null;
    try { node.hidePopover(); } catch { /* already hidden */ }
  };
  const show = (target) => {
    if (anchor === target) return;
    anchor = target;
    node.textContent = target.dataset.tip;
    if (!node.isConnected) document.body.append(node);
    try { node.showPopover(); } catch { /* already shown */ }
    placePopover(node, target, { align: "start" });
  };
  const trigger = (event) => event.target?.closest?.("[data-tip]");
  const over = (event) => {
    const target = trigger(event);
    if (!target || target === anchor) return;
    clearTimeout(timer);
    timer = setTimeout(() => show(target), event.type === "focusin" ? 0 : HOVER_DELAY);
  };
  const out = (event) => { if (trigger(event)) hide(); };
  const escape = (event) => { if (event.key === "Escape") hide(); };
  const controller = new AbortController();
  const { signal } = controller;
  root.addEventListener("pointerover", over, { signal });
  root.addEventListener("focusin", over, { signal });
  root.addEventListener("pointerout", out, { signal });
  root.addEventListener("focusout", out, { signal });
  root.addEventListener("pointerdown", hide, { signal });
  root.addEventListener("keydown", escape, { signal });
  return { element: node, hide, dispose() { hide(); controller.abort(); node.remove(); } };
}
