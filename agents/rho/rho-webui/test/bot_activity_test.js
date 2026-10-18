import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush, type } from "./support/dom.js";
import { botActivity } from "../webui/features/bots/activity.js";
import { homeWorkspace } from "../webui/features/bots/home.js";
import { botsSidebar } from "../webui/features/bots/sidebar.js";
import { observable } from "../webui/kernel/observable.js";
import { conversationControls } from "../webui/features/conversation/lifecycle.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());
const BOT = { public_id: "b-1", name: "helper", display_name: "Helper", home_workspace_public_id: "w-new" };
const locator = (id, workspace = "w-old") => ({ public_id: id, workspace_public_id: workspace });
const deferred = () => { let resolve; const promise = new Promise((done) => { resolve = done; }); return { promise, resolve }; };
const button = (root, label) => root.querySelectorAll("button").find((node) => node.textContent === label);

function harness({ current = locator("c-current"), bot = BOT, history = [] } = {}) {
  const requests = []; const calls = [];
  const handlers = {
    "/bots/detail": () => ({ bot, current, effective_welcome_message: "Welcome <person>." }),
    "/bots/history": () => ({ conversations: history, pagination: {} }),
    "/bots/current": () => ({ current: locator("c-current"), selected: locator("c-current"), replayed: false }),
    "/bots/new": () => ({ current: locator("c-new", "w-new"), selected: locator("c-new", "w-new"), replayed: false }),
    "/bots/resume": () => ({ current: locator("c-older", "w-old"), selected: locator("c-older", "w-old"), replayed: false }),
    "/workspaces": () => ({ workspaces: [{ public_id: "w-new", name: "New home" }, { public_id: "w-old", name: "Old home" }] }),
    "/agents/settings": ({ body }) => body,
  };
  const shell = { call: async (path, options = {}) => {
    const request = { path, method: options.method || "GET", body: options.body, signal: options.signal };
    requests.push(request); return handlers[path.split("?")[0]]({ ...request, query: new URLSearchParams(path.split("?")[1]) });
  }, conversations: { select: (...args) => calls.push(["select", ...args]) }, toast: (...args) => calls.push(["toast", ...args]),
  bots: { state: observable({ bots: [bot] }) }, router: { push: (...args) => calls.push(["route", ...args]) }, navigate: (...args) => calls.push(["navigate", ...args]) };
  const view = botActivity(shell, bot);
  document.body.append(view.element);
  return { view, shell, handlers, requests, calls, writes: () => requests.filter((row) => row.method !== "GET") };
}

test("reading a Bot renders static welcome and history without creating inputs or a conversation", async () => {
  const h = harness({ current: null }); await flush();
  expect(h.writes()).toEqual([]);
  expect(h.view.element.querySelector(".bots-page__welcome").textContent).toBe("Welcome <person>.");
  expect(h.view.element.querySelector("person")).toBeNull();
  button(h.view.element, "Open current conversation").click(); await flush();
  expect(h.writes()).toHaveLength(1);
  expect(h.writes()[0].path).toBe("/bots/current");
  expect(h.calls).toContainEqual(["select", "c-current", { workspace: "w-old" }]);
  h.view.dispose();
});

test("new and resume use the switch owner, keep a retry key after response loss and open the actual current winner", async () => {
  const older = { ...locator("c-older"), title: "Earlier work", archived_at: "2026-01-01", active_turn_public_id: "t-live", bot_public_id: BOT.public_id };
  const h = harness({ history: [older] }); await flush();
  let attempts = 0;
  h.handlers["/bots/new"] = () => { if (++attempts === 1) throw new Error("Response lost"); return {
    selected: locator("c-new", "w-new"), current: locator("c-current-winner", "w-other"), replayed: true,
  }; };
  button(h.view.element, "New conversation").click(); await flush();
  expect(h.view.element.textContent).toContain("Response lost");
  button(h.view.element, "New conversation").click(); await flush();
  const [first, retry] = h.writes();
  expect(first.body.operation_id).toBe(retry.body.operation_id);
  expect(h.calls).toContainEqual(["select", "c-current-winner", { workspace: "w-other" }]);
  button(h.view.element, "Resume").click(); await flush();
  expect(h.writes().at(-1)).toMatchObject({ path: "/bots/resume", body: {
    agent_public_id: BOT.public_id, conversation_public_id: "c-older", workspace_public_id: "w-old",
  } });
  expect(h.calls).toContainEqual(["select", "c-older", { workspace: "w-old" }]);
  expect(h.writes().some((row) => row.path.includes("stop") || row.path === "/conversations/new")).toBe(false);
  h.view.dispose();
});

test("history pagination discards a late page after the archived filter changes", async () => {
  const h = harness(); await flush();
  h.handlers["/bots/history"] = () => ({ conversations: [{ ...locator("c-one"), title: "One" }], pagination: { next_after: "next-page" } });
  await h.view.refresh();
  const pending = deferred();
  h.handlers["/bots/history"] = ({ query }) => query.has("after") ? pending.promise : { conversations: [{ ...locator("c-archive", "w-archive"), title: "Archived" }], pagination: {} };
  button(h.view.element, "Show more").click();
  type(h.view.element.querySelector('[name="bot_history_archived"]'), "1"); await flush();
  pending.resolve({ conversations: [{ ...locator("c-stale"), title: "Stale page" }], pagination: {} }); await flush();
  expect(h.view.element.textContent).toContain("Archived");
  expect(h.view.element.textContent).not.toContain("Stale page");
  const link = h.view.element.querySelector(".bots-page__history a");
  expect(link.getAttribute("href")).toBe("/workspaces/w-archive/conversations/c-archive");
  link.click(); expect(h.calls).toContainEqual(["select", "c-archive", { workspace: "w-archive" }]);
  h.view.dispose();
});

