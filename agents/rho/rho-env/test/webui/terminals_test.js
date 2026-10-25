import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "../../../rho-webui/test/support/dom.js";
import { terminalSession as session } from "../../webui/terminal/session.js";
import { terminalsPanel as picker } from "../../webui/terminal/picker.js";
import { register as registerModule } from "../../webui/terminal/index.js";
import { taskTerminal } from "../../webui/terminal/task.js";
import english from "../../webui/terminal/locales/en.js";
import { createHandle } from "../../../rho-webui/webui/kernel/handle.js";
import { createSlots } from "../../../rho-webui/webui/kernel/slots.js";
import { translator } from "../../../rho-webui/webui/kernel/i18n.js";
import { el } from "../../../rho-webui/webui/kernel/dom.js";
import { primitives } from "../../../rho-webui/webui/primitives/index.js";
import { uuidv7 } from "../../../rho-webui/webui/kernel/uuid.js";
import { isTerminal } from "../../../rho-webui/webui/kernel/format.js";
const t = translator({ en: english });
const uiFor = (shell) => ({ el, primitives, translator, uuidv7, isTerminal, signal: new AbortController().signal, ...shell });
const terminalSession = (shell, props) => session(uiFor(shell), t, props);
const terminalsPanel = (shell, props) => picker(uiFor(shell), t, props);
const register = (ui, shell) => registerModule(uiFor({ ...shell, slots: ui.slots }));

let restore, panels;
beforeEach(() => { restore = installDocument(); panels = []; });
afterEach(() => { panels.forEach((panel) => panel.dispose()); restore(); });
const target = { public_id: "run", task_key: "call_tool", workspace_public_id: "workspace" };
const findButton = (panel, label) => panel.element.querySelectorAll("button").find((node) => node.textContent === label);

function fixture({ status = "needs_approval", failFirst = false, error = status === "failed" ? { key: "tool_not_served" } : null, stopError = false } = {}) {
  const creates = [], stops = [], updates = [];
  let close;
  const intent = { workspace_public_id: "workspace", runner_executor_public_id: "runner", idempotency_key: "same-intent" };
  const panel = terminalSession({ async call(path, options = {}) {
    if (path === "/runners") return { runners: [{ public_id: "runner", tools: ["terminal"], display_name: "Runner" }] };
    if (path === "/terminals" && options.method === "POST") {
      creates.push(options.body);
      if (failFirst && creates.length === 1) throw new Error("Connection interrupted");
      return { terminal: target };
    }
    if (path.startsWith("/terminals?")) return { terminals: [], has_more: false };
    if (path.startsWith("/runs/task?")) return { task: { status, error } };
    if (path === "/stop") { stops.push(options.body); if (stopError) throw new Error("Stop unavailable"); return {}; }
    throw new Error(`Unexpected request ${path}`);
  } }, { params: { intent }, beforeClose(handler) { close = handler; }, updateParams(next) { updates.push(next); } });
  panels.push(panel);
  return { panel, creates, stops, close: () => close(), updates, settle(nextStatus, nextError) { status = nextStatus; error = nextError; } };
}

test("creation waits for discovery and an uncertain retry preserves the original Runner and key", async () => {
  const f = fixture({ failFirst: true });
  await flush();
  expect(findButton(f.panel, "Retry terminal creation")).toBeTruthy();
  findButton(f.panel, "Retry terminal creation").click();
  await flush();
  expect(f.creates).toHaveLength(2);
  expect(f.creates[0]).toEqual(f.creates[1]);
  expect(f.creates[0].workspace_public_id).toBe("workspace");
  expect(f.panel.element.textContent).toContain("approval");
  expect(f.panel.element.querySelector(".terminal")).toBeNull();
  expect(await f.close()).toBe(true);
  await flush();
  expect(f.stops[0]).toMatchObject({ public_id: "run", host_type: "run", force: true });
  expect(f.stops[0].task_key).toBeUndefined();
});

test("a failed task shows its reason and does not leave an endless Connecting terminal", async () => {
  const f = fixture({ status: "failed" });
  await flush();
  expect(f.panel.element.textContent).toContain("tool_not_served");
  expect(f.panel.element.querySelector(".terminal")).toBeNull();
  expect(f.panel.element.querySelector(".terminal__head")).toBeNull();
});

