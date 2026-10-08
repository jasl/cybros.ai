import { test, expect } from "bun:test";
import { telegramSettings } from "../webui/telegram_settings.js";

// Exercise the actual setup controls and callbacks; the E2E suite checks
// browser focus, layout and the daemon's plugin activation route.
async function withDocument(run) {
  const previous = globalThis.document;
  const node = (tag) => ({ tag, nodeType: 1, children: [], listeners: {}, value: "", textContent: "", hidden: false,
    setAttribute(name, value) { this[name] = value; },
    addEventListener(name, handler) { this.listeners[name] = handler; },
    append(child) { this.children.push(child); },
    replaceChildren(...children) { this.children = children; },
    querySelectorAll(selector) { return descendants(this).filter((child) => child !== this && child.tag === selector); },
  });
  globalThis.document = { createElement: node, createTextNode: (text) => ({ nodeType: 3, textContent: text, children: [] }) };
  try { await run(); } finally { globalThis.document = previous; }
}

const descendants = (node) => [node, ...node.children.flatMap(descendants)];
const visible = (node) => node.hidden ? [] : [node, ...node.children.flatMap(visible)];
const button = (panel, label) => visible(panel.element).find((node) => node.tag === "button" && node.textContent === label);
const text = (node) => node.textContent + node.children.map(text).join("");
const plugin = { id: "rho.ingress_telegram", enabled: false, active: false, configurable: true,
  readiness: { ready: false, issues: [] }, configuration: { diagnostics: [] } };
const awaitingToken = { enabled: false, connection: "stopped", token: { present: false }, configuration: {}, access: null };

test("Telegram activates directly in setup and reveals the same settings form after success", async () => withDocument(async () => {
  let complete;
  let activations = 0;
  const panel = telegramSettings({ write: async () => {}, changed: async () => {}, showError: (error) => { throw error; },
    activate: async () => {
      activations++;
      await new Promise((resolve) => { complete = resolve; });
      panel.update(awaitingToken, { ...plugin, enabled: true, active: true });
    } });
  panel.update(null, plugin);
  const token = descendants(panel.element).find((node) => node.name === "token");
  expect(visible(panel.element)).not.toContain(token);
  const enable = button(panel, "Enable Telegram");
  const pending = enable.listeners.click();
  expect(enable.disabled).toBe(true);
  expect(enable.textContent).toBe("Enabling Telegram…");
  await enable.listeners.click();
  expect(activations).toBe(1);
  complete(); await pending;
  expect(visible(panel.element)).toContain(token);
  expect(button(panel, "Enable Telegram")).toBeUndefined();
  expect(button(panel, "Verify and save Telegram")).toBeDefined();
  expect(text(panel.element)).toContain("Connect your Telegram bot");
}));

test("a saved activation failure keeps its repair reason and retry in Telegram setup", async () => withDocument(async () => {
  let activations = 0;
  const failed = { ...plugin, enabled: true, readiness: { ready: false, issues: [{ message: "Install the missing dependency and retry." }] } };
  const panel = telegramSettings({ write: async () => {}, changed: async () => {}, showError: () => {}, activate: async () => {
    activations++; panel.update(null, failed);
  } });
  panel.update(null, plugin);
  await button(panel, "Enable Telegram").listeners.click();
  expect(text(panel.element)).toContain("Install the missing dependency and retry.");
  expect(button(panel, "Retry Telegram activation").disabled).toBe(false);
  await button(panel, "Retry Telegram activation").listeners.click();
  expect(activations).toBe(2);
  expect(visible(panel.element).some((node) => node.name === "token")).toBe(false);
}));

test("the activated setup form guides missing token and owner steps without treating onboarding as a failure", async () => withDocument(async () => {
  const panel = telegramSettings({ write: async () => {}, activate: async () => {}, changed: async () => {}, showError: () => {} });
  panel.update({ ...awaitingToken, enabled: true }, { ...plugin, enabled: true, active: true,
    readiness: { ready: false, issues: ["A Telegram bot token is not configured", "A Telegram bot owner is not configured"] } });
  expect(text(panel.element)).toContain("Connect your Telegram bot");
  expect(text(panel.element)).toContain("Save a bot token to start Telegram polling.");
  expect(text(panel.element)).not.toContain("A Telegram bot token is not configured");
  expect(button(panel, "Verify and save Telegram")).toBeDefined();
}));

test("an unavailable Telegram package gives installation guidance without an unusable activation button", async () => withDocument(async () => {
  const panel = telegramSettings({ write: async () => {}, activate: async () => {}, changed: async () => {}, showError: () => {} });
  panel.update(null, null);
  expect(text(panel.element)).toContain("Install rho-ingress-telegram");
  expect(button(panel, "Enable Telegram")).toBeUndefined();
  panel.update(null, { ...plugin, configurable: false, readiness: { ready: false, issues: [{ message: "Repair the plugin descriptor." }] } });
  expect(button(panel, "Enable Telegram").disabled).toBe(true);
  expect(text(panel.element)).toContain("Repair the plugin descriptor.");
}));

test("activation errors release the local button for a deliberate retry", async () => withDocument(async () => {
  const errors = [];
  const failure = new Error("The activation request failed.");
  const panel = telegramSettings({ write: async () => {}, changed: async () => {}, showError: (error) => errors.push(error),
    activate: async () => { throw failure; } });
  panel.update(null, plugin);
  await button(panel, "Enable Telegram").listeners.click();
  expect(errors).toEqual([failure]);
  expect(button(panel, "Enable Telegram").disabled).toBe(false);
}));

test("Telegram grouping delay defaults to two seconds and saves through the shared configuration door", async () => withDocument(async () => {
  const writes = [];
  const panel = telegramSettings({ write: async (path, body) => { writes.push({ path, body }); return { ...awaitingToken, configuration: body }; },
    activate: async () => {}, changed: async () => {}, showError: (error) => { throw error; } });
  panel.update(awaitingToken, plugin);
  const field = descendants(panel.element).find((node) => node.name === "input_debounce_seconds");
  expect(Number(field.value)).toBe(2);
  expect([field.min, field.max, field.step]).toEqual(["0", "10", "1"]);
  field.value = "10";
  const options = descendants(panel.element).find((node) => node.tag === "form" && descendants(node).includes(field));
  options.listeners.input();
  panel.update({ ...awaitingToken, configuration: { input_debounce_seconds: 1 } }, plugin);
  expect(field.value).toBe("10");
  await options.listeners.submit({ preventDefault() {} });
  expect(writes).toHaveLength(1);
  expect(writes[0].path).toBe("/telegram/configuration");
  expect(writes[0].body.input_debounce_seconds).toBe(10);
  panel.update({ ...awaitingToken, configuration: { input_debounce_seconds: 0 } }, plugin);
  expect(Number(field.value)).toBe(0);
}));
