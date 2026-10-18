import { el } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";
import { segmented, switchControl } from "./field.js";
import { tag } from "./feedback.js";

// Group the owning catalog's tools by source, followed by selected names
// rho no longer serves so the user can release those selections.
export function toolRows(choices, given) {
  const served = new Set(choices.map((row) => row.name));
  const gone = (given || []).filter((name) => !served.has(name)).map((name) => ({ name, kind: "gone" }));
  const kinds = ["kernel", "agent", "runner", "gone"];
  return kinds.map((kind) => ({ kind, tools: [...choices, ...gone].filter((row) => row.kind === kind) })).filter((group) => group.tools.length);
}

// Select the whole catalog or explicit names. A saved selection that names
// a tool rho no longer serves keeps that name under its own heading.
export function toolPicker({ choices, given, name = "tools", label = t("agents.tools_label"), allLabel = t("agents.tools_all"), onChange = () => {} }) {
  let mode = given === null ? "all" : "some";
  let changed = false;
  const checked = new Set(given || []);
  const groups = el("div", { class: "toolset__groups" });
  const list = el("div", { class: "toolset", role: "group", "aria-label": label }, groups);
  const empty = el("p", { class: "field__hint", text: t("agents.tools_none_served"), hidden: true });
  const choice = segmented({ name: `${name}_mode`, label, value: mode,
    options: [{ value: "all", label: allLabel }, { value: "some", label: t("agents.tools_some") }],
    onChange: (next) => { changed = true; mode = next; paint(); onChange(); } });
  const element = el("div", { class: "stack stack--tight" }, choice.element, list, empty);

  function row(tool) {
    const control = switchControl({ label: "", checked: checked.has(tool.name), attrs: { name, value: tool.name, "aria-label": tool.name },
      onChange: (event) => { changed = true; if (event.target.checked) checked.add(tool.name); else checked.delete(tool.name); onChange(); } });
    return el("div", { class: "settings-row toolset__row", "data-tool": tool.name },
      el("div", { class: "settings-row__text" },
        el("p", { class: "settings-row__label" }, el("span", { class: "bots-tool__name", text: tool.name }),
          tool.kind === "gone" ? tag({ tone: "warning", text: t("agents.tool_gone") }) : null),
        tool.description ? el("p", { class: "settings-row__description", text: tool.description }) : null),
      control.element);
  }

  const headings = { kernel: () => t("agents.tools_kernel"), agent: () => t("agents.tools_agent"), runner: () => t("agents.tools_runner"), gone: () => t("agents.tools_gone") };
  function paint() {
    list.hidden = mode !== "some";
    empty.hidden = mode !== "some" || choices.length > 0;
    groups.replaceChildren(...toolRows(choices, [...checked]).map((group) =>
      el("section", { class: "toolset__group" }, el("h4", { class: "toolset__title", text: headings[group.kind]() }), ...group.tools.map(row))));
  }
  paint();
  return {
    element,
    read: () => (mode === "all" ? null : choices.map((row) => row.name).concat([...checked].filter((name) => !choices.some((row) => row.name === name))).filter((name) => checked.has(name))),
    changed: () => changed,
    update(next) { choices = next; paint(); },
  };
}
