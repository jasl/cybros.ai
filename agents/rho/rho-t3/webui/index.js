import english from "./locales/en.js";
import { t3Page, t3Row } from "./page.js";
import { t3Settings } from "./settings.js";

// While T3 runs it has a sidebar entry and a page of its own, and the same
// settings body replaces the generic form on its Plugins page. The plugin
// switch owns enablement, so nothing here enables or disables the plugin.
export function register(ui) {
  const t = ui.translator({ en: english });
  ui.slots.register("sidebar.panellist", { id: "t3", order: 30 }, (props) => t3Row(ui, t, props));
  ui.slots.register("main", { key: "t3" }, (props) => t3Page(ui, t, props));
  ui.slots.register("plugins.item.config", { key: ui.id }, () => t3Settings(ui, t));
}
