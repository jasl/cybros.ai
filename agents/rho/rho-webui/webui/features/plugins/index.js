import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { panelRow, stateDot } from "../../primitives/index.js";
import { pluginsPage } from "./page.js";
import { createSwitching } from "./switching.js";

// A running plugin that reports it still needs setup.
const needsSetup = (plugins) => plugins.some((row) => row.enabled && row.active && row.readiness && !row.readiness.ready);

// The sidebar row that opens the Plugins page; from the page's own detail it
// returns to the list.
function navRow(ui, shell, initialProps) {
  const note = el("span", { class: "sr-only" });
  const badge = el("span", { class: "panel-row__badge", hidden: true }, stateDot({ tone: "warn" }), note);
  const row = panelRow({ key: "plugins", icon: "plugins", label: t("common.plugins"), navigate: ui.navigate, badge,
    onSelect: () => shell.router.push({ plugin: null }, { notify: true }) });

  function paint() {
    const attention = needsSetup(shell.inventory.state.get().plugins);
    badge.hidden = !attention;
    note.textContent = attention ? t("plugin_page.needs_setup") : "";
  }

  const stop = shell.inventory.state.subscribe(paint);
  row.update(initialProps);
  paint();
  return { element: row.element, update(next) { row.update(next); paint(); }, dispose: stop };
}

export function register(ui, shell) {
  const switching = createSwitching(shell);
  ui.slots.register("main", { key: "plugins" }, () => pluginsPage(shell, switching));
  ui.slots.register("sidebar.panellist", { id: "plugins", order: 10 }, (props) => navRow(ui, shell, props));
}
