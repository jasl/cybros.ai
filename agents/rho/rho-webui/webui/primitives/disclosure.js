import { el } from "../kernel/dom.js";
import { icon } from "./button.js";

// The one-line 24px row that folds reasoning, tool calls and activity: a
// native <details> so it works before any script and with the keyboard.
export function disclosure({ title, summary, icon: glyph = "chevron-right", open = false, onToggle, tone, attrs = {} }) {
  const titleNode = el("span", { class: "disclosure__title", text: title });
  const summaryNode = el("span", { class: "disclosure__summary", text: summary || "", hidden: !summary });
  const body = el("div", { class: "disclosure__body" });
  const element = el("details", { class: `disclosure${tone ? ` disclosure--${tone}` : ""}`, open, ...attrs },
    el("summary", { class: "disclosure__row" }, el("span", { class: "disclosure__glyph" }, icon(glyph), icon("chevron-right")), titleNode, summaryNode),
    body);
  if (onToggle) element.addEventListener("toggle", () => onToggle(element.open));
  return {
    element, body,
    setTitle(text) { titleNode.textContent = text; },
    setSummary(text) { summaryNode.textContent = text || ""; summaryNode.hidden = !text; },
    setTone(next) { element.className = `disclosure${next ? ` disclosure--${next}` : ""}`; },
    get open() { return element.open; },
    set open(value) { element.open = value; },
  };
}
