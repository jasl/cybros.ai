import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { createInventory } from "../webui/shell/inventory.js";
import { createModules } from "../webui/kernel/modules.js";
import { createSlots } from "../webui/kernel/slots.js";
import { createHandle } from "../webui/kernel/handle.js";
import { translator } from "../webui/kernel/i18n.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const plugin = (id, webui = null, extra = {}) => ({ id, name: id, description: "", enabled: true, active: true,
  readiness: { ready: true, issues: [] }, capabilities: { tools: [], commands: [], webui }, ...extra });

function harness(answers) {
  const slots = createSlots();
  const imported = [];
  const modules = createModules({
    makeHandle: (id) => createHandle({ id, slots, call: async () => ({}), toast() {}, navigate() {}, dock: {}, primitives: {}, el() {}, translator }),
    importer: async (url) => { imported.push(url); if (url.includes("broken")) throw new Error("404"); return { register() {} }; },
  });
  const toasts = [];
  const opened = [];
  const controller = new AbortController();
  let calls = 0;
  const inventory = createInventory({ signal: controller.signal, modules, toast: (text, options) => toasts.push([text, options]), openPlugin: (id) => opened.push(id),
    call: async () => { calls += 1; return typeof answers === "function" ? answers(calls) : answers; } });
  return { inventory, modules, imported, toasts, opened, controller, calls: () => calls };
}

test("refresh loads the inventory and syncs running modules from capabilities.webui", async () => {
  const { inventory, modules, imported } = harness({ plugins: [plugin("rho.webui"), plugin("rho.ingress_telegram", "/modules/rho.ingress_telegram/abc/index.js")], failures: [] });
  await inventory.refresh();
  expect(inventory.state.get()).toMatchObject({ loading: false, loaded: true, failures: [] });
  expect(imported).toEqual(["/modules/rho.ingress_telegram/abc/index.js"]);
  expect([...modules.state.get().values()].map((row) => [row.id, row.status])).toEqual([["rho.ingress_telegram", "ready"]]);
  expect(inventory.plugin("rho.webui").id).toBe("rho.webui");
});

test("a mutation answer replaces its row in place and unloads a module whose plugin stopped", async () => {
  const { inventory, modules } = harness({ plugins: [plugin("rho.ingress_telegram", "/modules/rho.ingress_telegram/abc/index.js")], failures: [] });
  await inventory.refresh();
  await inventory.accept({ plugin: plugin("rho.ingress_telegram", null, { enabled: false, active: false }) });
  expect(inventory.state.get().plugins[0].enabled).toBe(false);
  expect(modules.state.get().size).toBe(0);
});

test("a failed module is announced once with a way to its plugin, and errors keep the last inventory", async () => {
  const { inventory, toasts, opened } = harness((count) => {
    if (count === 2) throw new Error("offline");
    return { plugins: [plugin("broken.plugin", "/modules/broken.plugin/abc/index.js")], failures: [] };
  });
  await inventory.refresh();
  await inventory.refresh();
  expect(toasts).toHaveLength(1);
  expect(toasts[0][0]).toContain("broken.plugin");
  toasts[0][1].action.onClick();
  expect(opened).toEqual(["broken.plugin"]);
  expect(inventory.state.get().error.message).toBe("offline");
  expect(inventory.state.get().plugins).toHaveLength(1);
});

test("focus refreshes at most once per second and concurrent refreshes share one request", async () => {
  const { inventory, calls } = harness({ plugins: [], failures: [] });
  inventory.watchFocus();
  const first = inventory.refresh();
  const second = inventory.refresh();
  expect(second).toBe(first);
  await first;
  window.dispatchEvent(new Event("focus"));
  window.dispatchEvent(new Event("focus"));
  await flush();
  expect(calls()).toBe(2);
});
