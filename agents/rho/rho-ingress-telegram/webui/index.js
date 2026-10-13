import english from "./locales/en.js";
import { telegramConnections } from "./connections.js";
import { telegramSetup } from "./setup.js";

// Connections own credentials and transport. Each Bot contributes only its
// fixed destination and message policy to the Core Bot page.
export function register(ui) {
  const t = ui.translator({ en: english });
  ui.slots.register("settings.section", { key: "connections", order: 18, label: () => t("connections.title") },
    (props) => telegramConnections(ui, t, props));
  ui.slots.register("plugins.item.config", { key: "rho.ingress_telegram" }, (props) => telegramConnections(ui, t, props));
  ui.slots.register("bots.item.config", { id: "telegram", order: 10 }, (props) => telegramSetup(ui, t, props, { agent: props.bot }));
}
