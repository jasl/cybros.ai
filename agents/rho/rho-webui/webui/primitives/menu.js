import { el, safeUrl } from "../kernel/dom.js";
import { icon } from "./button.js";

const MARGIN = 8;
const GAP = 4;

// Place a top-layer popover beside its anchor: below by default, above when
// the space below is short; aligned to the anchor's start or end edge; always
// inside the viewport.
export function placePopover(node, anchor, { align = "start" } = {}) {
  const rect = anchor.getBoundingClientRect();
  const size = node.getBoundingClientRect();
  const width = Math.max(size.width, 0);
  const height = Math.max(size.height, 0);
  const viewportWidth = globalThis.innerWidth || 0;
  const viewportHeight = globalThis.innerHeight || 0;
  let left = align === "end" ? rect.right - width : rect.left;
  left = Math.max(MARGIN, Math.min(left, viewportWidth - width - MARGIN));
  let top = rect.bottom + GAP;
  if (top + height > viewportHeight - MARGIN && rect.top - GAP - height >= MARGIN) top = rect.top - GAP - height;
  top = Math.max(MARGIN, top);
  node.style.left = `${Math.round(left)}px`;
  node.style.top = `${Math.round(top)}px`;
}

function itemNode(item, close) {
  switch (item.type) {
    case "separator": return el("div", { class: "menu__separator", role: "separator" });
    case "title": return el("div", { class: "menu__title", role: "presentation", text: item.label });
    case "radio":
    case "check":
    case "link":
    case "item": {
      const checkable = item.type === "radio" || item.type === "check";
      const href = item.type === "link" ? safeUrl(item.href) : null;
      const node = el(href ? "a" : "button", { ...(href ? { href, target: "_blank", rel: "noopener noreferrer" } : { type: "button" }),
        class: `menu__item${item.danger ? " menu__item--danger" : ""}`,
        role: checkable ? `menuitem${item.type === "radio" ? "radio" : "checkbox"}` : "menuitem",
        "aria-checked": checkable ? String(!!item.checked) : undefined, disabled: !!item.disabled, tabindex: "-1",
        onclick: () => { close(); item.onSelect?.(); } },
      item.icon ? icon(item.icon) : null,
      el("span", { class: "menu__text" }, el("span", { class: "menu__label", text: item.label }),
        item.detail ? el("span", { class: "menu__detail", text: item.detail }) : null),
      checkable ? el("span", { class: "menu__check" }, icon("check")) : null,
      item.shortcut ? el("span", { class: "menu__shortcut", text: item.shortcut }) : null);
      return node;
    }
    default: throw new Error(`Unknown menu item type ${item.type}`);
  }
}

// Open a menu beside `anchor`. The popover handles light dismiss and Escape;
// focus goes back to the anchor whenever it ends up inside the menu.
export function openMenu({ anchor, items, align = "start", label, onClose }) {
  const menu = el("div", { class: "menu", role: "menu", popover: "auto", "aria-label": label });
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    try { menu.hidePopover(); } catch { /* already hidden */ }
    menu.remove();
    anchor.setAttribute("aria-expanded", "false");
    if (document.activeElement === document.body || menu.contains(document.activeElement)) anchor.focus();
    onClose?.();
  };
  let rows = items.map((item) => itemNode(item, close));
  menu.append(...rows);
  const focusable = () => rows.filter((row) => row.getAttribute("role")?.startsWith("menuitem") && !row.disabled);
  menu.addEventListener("keydown", (event) => {
    const options = focusable();
    const index = options.indexOf(document.activeElement);
    const go = (next) => { event.preventDefault(); options.at(next % options.length)?.focus(); };
    if (event.key === "ArrowDown") go(index + 1);
    else if (event.key === "ArrowUp") go(index <= 0 ? options.length - 1 : index - 1);
    else if (event.key === "Home") go(0);
    else if (event.key === "End") go(options.length - 1);
    else if (event.key === "Tab") { event.preventDefault(); close(); }
  });
  menu.addEventListener("toggle", (event) => { if (event.newState === "closed") close(); });
  document.body.append(menu);
  anchor.setAttribute("aria-expanded", "true");
  menu.showPopover();
  placePopover(menu, anchor, { align });
  focusable()[0]?.focus();
  return { close, element: menu, update(next) {
    const focused = rows.find((row) => row === document.activeElement);
    const label = focused?.querySelector(".menu__label")?.textContent;
    rows = next.map((item) => itemNode(item, close));
    menu.replaceChildren(...rows);
    if (focused) (focusable().find((row) => row.querySelector(".menu__label")?.textContent === label) || focusable()[0])?.focus();
    placePopover(menu, anchor, { align });
  } };
}

const TRIGGERS = {
  chip: (label, glyph) => el("button", { type: "button", class: "chip", "aria-haspopup": "menu", "aria-expanded": "false" },
    glyph ? icon(glyph) : null, el("span", { class: "chip__label", text: label }), icon("chevron-down")),
  icon: (label, glyph) => el("button", { type: "button", class: "btn btn--ghost btn--icon btn--sm", "aria-haspopup": "menu", "aria-expanded": "false",
    "aria-label": label, "data-tip": label }, icon(glyph || "more")),
  button: (label, glyph) => el("button", { type: "button", class: "btn btn--secondary btn--sm", "aria-haspopup": "menu", "aria-expanded": "false" },
    glyph ? icon(glyph) : null, el("span", { class: "btn__label", text: label }), icon("chevron-down")),
};

// A trigger that opens a menu built from `items()` at open time, so the rows
// always reflect the current state.
export function menuButton({ label, icon: glyph, variant = "chip", items, align = "start", ariaLabel, attrs = {} }) {
  if (!TRIGGERS[variant]) throw new Error(`Unknown menu trigger ${variant}`);
  const element = TRIGGERS[variant](label, glyph);
  for (const [name, value] of Object.entries(attrs)) element.setAttribute(name, value);
  if (ariaLabel) element.setAttribute("aria-label", ariaLabel);
  let open = null;
  element.addEventListener("click", () => {
    if (open) { open.close(); return; }
    open = openMenu({ anchor: element, items: items(), align, label: ariaLabel || label, onClose: () => { open = null; } });
  });
  return {
    element,
    update({ label: text, icon: nextGlyph } = {}) {
      if (text !== undefined) {
        const target = element.querySelector(".chip__label, .btn__label");
        if (target) target.textContent = text; else element.setAttribute("aria-label", text);
      }
      if (nextGlyph !== undefined) element.querySelector(".icon")?.setAttribute("data-icon", nextGlyph);
    },
    close() { open?.close(); },
    refresh() { open?.update(items()); },
    dispose() { open?.close(); },
  };
}
