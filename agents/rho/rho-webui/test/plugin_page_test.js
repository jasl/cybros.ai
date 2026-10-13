import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, type, flush } from "./support/dom.js";
import { el } from "../webui/kernel/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { createSlots } from "../webui/kernel/slots.js";
import { listOutlet } from "../webui/kernel/outlets.js";
import { register } from "../webui/features/plugins/index.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const settle = async () => { for (let index = 0; index < 20; index += 1) await Promise.resolve(); await flush(); };
const schema = { type: "object", properties: { port: { type: "integer", default: 3773 } } };
const plugin = (id, fields = {}) => ({ id, name: id[0].toUpperCase() + id.slice(1), description: `${id} plugin`, enabled: true, active: true,
  configurable: true, restart_required: false, requires: [], category: "tools", source: { kind: "installed", name: id, version: "1.0" }, version: "1.0",
  readiness: { ready: true, issues: [] }, capabilities: { tools: [], commands: [], webui: null, page: false },
  configuration: { schema, overrides: {}, value: { port: 3773 }, diagnostics: [], secrets: [] }, ...fields });

function pages(plugins, { answers = {}, loaded = true, address = {} } = {}) {
  const inventory = observable({ plugins, failures: [], loading: false, error: null, loaded });
  const requests = [];
  const toasts = [];
  const navigated = [];
  let location = { panel: "plugins", plugin: null, ...address };
  const listeners = new Set();
  const router = {
    read: () => ({ ...location }),
    push(changes, { notify = false } = {}) { location = { ...location, ...changes }; if (notify) for (const listener of [...listeners]) listener({ ...location }); },
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
  };
  const shell = {
    slots: createSlots(), signal: new AbortController().signal, router, renderError: (error) => { throw error; },
    toast: (text, options) => toasts.push([text, options?.tone]),
    modules: { state: observable(new Map()) },
    call: async (path, options = {}) => {
      requests.push([path, options.method || "GET", options.body]);
      const handler = answers[`${options.method || "GET"} ${path}`];
      if (!handler) throw new Error(`unexpected ${path}`);
      return handler(options.body);
    },
    inventory: {
      state: inventory,
      refresh: async () => { requests.push(["refresh"]); },
      accept: async (answer) => {
        if (!answer?.plugin) return;
        inventory.update((value) => ({ ...value, plugins: value.plugins.map((row) => (row.id === answer.plugin.id ? answer.plugin : row)) }));
      },
    },
  };
  const ui = { slots: { register: (name, options, component) => shell.slots.register(name, options, component) }, navigate: (key) => navigated.push(key) };
  register(ui, shell);
  const page = shell.slots.winner("main", "plugins").component({ visible: true });
  document.body.append(page.element);
  return { shell, page, inventory, requests, toasts, navigated, router, element: page.element };
}
const cards = (root) => root.querySelectorAll(".plugin-card:not(.plugin-card--skeleton)");
const flip = (input, checked) => { input.checked = checked; input.dispatchEvent(new Event("change")); };
const press = (node) => node.dispatchEvent(new Event("click"));
const byText = (root, selector, text) => root.querySelectorAll(selector).find((node) => node.textContent === text);