test("Home controls future new conversations without blocking an existing current conversation", async () => {
  const h = harness({ bot: { ...BOT, home_workspace_public_id: null } }); await flush();
  expect(button(h.view.element, "New conversation").disabled).toBe(true);
  expect(button(h.view.element, "Open current conversation").disabled).toBe(false);
  h.handlers["/bots/detail"] = () => ({ bot: { ...BOT, home_workspace_public_id: null }, current: null, effective_welcome_message: "" });
  await h.view.refresh();
  expect(button(h.view.element, "Open current conversation").disabled).toBe(true);
  expect(h.view.element.textContent).toContain("Choose a Home Workspace below");
  expect(h.view.element.querySelector(".bots-page__welcome").hidden).toBe(true);
  h.view.dispose();
});

test("Home saves separately and preserves an unsaved choice through failed and successful refreshes", async () => {
  const h = harness(); const saved = [];
  const home = homeWorkspace(h.shell, BOT, { saved: (value) => saved.push(value) }); document.body.append(home.element); await flush();
  const select = home.element.querySelector("select"); type(select, "w-old");
  const read = h.handlers["/workspaces"];
  h.handlers["/workspaces"] = () => { throw new Error("No connection"); };
  await home.refresh(); expect(select.value).toBe("w-old"); expect(select.closest("fieldset").disabled).toBe(true);
  h.handlers["/workspaces"] = read; await home.refresh(); expect(select.value).toBe("w-old");
  select.form.requestSubmit(); await flush();
  expect(h.writes().at(-1)).toMatchObject({ method: "PUT", path: "/agents/settings", body: { agent_public_id: BOT.public_id, home_workspace_public_id: "w-old" } });
  expect(saved).toEqual(["w-old"]);
  type(select, ""); select.form.requestSubmit(); await flush();
  expect(h.writes().at(-1).body.home_workspace_public_id).toBeNull();
  home.dispose(); h.view.dispose();
});

test("Home preserves a choice reported by change when Bot detail refreshes before saving", async () => {
  const bot = { ...BOT, home_workspace_public_id: null };
  const h = harness({ bot, current: null }); const saved = [];
  const home = homeWorkspace(h.shell, bot, { saved: (value) => saved.push(value) }); document.body.append(home.element); await flush();
  const select = home.element.querySelector("select");
  select.value = "w-old";
  select.dispatchEvent(new Event("change", { bubbles: true }));
  home.update(bot, true);
  select.form.requestSubmit(); await flush();
  expect(h.writes().at(-1)).toMatchObject({ method: "PUT", path: "/agents/settings", body: { agent_public_id: BOT.public_id, home_workspace_public_id: "w-old" } });
  expect(saved).toEqual(["w-old"]);
  expect(select.value).toBe("w-old");
  home.dispose(); h.view.dispose();
});

test("a Bot history row stays read-only after its live channel binding has moved, with Stop still available", () => {
  expect(conversationControls({ bot_public_id: BOT.public_id, ingresses: [], archived_at: "2026-01-01" }, "ready"))
    .toEqual({ writable: false, send: false, stop: true });
});

test("sidebar Bot links ensure current through the Bot owner and settings use its UUID", async () => {
  const h = harness({ bot: { ...BOT, home_workspace_public_id: null } });
  const sidebar = botsSidebar({ navigate: h.shell.navigate }, h.shell, { current: "conversation", collapsed: false });
  document.body.append(sidebar.element);
  sidebar.element.querySelector(".sidebar__bot-name").click(); await flush();
  expect(h.writes()[0].path).toBe("/bots/current");
  expect(h.calls).toContainEqual(["select", "c-current", { workspace: "w-old" }]);
  sidebar.element.querySelectorAll("button").find((node) => node.getAttribute("aria-label") === "Settings for Helper").click();
  expect(h.calls.find((call) => call[0] === "route")[1]).toMatchObject({ panel: "bots", item: BOT.public_id });
  sidebar.update({ collapsed: true }); expect(sidebar.element.querySelector(".sidebar__bots").hidden).toBe(true);
  sidebar.dispose(); h.view.dispose();
});

test("Bot conversation controls and sidebar use cryptographic operation IDs on LAN HTTP without randomUUID", async () => {
  const original = globalThis.crypto;
  let randomReads = 0;
  globalThis.crypto = { getRandomValues: (bytes) => { randomReads += 1; return original.getRandomValues(bytes); } };
  const h = harness({ history: [{ ...locator("c-older"), title: "Earlier work" }] });
  const sidebar = botsSidebar({ navigate: h.shell.navigate }, h.shell, { current: "conversation", collapsed: false });
  document.body.append(sidebar.element);
  try {
    await flush();
    await h.view.open();
    button(h.view.element, "New conversation").click(); await flush();
    button(h.view.element, "Resume").click(); await flush();
    sidebar.element.querySelector(".sidebar__bot-name").click(); await flush();
    expect(h.writes().map((request) => request.path)).toEqual(["/bots/current", "/bots/new", "/bots/resume", "/bots/current"]);
    const ids = h.writes().map((request) => request.body.operation_id);
    expect(ids.every((id) => /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id))).toBe(true);
    expect(new Set(ids).size).toBe(4);
    expect(randomReads).toBe(4);
    expect(h.calls.filter((call) => call[0] === "select")).toHaveLength(4);
  } finally { sidebar.dispose(); h.view.dispose(); globalThis.crypto = original; }
});