test("a canceled terminal shows a normal stopped status instead of its cancellation error", async () => {
  const f = fixture({ status: "canceled", error: { key: "run_canceled" } });
  await flush();
  expect(f.updates.at(-1).status).toBe("Terminal stopped");
  expect(f.panel.element.textContent).not.toContain("run_canceled");
  expect(f.panel.element.querySelector(".alert--error").hidden).toBe(true);
  expect(f.panel.element.querySelector(".terminal__head")).toBeNull();
});

test("an already mounted terminal receives the stopped status when cancellation settles", async () => {
  const f = fixture({ status: "running" });
  await flush();
  expect(f.panel.element.querySelector(".terminal")).toBeTruthy();
  f.settle("canceled", { key: "run_canceled" });
  await new Promise((resolve) => setTimeout(resolve, 1100));
  expect(f.updates.at(-1).status).toBe("Terminal stopped");
  expect(f.panel.element.querySelector(".terminal__head")).toBeNull();
  expect(f.panel.element.querySelector(".terminal .alert").hidden).toBe(true);
  expect(f.panel.element.querySelector(".terminal__head")).toBeNull();
  expect(f.panel.element.querySelector(".alert--error").hidden).toBe(true);
  expect(f.panel.element.textContent).not.toContain("run_canceled");
});


test("switching Workspace replaces the panel reads without stopping the previous terminal", async () => {
  let factory;
  const calls = [];
  const shell = { async call(path) {
    calls.push(path);
    return path === "/runners" ? { runners: [] } : { terminals: [], has_more: false };
  } };
  register({ slots: { register(slot, _meta, component) { if (slot === "dock.tab" && _meta.key === "terminals") factory = component; } } }, shell);
  const panel = factory({ conversation: { workspace: "first" } });
  panels.push(panel);
  await flush();
  panel.update({ conversation: { workspace: "second" } });
  await flush();
  expect(calls).toContain("/terminals?workspace_public_id=first");
  expect(calls).toContain("/terminals?workspace_public_id=second");
  expect(calls).not.toContain("/stop");
});

test("unavailable terminals show an empty state instead of a blank selector and recover after refresh", async () => {
  let runners = [];
  const panel = terminalsPanel({ async call(path) {
    return path === "/runners" ? { runners } : { terminals: [], has_more: false };
  } }, { conversation: { workspace: "workspace" } });
  panels.push(panel);
  await flush();
  const runner = panel.element.querySelector("select");
  expect(runner.disabled).toBe(true);
  expect(runner.textContent).toContain("No terminal available");
  expect(panel.element.querySelector(".alert--info").hidden).toBe(false);
  runners = [{ public_id: "runner", tools: ["terminal"], display_name: "Local" }];
  findButton(panel, "Refresh").click();
  await flush();
  expect(runner.disabled).toBe(false);
  expect(findButton(panel, "New terminal").disabled).toBe(false);
  expect(panel.element.querySelector(".alert--info").hidden).toBe(true);
});

test("plugin activation owns its entries and styles, and disposal removes them", () => {
  const slots = createSlots();
  expect(slots.entries("conversation.header.utilities")).toHaveLength(0);
  const handle = createHandle({ id: "rho.terminal", slots, el, primitives, translator, dock: { open() {} } });
  registerModule(handle.ui);
  expect(slots.winner("dock.tab", "terminal").owner).toBe("rho.terminal");
  expect(slots.entries("conversation.header.utilities")).toHaveLength(1);
  expect(slots.entries("task.detail")).toHaveLength(1);
  expect(document.head.querySelectorAll("link")).toHaveLength(2);
  handle.dispose();
  expect(slots.entries("dock.tab")).toHaveLength(0);
  expect(slots.entries("conversation.header.utilities")).toHaveLength(0);
  expect(slots.entries("task.detail")).toHaveLength(0);
  expect(document.head.querySelectorAll("link")).toHaveLength(0);
  const again = createHandle({ id: "rho.terminal", slots, el, primitives, translator, dock: { open() {} } });
  registerModule(again.ui);
  expect(slots.entries("conversation.header.utilities")).toHaveLength(1);
  expect(document.head.querySelectorAll("link")).toHaveLength(2);
  again.dispose();
});

