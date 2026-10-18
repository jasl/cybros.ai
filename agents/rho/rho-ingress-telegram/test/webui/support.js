import { createSlots } from "../../../rho-webui/webui/kernel/slots.js";
import { keyedOutlet, listOutlet } from "../../../rho-webui/webui/kernel/outlets.js";
import { createHandle } from "../../../rho-webui/webui/kernel/handle.js";
import { translator } from "../../../rho-webui/webui/kernel/i18n.js";
import { el } from "../../../rho-webui/webui/kernel/dom.js";
import { primitives } from "../../../rho-webui/webui/primitives/index.js";
import { register } from "../../webui/index.js";

export const ID = "rho.ingress_telegram";
export const BOT = { public_id: "bot-a", name: "alpha", display_name: "Alpha" };
export const CONNECTION = { public_id: "connection-a", name: "Shared account", enabled: true, token: { present: true },
  bot: { id: 7, username: "shared_bot" }, connection: "running", offset: 12, bot_count: 2 };
export const telegram = (overrides = {}) => ({ agent_public_id: BOT.public_id, owner_only: true, enabled: true, plugin_enabled: true,
  connection_public_id: CONNECTION.public_id, connection: "running", bot: CONNECTION.bot,
  configuration: { enabled: true, connection_public_id: CONNECTION.public_id, target: { chat_id: "42", topic_id: null },
    owner_id: "42", stale_after: 600, input_debounce_seconds: 2, transcription_model: "", speech_model: "" }, access: null, ...overrides });
export const field = (container, name) => container.querySelector(`[name="${name}"]`);
export const button = (container, label) => container.querySelectorAll("button").find((node) => node.textContent === label || node.getAttribute("aria-label") === label);
export const deferred = () => { let resolve; const promise = new Promise((done) => { resolve = done; }); return { promise, resolve }; };
export const shown = (node) => node.nodeType === 3 ? node.data : node.hidden ? "" : node.childNodes.map(shown).join("\n");

export function mount({ routes = {}, bot = BOT, connections = false, plugin = false } = {}) {
  const slots = createSlots(); const requests = []; const toasts = []; let refreshes = 0; let inventoryRefreshes = 0;
  const answers = {
    "/telegram/connections": () => ({ connections: [CONNECTION] }),
    "/telegram/connection": ({ body }) => ({ connection: body ? { ...CONNECTION, ...body, token: { present: body.token !== null } } : CONNECTION, saved: true, applied: true }),
    "/telegram": () => telegram({ agent_public_id: bot.public_id }),
    "/telegram/configuration": () => ({ saved: true, applied: true }),
    "/models": () => ({ models: [] }), ...routes,
  };
  const handle = createHandle({ id: ID, slots, el, primitives, translator,
    call: async (path, { method = "GET", body, signal } = {}) => {
      requests.push({ path, method, body, signal });
      if (signal?.aborted) throw Object.assign(new Error("Aborted"), { name: "AbortError" });
      const handler = answers[path] || answers[path.split("?")[0]];
      if (!handler) throw new Error(`Unexpected request: ${path}`);
      return handler({ body, signal, query: new URLSearchParams(path.split("?")[1]) });
    }, toast: (text, options) => toasts.push([text, options?.tone]), navigate() {}, dock: { open() {} }, inventory: { refresh: async () => { inventoryRefreshes += 1; } } });
  register(handle.ui);
  const container = el("div"); document.body.append(container);
  const props = { bot, visible: true, refresh: async () => { refreshes += 1; } };
  let outlet;
  if (connections) {
    outlet = keyedOutlet(slots, plugin ? "plugins.item.config" : "settings.section", container);
    outlet.show(plugin ? ID : "connections", props);
  } else outlet = listOutlet(slots, "bots.item.config", container, props);
  return { container, slots, handle, outlet, props, requests, routes: answers, toasts, refreshes: () => refreshes, inventoryRefreshes: () => inventoryRefreshes,
    writes: () => requests.filter((row) => row.method !== "GET") };
}
