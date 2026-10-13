import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { switchControl, tag } from "../../primitives/index.js";

// Known groups keep a fixed order; a group the kernel adds later lands after them.
const GROUP_ORDER = ["graph", "human", "conversation", "memory", "skill", "tools", "runners"];

// The middle segment of a canonical name (`nexus.memory.read` → `memory`).
export const toolGroup = (canonical) => canonical.split(".")[1] || canonical;

// The saved list with the switches applied. Kept names keep their saved
// order — the declaration is the front of a run's cached prefix, so an
// unchanged choice must stay byte-identical — and newly chosen ones follow
// in catalog order.
export function kernelToolSelection(saved, catalog, checked) {
  const kept = saved.filter((name) => checked.has(name));
  const added = catalog.map((row) => row.canonical_name).filter((name) => checked.has(name) && !saved.includes(name));
  return [...kept, ...added];
}

// The rows an editor shows, grouped: every catalog tool, then saved names
// the kernel no longer serves, flagged. Without a catalog only the saved
// names are rows.
export function kernelToolRows(saved, catalog) {
  const served = new Set((catalog || []).map((row) => row.canonical_name));
  const unlisted = saved.filter((name) => !served.has(name)).map((name) => ({ canonical_name: name, name: null, description: "", unavailable: !!catalog }));
  const groups = new Map();
  for (const row of [...(catalog || []), ...unlisted]) {
    const group = toolGroup(row.canonical_name);
    if (!groups.has(group)) groups.set(group, []);
    groups.get(group).push(row);
  }
  const rank = (group) => { const index = GROUP_ORDER.indexOf(group); return index === -1 ? GROUP_ORDER.length : index; };
  return [...groups.entries()].sort(([left], [right]) => rank(left) - rank(right)).map(([group, tools]) => ({ group, tools }));
}

// The first sentence of the kernel's own description, for a tool the page
// has no copy of yet.
export const firstSentence = (text) => (text || "").split(/(?<=[.!?])\s/)[0].trim();

// A list of switches over the kernel's tool catalog. `set` paints the saved
// names against a catalog (or without one); `read` is the list to save.
export function kernelToolsControl({ onChange }) {
  const notice = el("p", { class: "field__hint", hidden: true });
  const groups = el("div", { class: "toolset__groups" });
  const element = el("div", { class: "toolset", role: "group", "aria-label": t("settings_editor.nexus_tools") }, notice, groups);
  let saved = [];
  let catalog = null;
  let checked = new Set();

  function row(tool) {
    const name = tool.canonical_name;
    const label = t(`kernel_tools.${name}.label`, {}, tool.name || name);
    const description = tool.unavailable ? t("settings_editor.tool_not_served")
      : t(`kernel_tools.${name}.description`, {}, firstSentence(tool.description));
    const control = switchControl({ label: "", checked: checked.has(name), attrs: { name: "kernel_tools", value: name, "aria-label": label },
      onChange: (event) => { if (event.target.checked) checked.add(name); else checked.delete(name); onChange?.(); } });
    return el("div", { class: "settings-row toolset__row", "data-tool": name },
      el("div", { class: "settings-row__text" },
        el("p", { class: "settings-row__label" }, el("span", { text: label }),
          tool.unavailable ? tag({ tone: "warning", text: t("settings_editor.not_served") }) : tool.name ? tag({ tone: "outline", text: tool.name }) : null),
        description ? el("p", { class: "settings-row__description", text: description }) : null),
      control.element);
  }

  function paint() {
    notice.textContent = catalog ? "" : t("settings_editor.tool_catalog_unavailable");
    notice.hidden = !!catalog;
    groups.replaceChildren(...kernelToolRows(saved, catalog).map(({ group, tools }) => el("section", { class: "toolset__group" },
      el("h4", { class: "toolset__title", text: t(`kernel_tools.group.${group}`, {}, group) }), ...tools.map(row))));
  }

  paint();
  return {
    element,
    set({ saved: names, catalog: rows }) { saved = names || []; catalog = rows; checked = new Set(saved); paint(); },
    // A catalog that arrives mid-edit repaints the rows around the switches as they are.
    catalog(rows) { if (rows !== catalog) { catalog = rows; paint(); } },
    read() { return kernelToolSelection(saved, catalog || [], checked); },
  };
}
