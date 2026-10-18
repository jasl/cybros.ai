import { botsSidebar } from "./sidebar.js";
import { botsPage, PANEL } from "./page.js";

// Bots have a separate entry from Main Agent conversations. Each Bot page
// owns its current conversation, history and identity settings.
export function register(ui, shell) {
  ui.slots.register("main", { key: PANEL }, () => botsPage(shell));
  ui.slots.register("sidebar.panellist", { id: PANEL, order: 7 }, (props) => botsSidebar(ui, shell, props));
}
