import { el, icon } from "../kernel/dom.js";
import { panelPath } from "../kernel/address.js";

const modified = (event) => (event.button ?? 0) !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey;

export function navigationLink({ navigate, ...attrs }, ...children) {
  return el("a", { ...attrs, onclick: (event) => {
    if (modified(event)) return;
    event.preventDefault();
    navigate();
  } }, ...children);
}

// A sidebar row that opens a main panel: an ordinary link for a new tab, a
// navigation in this one. `update` follows the owner's `current` and
// `collapsed`; on the rail the label hides and the name moves to the tooltip.
// `badge` is an optional element shown after the label; `onSelect` runs when
// the row is clicked while already current, for a page that resets itself.
export function panelRow({ key, icon: glyph, label, navigate, badge = null, onSelect = null }) {
  const text = el("span", { class: "panel-row__label", text: label });
  const element = navigationLink({ class: "panel-row", href: panelPath(key), navigate: () => {
    if (element.getAttribute("aria-current") === "page" && onSelect) onSelect(); else navigate(key);
  } }, icon(glyph), text, badge);

  return {
    element,
    update({ current, collapsed } = {}) {
      if (current === key) element.setAttribute("aria-current", "page"); else element.removeAttribute("aria-current");
      if (collapsed) { element.setAttribute("aria-label", label); element.dataset.tip = label; }
      else { element.removeAttribute("aria-label"); delete element.dataset.tip; }
    },
  };
}

// The scaffold of a main panel: a scrolling page with a header (title,
// optional intro and actions) and a body the caller fills. `level` is the
// title's heading level.
export function page({ title, description, actions = [], level = 1 }) {
  const heading = el(`h${level}`, { class: "page__title", text: title });
  const intro = el("p", { class: "page__intro", text: description || "", hidden: !description });
  const body = el("div", { class: "page__body" });
  const element = el("div", { class: "page" },
    el("div", { class: "page__inner" },
      el("header", { class: "page__header" },
        el("div", { class: "page__heading" }, heading, intro),
        actions.length ? el("div", { class: "page__actions" }, actions) : null),
      body));
  return {
    element, body,
    setTitle(text) { heading.textContent = text; },
    setDescription(text) { intro.textContent = text || ""; intro.hidden = !text; },
  };
}
