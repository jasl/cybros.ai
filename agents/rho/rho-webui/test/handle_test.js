import { test, expect } from "bun:test";
import { createSlots } from "../webui/kernel/slots.js";
import { createHandle } from "../webui/kernel/handle.js";
import { translator } from "../webui/kernel/i18n.js";
import { el } from "../webui/kernel/dom.js";

const component = () => ({ element: { nodeType: 1 } });

function handle(overrides = {}) {
  const slots = createSlots();
  const calls = [];
  const refreshes = [];
  const built = createHandle({ id: "rho.ingress_telegram", slots, translator, el, primitives: { button: () => {} },
    call: async (path, options) => { calls.push([path, options]); return { ok: true }; },
    toast: () => {}, navigate: () => {}, dock: { open: () => {} }, inventory: { refresh: () => refreshes.push(1) }, ...overrides });
  return { ...built, slots, calls, refreshes };
}

test("the handle exposes exactly the module platform and is frozen", () => {
  const { ui, refreshes } = handle();
  expect(Object.keys(ui).sort()).toEqual(["call", "dock", "el", "id", "inventory", "isTerminal", "navigate", "primitives", "signal", "slots", "toast", "translator", "uuidv7"]);
  expect(Object.isFrozen(ui)).toBe(true);
  expect(ui.id).toBe("rho.ingress_telegram");
  expect(ui.signal.aborted).toBe(false);
  ui.inventory.refresh();
  expect(refreshes).toEqual([1]);
});

test("registrations through the handle carry the module id and die with the handle", () => {
  const { ui, slots, dispose } = handle();
  const remove = ui.slots.register("plugins.item.config", { key: "rho.ingress_telegram" }, component);
  expect(slots.winner("plugins.item.config", "rho.ingress_telegram").owner).toBe("rho.ingress_telegram");
  ui.slots.register("conversation.header.utilities", { id: "telegram" }, component);
  remove();
  expect(slots.winner("plugins.item.config", "rho.ingress_telegram")).toBeNull();
  dispose();
  expect(slots.entries("conversation.header.utilities")).toEqual([]);
  expect(ui.signal.aborted).toBe(true);
});

test("requests default to the handle's signal and keep an explicit one", async () => {
  const { ui, calls } = handle();
  await ui.call("/telegram");
  const own = new AbortController();
  await ui.call("/telegram/access", { method: "POST", body: { list: "allowed_users" }, signal: own.signal, conversation: "c-1" });
  expect(calls[0]).toEqual(["/telegram", { signal: ui.signal }]);
  expect(calls[1]).toEqual(["/telegram/access", { method: "POST", body: { list: "allowed_users" }, signal: own.signal, conversation: "c-1" }]);
});

test("a module translator resolves its own catalog with the shell's brand and never shell keys", () => {
  const { ui } = handle();
  const t = ui.translator({ en: { "setup.title": "Connect {rho} to Telegram", "access.unavailable": "After {nexus} connects" } });
  expect(t("setup.title")).toBe("Connect rho to Telegram");
  expect(t("access.unavailable")).toBe("After Nexus connects");
  expect(() => t("common.close")).toThrow("Missing translation: common.close");
  expect(t("common.close", {}, "fallback")).toBe("fallback");
  expect(() => ui.translator({})).toThrow("needs an `en` entry");
});