test("plugins are grouped by category in a fixed order, labelled only when they need something, with a gear for settings", () => {
  const p = pages([plugin("telegram", { category: "channels" }), plugin("browser", { readiness: { ready: false, issues: ["Install Chromium."] } }),
    plugin("notes", { enabled: false, active: false, configuration: { schema: { type: "object", properties: {} }, overrides: {}, value: {}, diagnostics: [], secrets: [] } }),
    plugin("odd", { category: "mystery" })]);
  // The page shown reads the inventory and the managed packages.
  expect(p.requests).toEqual([["refresh"], ["/extensions/packages", "GET"]]);
  const groups = p.element.querySelectorAll(".plugins__group");
  expect(groups.map((group) => [group.querySelector(".group__title").textContent, group.hidden]))
    .toEqual([["Interface0", true], ["Channels1", false], ["Agents0", true], ["Tools2", false], ["Conversation0", true], ["System0", true], ["Other1", false]]);
  const tools = cards(groups[3]);
  expect(tools.map((card) => [card.querySelector(".plugin-card__title").textContent, card.querySelector(".tag")?.textContent ?? null]))
    .toEqual([["Browser", "Setup needed"], ["Notes", null]]);
  expect(cards(groups[1])[0].querySelector(".tag")).toBeNull();
  // The version sits beside the name.
  expect(cards(groups[1])[0].querySelector(".plugin-card__name").textContent).toBe("Telegramv1.0");
  // Settings fields earn a gear that opens the plugin; no fields, no gear.
  const gear = (card, label) => card.querySelectorAll("button").find((node) => node.getAttribute("aria-label") === label);
  expect(gear(cards(groups[1])[0], "Telegram settings").hidden).toBe(false);
  const notes = tools[1];
  expect(gear(notes, "Notes settings").hidden).toBe(true);
  expect(notes.querySelector(".plugin-tile").textContent).toBe("N");
  const toggle = notes.querySelector("input[role=switch]");
  expect([toggle.checked, toggle.getAttribute("aria-label")]).toEqual([false, "Notes enabled"]);
  // Switching a plugin on leaves it where it was.
  flip(toggle, true);
  expect(cards(groups[3]).map((card) => card.dataset.pluginId)).toEqual(["browser", "notes"]);
  expect(p.element.querySelector(".plugins__grid[aria-hidden]").hidden).toBe(true);
  press(gear(cards(groups[1])[0], "Telegram settings"));
  expect(p.router.read().plugin).toBe("telegram");
});

test("skeletons stand in until the first read, and a failed read and loader failures are said", () => {
  const p = pages([], { loaded: false });
  expect(p.element.querySelector(".plugins__grid[aria-hidden]").hidden).toBe(false);
  p.inventory.update((value) => ({ ...value, error: new Error("Nexus is unreachable") }));
  expect(p.element.querySelector(".alert--error").textContent).toBe("Nexus is unreachable");
  p.inventory.update((value) => ({ ...value, error: null, loaded: true, failures: [{ id: "broken", message: "bad manifest" }] }));
  expect(p.element.querySelectorAll(".alert--error").map((node) => node.hidden ? "" : node.textContent)).toContain("broken: bad manifest");
  expect(p.element.querySelector(".empty-state").hidden).toBe(false);
});

test("enabling posts the plugin manager's enable and applies the answered row", async () => {
  const p = pages([plugin("notes", { enabled: false, active: false })], { answers: {
    "POST /extensions/notes/enable": () => ({ saved: true, applied: true, plugin: plugin("notes") }) } });
  flip(cards(p.element)[0].querySelector("input[role=switch]"), true);
  await settle();
  expect(p.requests.at(-1)).toEqual(["/extensions/notes/enable", "POST", { dependents: [] }]);
  expect(cards(p.element)[0].querySelector(".tag")).toBeNull();
  expect(p.toasts).toEqual([["Saved and applied.", "success"]]);
});

test("disabling what other enabled plugins need asks first and can disable them together; cancelling changes nothing", async () => {
  const p = pages([plugin("base"), plugin("dependent", { requires: ["base"] })], { answers: {
    "POST /extensions/base/disable": () => ({ saved: true, applied: true, plugin: plugin("base", { enabled: false, active: false }) }) } });
  const toggle = cards(p.element)[0].querySelector("input[role=switch]");
  flip(toggle, false);
  await settle();
  let dialog = document.body.querySelector("dialog");
  expect(dialog.querySelector(".modal__title").textContent).toBe("Disable Base?");
  press(byText(dialog, "button", "Cancel"));
  await settle();
  expect(p.requests.filter(([path]) => path.endsWith("/disable"))).toEqual([]);
  expect(toggle.checked).toBe(true);
  flip(toggle, false);
  await settle();
  dialog = document.body.querySelector("dialog");
  const box = dialog.querySelector("input[type=checkbox]");
  expect(box.closest("label").textContent).toBe("Dependent");
  box.checked = true;
  press(byText(dialog, "button", "Disable plugin"));
  await settle();
  expect(p.requests.at(-1)).toEqual(["/extensions/base/disable", "POST", { dependents: ["dependent"] }]);
});

