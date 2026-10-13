import { el } from "../kernel/dom.js";
import { hueOf, initialOf } from "../kernel/format.js";
import { icon } from "./button.js";

const TONES = ["error", "warning", "info", "success"];
const TONE_ICONS = { error: "error", warning: "warning", info: "info", success: "success" };

// An inline message with a tone. Errors announce themselves; the rest are
// polite status text. `show`/`hide` keep one node in place for a form.
export function alert({ tone = "error", text = "", hidden = !text } = {}) {
  if (!TONES.includes(tone)) throw new Error(`Unknown alert tone ${tone}`);
  const glyph = icon(TONE_ICONS[tone]);
  const body = el("span", { class: "alert__text", text });
  const element = el("div", { class: `alert alert--${tone}`, role: tone === "error" ? "alert" : "status", hidden }, glyph, body);
  return {
    element,
    show(message, nextTone = tone) {
      if (!TONES.includes(nextTone)) throw new Error(`Unknown alert tone ${nextTone}`);
      element.className = `alert alert--${nextTone}`;
      element.setAttribute("role", nextTone === "error" ? "alert" : "status");
      glyph.dataset.icon = TONE_ICONS[nextTone];
      body.textContent = message; element.hidden = false;
    },
    hide() { element.hidden = true; },
  };
}

const TAG_TONES = ["neutral", "success", "info", "warning", "danger", "quiet", "outline"];
export function tag({ tone = "neutral", text }) {
  if (!TAG_TONES.includes(tone)) throw new Error(`Unknown tag tone ${tone}`);
  return el("span", { class: `tag tag--${tone}`, text });
}

// The mark of a named thing — a bot, a workspace: its initial on the colour
// its id picks; rho's own rows (`own`) keep the rho glyph.
const MARK_SIZES = ["sm", "md", "lg"];
export function namedMark({ name, id, own = false, size = "md" }) {
  if (!MARK_SIZES.includes(size)) throw new Error(`Unknown mark size ${size}`);
  const sizing = size === "md" ? "" : ` mark--${size}`;
  if (own) return el("span", { class: `mark${sizing}`, "aria-hidden": "true" }, icon("rho"));
  return el("span", { class: `mark mark--named${sizing}`, "aria-hidden": "true", style: `--hue:${hueOf(id)}`, text: initialOf(name) });
}

// A kind's mark rather than a thing's: one glyph on a quiet tile — a bot
// (no bot has a logo of its own), another agent — in the mark's sizes.
export function glyphMark({ glyph, size = "md" }) {
  if (!MARK_SIZES.includes(size)) throw new Error(`Unknown mark size ${size}`);
  const sizing = size === "md" ? "" : ` mark--${size}`;
  return el("span", { class: `mark mark--glyph${sizing}`, "aria-hidden": "true" }, icon(glyph));
}

const DOT_TONES = ["ok", "warn", "bad", "idle"];
export function stateDot({ tone = "idle", label } = {}) {
  if (!DOT_TONES.includes(tone)) throw new Error(`Unknown state ${tone}`);
  return el("span", { class: `dot dot--${tone}`, role: label ? "img" : undefined, "aria-label": label, "aria-hidden": label ? undefined : "true" });
}

export function spinner({ label, size = "sm" } = {}) {
  return el("span", { class: `spinner spinner--${size}`, role: label ? "status" : undefined, "aria-label": label, "aria-hidden": label ? undefined : "true" });
}

export function skeleton({ lines = 3, height } = {}) {
  return el("div", { class: "skeleton", "aria-hidden": "true", style: height ? `height:${height}` : undefined },
    Array.from({ length: lines }, () => el("span", { class: "skeleton__line" })));
}

// A deliberate empty state: title, optional description, optional action.
export function emptyState({ icon: glyph, title, description, action }) {
  return el("div", { class: "empty-state" }, glyph ? el("span", { class: "empty-state__icon" }, icon(glyph)) : null,
    el("p", { class: "empty-state__title", text: title }),
    description ? el("p", { class: "empty-state__description", text: description }) : null, action || null);
}
