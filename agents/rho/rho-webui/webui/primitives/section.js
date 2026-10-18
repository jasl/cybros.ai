import { el, safeUrl } from "../kernel/dom.js";
import { iconButton } from "./button.js";

// A settings card: title, optional description and actions, then a body the
// caller fills.
export function section({ title, description, actions = [], level = 2 }) {
  const body = el("div", { class: "card__body" });
  const element = el("section", { class: "card" },
    el("div", { class: "card__head" },
      el("div", { class: "card__heading" }, el(`h${level}`, { class: "card__title", text: title }),
        description ? el("p", { class: "card__description", text: description }) : null),
      actions.length ? el("div", { class: "card__actions" }, actions) : null),
    body);
  return { element, body };
}

// A group of a page: a heading with the count of what it holds and the
// actions that act on the group — creating into it, importing into it —
// at the heading's end, then a body the caller fills. Every page lists
// its things in these, so an action always sits on the group it serves.
export function group({ title, actions = [], level = 2, attrs = {} }) {
  const count = el("span", { class: "group__count" });
  const body = el("div", { class: "group__body" });
  const element = el("section", { class: "group", ...attrs },
    el("div", { class: "group__head" },
      el(`h${level}`, { class: "group__title" }, el("span", { text: title }), count),
      actions.length ? el("div", { class: "group__actions" }, actions) : null),
    body);
  return { element, body, setCount(value) { count.textContent = value === null || value === undefined ? "" : String(value); } };
}

// A purpose-named group of fields inside one form: a legend, an optional
// line under it, then the fields. For a form whose one Save covers more
// than one purpose; a purpose with a Save of its own is a `section`.
export function formGroup({ title, description, attrs = {} }) {
  const element = el("fieldset", { class: "form-group", ...attrs },
    el("legend", { class: "form-group__title", text: title }),
    description ? el("p", { class: "form-group__description", text: description }) : null);
  return { element, append: (...nodes) => { element.append(...nodes); return element; } };
}

// Rows with a label, optional detail and one trailing action. `update(rows)`
// repaints the list in place.
export function list({ rows = [], empty } = {}) {
  const container = el("ul", { class: "rows" });
  const emptyNode = el("p", { class: "rows__empty text-tertiary", text: empty || "", hidden: !empty });
  const element = el("div", { class: "rows__frame" }, container, emptyNode);
  function paint(next) {
    container.replaceChildren(...next.map((row) => el("li", { class: "rows__row", "data-key": row.key },
      el("span", { class: "rows__text" }, el("span", { class: `rows__label${row.mono ? " mono" : ""}`, text: row.label }),
        row.detail ? el("span", { class: "rows__detail", text: row.detail }) : null),
      row.action ? iconButton({ icon: row.action.icon || "close", label: row.action.ariaLabel || row.action.label, onClick: row.action.onClick }) : null)));
    emptyNode.hidden = next.length > 0 || !empty;
  }
  paint(rows);
  return { element, update: paint };
}

// External links open in a new tab and only when the address is a web URL;
// anything else renders as plain text so a document cannot smuggle a scheme.
export function link({ href, text, external = true }) {
  const url = safeUrl(href);
  if (!url) return el("span", { text });
  return el("a", { class: "link", href: url, text, ...(external ? { target: "_blank", rel: "noopener noreferrer" } : {}) });
}