test("the plugin serving the page, and what it requires, cannot be switched off from the page", async () => {
  const p = pages([
    plugin("rho.webui", { name: "Web interface", requires: ["rho.ops"], capabilities: { tools: [], commands: [], webui: null, page: true } }),
    plugin("rho.ops", { name: "Ops" }), plugin("notes")]);
  const [webui, ops, notes] = cards(p.element).map((card) => [card.querySelector("input[role=switch]"), card.querySelector(".switch")]);
  expect(webui[0].disabled).toBe(true);
  expect(webui[1].dataset.tip).toBe("This plugin serves the page you are using, so it cannot be turned off from here. Use the terminal instead: rho extensions disable rho.webui");
  expect(ops[0].disabled).toBe(true);
  expect(ops[1].dataset.tip).toBe("Web interface needs this plugin, so it cannot be turned off from here. Use the terminal instead: rho extensions disable rho.ops");
  expect([notes[0].disabled, notes[1].dataset.tip]).toEqual([false, undefined]);
  // Even a flip that reaches the handler is refused: no dialog, no request.
  flip(ops[0], false);
  await settle();
  expect(document.body.querySelector("dialog")).toBeNull();
  expect(p.requests.filter(([path]) => path.endsWith("/disable"))).toEqual([]);
  expect(ops[0].checked).toBe(true);
  press(cards(p.element)[1].querySelector(".plugin-card__title"));
  const detail = p.element.querySelector(".plugin-detail");
  expect(detail.querySelector("input[role=switch]").disabled).toBe(true);
  expect(detail.querySelector(".plugin-detail__lock").textContent).toContain("Web interface needs this plugin");
  expect(detail.querySelector(".plugin-detail__heading").textContent).toBe("Opsv1.0");
  // Once the page's owner is not running, nothing is locked.
  p.inventory.update((value) => ({ ...value, plugins: value.plugins.map((row) => (row.id === "rho.webui" ? { ...row, capabilities: { ...row.capabilities, page: false } } : row)) }));
  expect(detail.querySelector("input[role=switch]").disabled).toBe(false);
  expect(detail.querySelector(".plugin-detail__lock").hidden).toBe(true);
});

test("a failed activation stays enabled with its issues and Retry activation, and keeps unsaved configuration", async () => {
  const initial = plugin("example", { enabled: false, active: false, readiness: { ready: false, issues: [] } });
  const failed = { ...initial, enabled: true, readiness: { ready: false, issues: ["Install the dependency, then retry activation."] } };
  const active = { ...failed, active: true, readiness: { ready: true, issues: [] } };
  let finish;
  const p = pages([initial], { address: { plugin: "example" }, answers: {
    "POST /extensions/example/enable": (body) => (body.dependents
      ? Promise.reject(Object.assign(new Error(failed.readiness.issues[0]), { status: 503, details: { saved: true, applied: false, plugin: failed } }))
      : new Promise((resolve) => { finish = () => resolve({ saved: true, applied: true, plugin: active }); })) } });
  const detail = p.element.querySelector(".plugin-detail");
  const port = detail.querySelector("input[type=number]");
  type(port, "4373");
  flip(detail.querySelector("input[role=switch]"), true);
  await settle();
  expect(detail.querySelector(".tag").textContent).toBe("Failed");
  expect(detail.querySelector(".alert--warning").textContent).toBe("Install the dependency, then retry activation.");
  expect(detail.querySelector(".plugin-detail__facts").textContent).toContain("Requested: enabled · Running: inactive · Setup needed");
  const retry = byText(detail, "button", "Retry activation");
  expect(retry.closest(".plugin-detail__actions").hidden).toBe(false);
  retry.click();
  expect(retry.disabled).toBe(true);
  retry.click();
  expect(p.requests.filter(([path]) => path === "/extensions/example/enable").map(([, , body]) => body)).toEqual([{ dependents: [] }, {}]);
  finish();
  await settle();
  expect(retry.closest(".plugin-detail__actions").hidden).toBe(true);
  expect(detail.querySelector(".plugin-detail__status .tag")).toBeNull();
  expect(port.value).toBe("4373");
});