test("terminal creation works on LAN HTTP without crypto.randomUUID", async () => {
  const original = Object.getOwnPropertyDescriptor(globalThis, "crypto");
  const nativeCrypto = globalThis.crypto;
  Object.defineProperty(globalThis, "crypto", { configurable: true,
    value: { getRandomValues: (bytes) => nativeCrypto.getRandomValues(bytes) } });
  try {
    const opened = [];
    const panel = terminalsPanel({ dock: { open: (...args) => opened.push(args), state: () => ({ get: () => ({ tabs: [] }) }) }, async call(path) {
      return path === "/runners" ? { runners: [{ public_id: "runner", tools: ["terminal"], display_name: "Local" }] } : { terminals: [], has_more: false };
    } }, { conversation: { workspace: "workspace" } });
    panels.push(panel);
    expect(findButton(panel, "New terminal").disabled).toBe(true);
    await flush();
    panel.element.querySelector("select").value = "runner";
    findButton(panel, "New terminal").click();
    findButton(panel, "New terminal").click();
    expect(opened).toHaveLength(2);
    expect(opened[0][1].id).not.toBe(opened[1][1].id);
    expect(opened[0][1].params.intent.idempotency_key).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  } finally { Object.defineProperty(globalThis, "crypto", original); }
});

test("reopening an already open shell selects its existing tab without creating another session", async () => {
  const opened = [];
  const existing = { id: "terminal:original-intent", key: "terminal", params: { target, number: 1 } };
  const shell = { dock: { state: () => ({ get: () => ({ tabs: [existing] }) }), open: (...args) => opened.push(args) },
    async call(path) {
      if (path === "/runners") return { runners: [] };
      return { terminals: [{ ...target, status: "dispatched", created_at: "2026-10-25T00:00:00Z" }], has_more: false };
    },
  };
  const panel = terminalsPanel(shell, { conversation: { workspace: "workspace" } });
  panels.push(panel);
  await flush();
  panel.element.querySelector('[data-terminal-id="run"]').click();
  expect(opened).toEqual([["terminal", { id: existing.id }]]);
});

test("an accepted terminal identity survives remounting without a second create or implicit Stop", async () => {
  let params = { intent: { idempotency_key: "original", runner_executor_public_id: "runner" } };
  const calls = [];
  const shell = { async call(path) {
    calls.push(path);
    return path === "/terminals" ? { terminal: target } : { task: { status: "needs_approval" } };
  } };
  const first = terminalSession(shell, { params, beforeClose() {}, updateParams(next) { params = next; } });
  await flush();
  first.dispose();
  const second = terminalSession(shell, { params, beforeClose() {}, updateParams(next) { params = next; } });
  panels.push(second);
  await flush();
  expect(calls.filter((path) => path === "/terminals")).toHaveLength(1);
  expect(calls.filter((path) => path === "/stop")).toHaveLength(0);
  expect(params.target).toEqual(target);
});

test("a failed Stop refuses close and keeps the error visible", async () => {
  const f = fixture({ stopError: true });
  await flush();
  expect(await f.close()).toBe(false);
  expect(f.panel.element.textContent).toContain("Stop unavailable");
  await new Promise((resolve) => setTimeout(resolve, 1100));
  expect(f.panel.element.querySelector(".alert--error").hidden).toBe(false);
  expect(await f.close()).toBe(false);
  expect(f.stops).toHaveLength(2);
});

test("closing a finished shell needs no Stop", async () => {
  const f = fixture({ status: "completed" });
  await flush();
  expect(await f.close()).toBe(true);
  expect(f.stops).toHaveLength(0);
});

test("closing during creation resolves the accepted target before Stop", async () => {
  const f = fixture();
  expect(await f.close()).toBe(true);
  expect(f.creates).toHaveLength(1);
  expect(f.stops[0]).toMatchObject({ public_id: "run", host_type: "run" });
});


test("task attachment is contributed only for a live tool and releases its tab actions", () => {
  const actions = el("span");
  const props = { actions, target, task: null };
  const panel = taskTerminal(uiFor({}), t, props);
  expect(findButton(panel, "Open terminal").hidden).toBe(true);
  for (const [kind, status, hidden] of [["tool_task", "dispatched", false], ["tool_task", "running", false], ["model_task", "running", true], ["tool_task", "completed", true]]) {
    panel.update({ ...props, task: { kind, status } });
    expect(findButton(panel, "Open terminal").hidden).toBe(hidden);
  }
  panel.update({ ...props, task: { kind: "tool_task", status: "running" } });
  findButton(panel, "Open terminal").click();
  expect(actions.querySelector("button").getAttribute("aria-label")).toBe("Stop terminal");
  panel.update({ ...props, task: { kind: "tool_task", status: "completed" } });
  expect(panel.element.querySelector(".terminal").dataset.connection).toBe("closed");
  panel.dispose();
  expect(actions.children).toHaveLength(0);
});
