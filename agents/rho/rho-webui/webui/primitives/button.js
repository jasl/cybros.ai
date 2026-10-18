import { el, icon } from "../kernel/dom.js";

export { icon };

const VARIANTS = ["primary", "secondary", "ghost", "danger"];
const SIZES = ["md", "sm"];

export function button({ label, variant = "secondary", size = "md", icon: glyph, type = "button", disabled = false, onClick, block = false, attrs = {} }) {
  if (!VARIANTS.includes(variant)) throw new Error(`Unknown button variant ${variant}`);
  if (!SIZES.includes(size)) throw new Error(`Unknown button size ${size}`);
  const node = el("button", { type, class: `btn btn--${variant} btn--${size}${block ? " btn--block" : ""}`, disabled, onclick: onClick, ...attrs },
    glyph ? icon(glyph) : null, el("span", { class: "btn__label", text: label }));
  return node;
}

// `label` is the accessible name and the tooltip; there is no visible text.
export function iconButton({ icon: glyph, label, size = "sm", onClick, disabled = false, type = "button", attrs = {} }) {
  if (!SIZES.includes(size)) throw new Error(`Unknown button size ${size}`);
  return el("button", { type, class: `btn btn--ghost btn--icon btn--${size}`, "aria-label": label, "data-tip": label, disabled, onclick: onClick, ...attrs },
    icon(glyph));
}