test("a running plugin's own configuration body replaces the generic form while it is registered", () => {
  const p = pages([plugin("telegram")], { address: { plugin: "telegram" } });
  const config = () => p.element.querySelector(".plugin-detail__config");
  expect(config().querySelector("form.plugin-form")).not.toBeNull();
  const seen = [];
  const dispose = p.shell.slots.register("plugins.item.config", { key: "telegram" }, (props) => {
    seen.push(props.plugin.id);
    return { element: el("section", { class: "telegram-body", text: "Telegram setup" }), update: (next) => seen.push(`update:${next.plugin.readiness.ready}`) };
  }, "rho.ingress_telegram");
  expect(config().querySelector(".telegram-body").textContent).toBe("Telegram setup");
  p.inventory.update((value) => ({ ...value, plugins: [plugin("telegram", { readiness: { ready: false, issues: [] } })] }));
  expect(seen).toEqual(["telegram", "update:false"]);
  dispose();
  expect(config().querySelector("form.plugin-form")).not.toBeNull();
});

test("a module that failed to load is said on its card and, with Reload page, on its detail", () => {
  const p = pages([plugin("telegram")]);
  p.shell.modules.state.set(new Map([["telegram", { id: "telegram", name: "Telegram", status: "failed", phase: "import", message: "boom" }]]));
  expect(cards(p.element)[0].querySelector(".alert--error").textContent).toBe("The interface of Telegram failed while loading: boom");
  press(cards(p.element)[0].querySelector(".plugin-card__title"));
  const failure = p.element.querySelector(".plugin-detail__failure");
  expect(failure.hidden).toBe(false);
  expect(byText(failure, "button", "Reload page")).toBeDefined();
});

test("a card opens the detail at /plugins/<id>, the crumbs return to the list, and another page part can open a detail", () => {
  const p = pages([plugin("telegram"), plugin("notes")]);
  press(cards(p.element)[1].querySelector(".plugin-card__title"));
  expect(p.router.read()).toMatchObject({ panel: "plugins", plugin: "notes" });
  expect(p.element.querySelector(".plugin-detail__name").textContent).toBe("Notes");
  expect(p.element.querySelector(".plugin-detail__facts").textContent).toContain("Saved sourceinstalled · notes · 1.0");
  press(byText(p.element, ".crumbs button", "Plugins"));
  expect(p.router.read().plugin).toBeNull();
  expect(p.element.querySelector(".page")).not.toBeNull();
  p.router.push({ panel: "plugins", plugin: "telegram" }, { notify: true });
  expect(p.element.querySelector(".plugin-detail__name").textContent).toBe("Telegram");
  p.router.push({ plugin: "missing" }, { notify: true });
  expect(p.element.querySelector(".plugins__detail .empty-state").hidden).toBe(false);
});

test("the sidebar row opens the page, marks it current, collapses to an icon and warns while a running plugin needs setup", () => {
  const p = pages([plugin("telegram")]);
  const container = el("nav");
  const outlet = listOutlet(p.shell.slots, "sidebar.panellist", container, { current: "conversation", collapsed: false });
  const row = container.querySelector(".panel-row");
  expect(row.getAttribute("href")).toBe("/plugins");
  expect(row.querySelector(".panel-row__badge").hidden).toBe(true);
  press(row);
  expect(p.navigated).toEqual(["plugins"]);
  p.inventory.update((value) => ({ ...value, plugins: [plugin("telegram", { readiness: { ready: false, issues: [] } })] }));
  expect(row.querySelector(".panel-row__badge").hidden).toBe(false);
  expect(row.querySelector(".sr-only").textContent).toBe("A running plugin needs setup");
  outlet.update({ current: "plugins", collapsed: true });
  expect(row.getAttribute("aria-current")).toBe("page");
  expect([row.getAttribute("aria-label"), row.dataset.tip]).toEqual(["Plugins", "Plugins"]);
  p.router.push({ plugin: "telegram" });
  press(row);
  expect(p.router.read().plugin).toBeNull();
  expect(p.navigated).toEqual(["plugins"]);
});
