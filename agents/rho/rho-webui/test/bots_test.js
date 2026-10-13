import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { createSlots } from "../webui/kernel/slots.js";
import { observable } from "../webui/kernel/observable.js";
import { createBots } from "../webui/shell/bots.js";
import { botsPage, botDetail } from "../webui/features/bots/page.js";
import { bodyOf, policyOf, NAME_FORMAT } from "../webui/features/bots/editor.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const CATALOG = { main_preset_public_id: "p-main", default_bot_preset_public_id: "p-assistant", presets: [
  { public_id: "p-main", name: "Main work" }, { public_id: "p-assistant", name: "Assistant" }, { public_id: "p-review", name: "Review" },
] };
const REVIEWER = { public_id: "u-reviewer", name: "reviewer", display_name: "Reviewer", description: "Reviews changes",
  home_workspace_public_id: "w-home", preset_public_id: "p-review", preset_name: "Review", welcome_message: "Send me a change to review.",
  subagent: false,
  model: "vendor/text", model_standing: "available", tools: ["read", "grep"], system_prompt: "Projection only.",
  configuration: { runner_tool_names: [], prompt_template: { blocks: [] } } };
const WRITER = { public_id: "u-writer", name: "writer", display_name: "Writer", description: "Writes docs", from: "alice", model: "vendor/text", model_standing: "available", tools: [] };
const DRAFT = { public_id: "u-draft", name: "draft", display_name: "Draft", description: "Not ready", preset_public_id: "p-main", preset_name: "Main work", model_standing: "unset", tools: [] };
const UNAVAILABLE = { public_id: "u-old", name: "old", display_name: "Old", description: "Unavailable model", preset_public_id: "p-review", preset_name: "Review", model: "vendor/retired", model_standing: "unavailable", tools: [] };
const GROUP = { public_id: "u-group", name: "telegram_group", display_name: "telegram_group", description: "Telegram groups", model_standing: "unset", tools: [], registered: true };
const button = (root, label) => root.querySelectorAll("button").find((node) => node.textContent === label);
const control = (root, name) => root.querySelector(`[name="${name}"]`);

function harness({ bots = [WRITER, REVIEWER, DRAFT, UNAVAILABLE, GROUP], adopted = true } = {}) {
  const requests = [];
  const handlers = {
    "GET /agents": () => ({ bots }),
    "GET /presets": () => CATALOG,
    "GET /workspaces": () => ({ workspaces: [{ public_id: "w-home", name: "Home" }] }),
    "GET /bots/detail": () => ({ bot: REVIEWER, current: null, effective_welcome_message: REVIEWER.welcome_message }),
    "GET /bots/history": () => ({ conversations: [], pagination: { next_after: null } }),
    "POST /bots/current": () => ({ current: { public_id: "c-current", workspace_public_id: "w-home" } }),
    "POST /agents/rm": () => ({ removed: REVIEWER }),
    "PUT /agents": ({ body }) => ({ agent: { ...REVIEWER, ...body, display_name: body.display_name || body.name } }),
  };
  const call = async (path, options = {}) => {
    const method = options.method || "GET";
    requests.push({ method, path, body: options.body });
    return (handlers[`${method} ${path}`] || handlers[`${method} ${path.split("?")[0]}`])({ body: options.body });
  };
  const setup = { state: observable({ daemon: adopted ? { identity: { user_public_id: "u-rho", handle: "rho" }, workspace: { state: "adopted" } } : null }) };
  const controller = new AbortController();
  return { bots: createBots({ call, signal: controller.signal, setup }), requests, handlers, setup, controller, call };
}

function pageHarness(options) {
  const h = harness(options);
  const calls = [];
  const setup = { state: observable({}), refresh: async () => calls.push(["refresh"]) };
  let location = { panel: "bots", item: null };
  const listeners = new Set();
  const router = {
    read: () => ({ ...location }),
    push(changes, { notify } = {}) { location = { ...location, ...changes }; if (notify) for (const listener of listeners) listener({ ...location }); },
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    pop(changes) { location = { ...location, ...changes }; for (const listener of listeners) listener({ ...location }); },
  };
  const shell = { slots: createSlots(), renderError: (error) => { throw error; }, settings: { open: (section, item) => calls.push(["settings", section, item]) }, bots: h.bots, call: h.call, setup, router,
    toast: (text, tone) => calls.push(["toast", text, tone?.tone]), navigate: (key) => calls.push(["navigate", key]),
    conversations: { select: (...args) => calls.push(["select", ...args]), startNew: (options) => calls.push(["startNew", options]) } };
  const view = botsPage(shell);
  document.body.append(view.element);
  return { ...h, calls, setup, router, view, location: () => location,
    rows: () => view.element.querySelectorAll(".bots-page__bot"),
    open: (name = "reviewer") => view.element.querySelector(`[data-bot="${name}"] .bots-page__name`).click(),
    editor: () => view.element.querySelector(".bots-page__editor"),
    crumbs: () => view.element.querySelectorAll(".crumbs li").map((node) => node.textContent) };
}

test("the store lists persistent identities by name and preserves conversation eligibility", async () => {
  const h = harness();
  await flush();
  expect(h.requests.map((row) => row.path)).toEqual(["/agents"]);
  expect(h.bots.state.get().bots.map((row) => row.name)).toEqual(["draft", "old", "reviewer", "telegram_group", "writer"]);
  expect(h.bots.own()).toMatchObject({ public_id: "u-rho", name: "rho", own: true });
  expect(h.bots.byId("u-writer")).toBe(WRITER);
  expect(h.bots.byId("absent")).toBeNull();
  expect([h.bots.own(), REVIEWER, UNAVAILABLE, DRAFT, GROUP, null].map(h.bots.startable)).toEqual([true, true, true, false, false, false]);
  expect(h.bots.state.get().files).toBeUndefined();
});

test("adoption triggers discovery and an unavailable member plane leaves a readable state", async () => {
  const h = harness({ adopted: false });
  await flush();
  expect(h.requests).toEqual([]);
  h.handlers["GET /agents"] = () => { throw Object.assign(new Error("not yet"), { status: 409, code: "member_plane_unavailable" }); };
  h.setup.state.set({ daemon: { identity: { user_public_id: "u-rho" }, workspace: { state: "adopted" } } });
  await flush();
  expect(h.bots.state.get()).toMatchObject({ loaded: true, loading: false, bots: [] });
  expect(h.bots.state.get().error.code).toBe("member_plane_unavailable");
  h.controller.abort();
});

test("identity serialization carries a Preset reference and never copies its model or tools", () => {
  expect(bodyOf(policyOf(REVIEWER))).toEqual({ name: "reviewer", display_name: "Reviewer", description: "Reviews changes",
    audience: "owner", preset_public_id: "p-review", subagent: false, welcome_message: "Send me a change to review." });
  expect(bodyOf({ ...policyOf(null), name: " helper ", description: " Helps ", preset_public_id: "p-assistant" })).toEqual({
    name: "helper", display_name: null, description: "Helps", audience: "owner", preset_public_id: "p-assistant", subagent: true, welcome_message: null });
  const disabledWelcome = policyOf({ ...REVIEWER, welcome_message: "" });
  expect(disabledWelcome.welcome_mode).toBe("none");
  expect(bodyOf(disabledWelcome).welcome_message).toBe("");
  expect(bodyOf({ ...disabledWelcome, welcome_mode: "default" }).welcome_message).toBeNull();
  expect(["reviewer", "a1", "x".repeat(32), "code-reviewer_2"].every((name) => NAME_FORMAT.test(name))).toBe(true);
  expect(["Reviewer", "a", "x".repeat(33), "-lead", "with space"].some((name) => NAME_FORMAT.test(name))).toBe(false);
  expect(botDetail(WRITER)).toBe("Writes docs · Published by @alice");
});

test("the Bots list is separate from Main conversations and opens the Bot current owner", async () => {
  const p = pageHarness(); await flush();
  expect(p.view.element.querySelectorAll(".group__title").map((row) => row.textContent)).toEqual(["Bots5"]);
  expect(p.rows()).toHaveLength(5);
  expect(p.rows().some((row) => row.dataset.bot === "own")).toBe(false);
  const row = p.view.element.querySelector('[data-bot="reviewer"]');
  row.querySelector(".bots-page__actions button").click(); await flush();
  expect(p.requests.find((row) => row.path === "/bots/current").body.agent_public_id).toBe("u-reviewer");
  expect(p.calls).toContainEqual(["select", "c-current", { workspace: "w-home" }]);
  expect(p.calls.some((row) => row[0] === "startNew")).toBe(false);
  p.view.dispose();
});

test("creating a Bot selects the catalog default and saves its identity and delegation choice", async () => {
  const p = pageHarness();
  await flush();
  button(p.view.element, "New bot").click();
  expect(p.crumbs()).toEqual(["Bots", "New bot"]);
  const editor = p.editor();
  expect(editor.querySelectorAll(".field__label").map((row) => row.textContent)).toEqual(["Name", "Display name", "Description", "Purpose", "Agent Preset", "Introduction", "Welcome message"]);
  expect(control(editor, "preset_public_id").value).toBe("p-assistant");
  expect(control(editor, "subagent").checked).toBe(true);
  expect(control(editor, "subagent").getAttribute("role")).toBe("switch");
  expect(control(editor, "subagent").closest("label").textContent).toBe("Subagent");
  expect(editor.querySelector(`#${control(editor, "subagent").getAttribute("aria-describedby")}`).textContent).toContain("delegate");
  expect(control(editor, "code_mode")).toBeNull();
  control(editor, "name").value = "Bad Name";
  control(editor, "description").value = "Helps with work";
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(p.requests.some((row) => row.method === "PUT")).toBe(false);
  control(editor, "name").value = "helper";
  control(editor, "display_name").value = "Helper";
  control(editor, "welcome_mode").value = "custom";
  control(editor, "welcome_message").value = "Welcome. Tell me what you need.";
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(p.requests.find((row) => row.method === "PUT")).toEqual({ method: "PUT", path: "/agents", body: {
    name: "helper", display_name: "Helper", description: "Helps with work", audience: "owner", preset_public_id: "p-assistant", subagent: true, welcome_message: "Welcome. Tell me what you need.",
  } });
  expect(p.location().item).toBe("u-reviewer");
  expect(p.calls).toContainEqual(["toast", "Helper was created.", "success"]);
  p.view.dispose();
});

test("a new Bot keeps Subagent off after a failed save and submits the same choice on retry", async () => {
  const p = pageHarness();
  const save = p.handlers["PUT /agents"];
  p.handlers["PUT /agents"] = () => { throw new Error("Could not save the Bot"); };
  await flush();
  button(p.view.element, "New bot").click();
  const editor = p.editor();
  control(editor, "name").value = "helper";
  control(editor, "description").value = "Helps with work";
  control(editor, "subagent").click();
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(editor.textContent).toContain("Could not save the Bot");
  expect(editor.querySelector("fieldset").disabled).toBe(false);
  expect(control(editor, "subagent").checked).toBe(false);
  expect(p.requests.find((row) => row.method === "PUT").body.subagent).toBe(false);
  expect(p.location().item).toBe("new");
  p.handlers["PUT /agents"] = save;
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(p.requests.filter((row) => row.method === "PUT").map((row) => row.body.subagent)).toEqual([false, false]);
  expect(p.calls).toContainEqual(["toast", "helper was created.", "success"]);
  p.view.dispose();
});

test("editing keeps the Bot identity and opens its selected Preset for configuration", async () => {
  const p = pageHarness();
  await flush(); p.open();
  const editor = p.editor();
  expect(control(editor, "name").hasAttribute("readonly")).toBe(true);
  expect(control(editor, "preset_public_id").value).toBe("p-review");
  expect(control(editor, "subagent").checked).toBe(false);
  for (const name of ["model", "system_prompt", "tools", "prompt_template", "code_mode"]) expect(control(editor, name)).toBeNull();
  button(editor, "Edit selected Preset").click();
  expect(p.calls).toContainEqual(["settings", "presets", "p-review"]);
  control(editor, "description").value = "Reviews architecture";
  control(editor, "preset_public_id").value = "p-main";
  control(editor, "welcome_mode").value = "default";
  control(editor, "welcome_message").value = "";
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(p.requests.find((row) => row.method === "PUT").body).toEqual({ name: "reviewer", display_name: "Reviewer", description: "Reviews architecture",
    audience: "owner", preset_public_id: "p-main", subagent: false, welcome_message: null });
  expect(p.location().item).toBe(REVIEWER.public_id);
  expect(editor.querySelector("fieldset").disabled).toBe(false);
  p.handlers["PUT /agents"] = () => { throw new Error("Preset is unavailable"); };
  control(editor, "subagent").click();
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(editor.textContent).toContain("Preset is unavailable");
  expect(control(editor, "description").value).toBe("Reviews architecture");
  expect(control(editor, "subagent").checked).toBe(true);
  expect(p.requests.filter((row) => row.method === "PUT").map((row) => row.body.subagent)).toEqual([false, true]);
  p.handlers["PUT /agents"] = ({ body }) => {
    const saved = { ...REVIEWER, ...body };
    p.handlers["GET /agents"] = () => ({ bots: [saved] });
    return { agent: saved };
  };
  editor.querySelector("form").requestSubmit();
  await flush();
  button(editor, "Cancel").click();
  p.open();
  expect(control(p.editor(), "subagent").checked).toBe(true);
  p.view.dispose();
});

test("Preset refresh preserves the Bot draft and its chosen reference", async () => {
  const p = pageHarness();
  await flush(); p.open();
  const editor = p.editor();
  control(editor, "preset_public_id").value = "p-main";
  control(editor, "welcome_message").value = "Unsaved welcome";
  control(editor, "subagent").click();
  p.handlers["GET /presets"] = () => ({ ...CATALOG, presets: [...CATALOG.presets, { public_id: "p-new", name: "New Preset" }] });
  p.view.element.querySelector('.crumbs-row [aria-label="Refresh"]').click();
  await flush();
  expect(control(editor, "preset_public_id").options.map((row) => row.value)).toContain("p-new");
  expect(control(editor, "preset_public_id").value).toBe("p-main");
  expect(control(editor, "welcome_message").value).toBe("Unsaved welcome");
  expect(control(editor, "subagent").checked).toBe(true);
  p.view.dispose();
});

test("an early Bot form waits for Presets without losing its draft", async () => {
  const p = pageHarness();
  p.router.push({ item: "new" }, { notify: true });
  const editor = p.editor();
  control(editor, "name").value = "helper";
  control(editor, "subagent").click();
  expect(button(editor, "Create bot").disabled).toBe(true);
  await flush();
  expect(control(editor, "name").value).toBe("helper");
  expect(control(editor, "preset_public_id").value).toBe("p-assistant");
  expect(control(editor, "subagent").checked).toBe(false);
  expect(button(editor, "Create bot").disabled).toBe(false);
  p.view.dispose();
});

test("a missing selected Preset stays visible and requires an available replacement", async () => {
  const p = pageHarness({ bots: [{ ...REVIEWER, preset_public_id: "p-missing", preset_name: "Removed Preset" }] });
  await flush(); p.open();
  const editor = p.editor();
  expect(control(editor, "preset_public_id").value).toBe("p-missing");
  expect(editor.textContent).toContain("Removed Preset");
  expect(button(editor, "Edit selected Preset").disabled).toBe(true);
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(p.requests.some((row) => row.method === "PUT")).toBe(false);
  expect(editor.textContent).toContain("Choose an Agent Preset.");
  p.view.dispose();
});

test("purpose remains fixed after changing a personal Bot to external", async () => {
  const p = pageHarness({ bots: [REVIEWER] });
  await flush(); p.open();
  const editor = p.editor();
  const purpose = control(editor, "audience");
  purpose.value = "external";
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(p.requests.find((row) => row.method === "PUT").body.audience).toBe("external");
  expect(purpose.disabled).toBe(true);
  expect(editor.textContent).toContain("Duplicate this bot for personal use");
  button(p.view.element, "Duplicate").click();
  expect(control(document.querySelector("dialog"), "audience").value).toBe("external");
  p.view.dispose();
});

test("duplication sends a fresh name and purpose while the server copies the Preset reference", async () => {
  const original = { ...REVIEWER, audience: "external" };
  const created = { ...original, public_id: "u-copy", name: "reviewer-personal", display_name: "Personal reviewer", audience: "owner" };
  const p = pageHarness({ bots: [original] });
  p.handlers["POST /agents/duplicate"] = () => { p.handlers["GET /agents"] = () => ({ bots: [original, created] }); return { agent: created }; };
  await flush(); p.open();
  button(p.view.element, "Duplicate").click();
  const dialog = document.querySelector("dialog");
  expect(dialog.textContent).toContain("same Preset, Subagent choice and welcome message");
  control(dialog, "name").value = "reviewer-personal";
  control(dialog, "display_name").value = "Personal reviewer";
  control(dialog, "audience").value = "owner";
  dialog.querySelector("form").requestSubmit();
  await flush();
  expect(p.requests.find((row) => row.path === "/agents/duplicate").body).toEqual({ source_name: "reviewer", name: "reviewer-personal", display_name: "Personal reviewer", audience: "owner" });
  expect(p.location().item).toBe("u-copy");
  expect(control(p.editor(), "preset_public_id").value).toBe("p-review");
  expect(control(p.editor(), "subagent").checked).toBe(false);
  expect(document.querySelector("dialog")).toBeNull();
  p.view.dispose();
});

test("closing a duplicate dialog during save does not navigate when it finishes", async () => {
  const p = pageHarness();
  let complete;
  p.handlers["POST /agents/duplicate"] = () => new Promise((resolve) => { complete = resolve; });
  await flush(); p.open(); button(p.view.element, "Duplicate").click();
  const dialog = document.querySelector("dialog");
  control(dialog, "name").value = "reviewer-copy";
  dialog.querySelector("form").requestSubmit(); dialog.querySelector("form").requestSubmit();
  expect(p.requests.filter((row) => row.path === "/agents/duplicate")).toHaveLength(1);
  button(dialog, "Cancel").click();
  complete({ agent: { ...REVIEWER, public_id: "u-copy", name: "reviewer-copy" } });
  await flush();
  expect(p.location().item).toBe("u-reviewer");
  p.view.dispose();
});

test("Bot removal remains confirmed, preserves the Preset and returns to the list", async () => {
  const p = pageHarness();
  await flush(); p.open();
  const removal = p.view.element.querySelector(".bots-page__removal");
  expect(removal.textContent).toContain("Its Agent Preset remains available.");
  button(removal, "Remove").click();
  const dialog = document.querySelector("dialog");
  expect(dialog.querySelector(".modal__title").textContent).toBe("Remove Reviewer?");
  button(dialog, "Remove").click();
  await flush();
  expect(p.requests.find((row) => row.path === "/agents/rm").body).toEqual({ name: "reviewer" });
  expect(p.location().item).toBeNull();
  expect(document.querySelector("dialog")).toBeNull();
  p.view.dispose();
});

test("Bot routes retain identity, back navigation and names that match reserved page words", async () => {
  const definitions = ["rho", "new"].map((name) => ({ ...REVIEWER, public_id: `bot-${name}`, name, display_name: `Bot ${name}` }));
  const p = pageHarness({ bots: definitions });
  await flush();
  for (const bot of definitions) {
    p.open(bot.name);
    expect(p.location().item).toBe(bot.public_id);
    expect(control(p.editor(), "name").value).toBe(bot.name);
    p.view.element.querySelector(".crumbs .link-button").click();
    expect(p.location().item).toBeNull();
    p.router.pop({ item: bot.public_id });
    button(p.editor(), "Cancel").click();
    expect(p.location().item).toBeNull();
  }
  p.view.dispose();
});

test("an early identity route resolves after discovery and an unknown identity offers Back", async () => {
  const p = pageHarness();
  p.router.push({ item: "u-reviewer" }, { notify: true });
  expect(p.view.element.textContent).toContain("This bot is unavailable.");
  await flush();
  expect(p.editor()).not.toBeNull();
  p.router.pop({ item: "missing" });
  expect(p.view.element.textContent).toContain("This bot is unavailable.");
  button(p.view.element, "Back").click();
  expect(p.location().item).toBeNull();
  p.view.dispose();
});

test("empty Bots and catalog errors are actionable without offering the retired import flow", async () => {
  const p = pageHarness({ bots: [] });
  await flush();
  expect(p.view.element.textContent).toContain("No bots yet. Create one and choose its Agent Preset.");
  p.handlers["GET /presets"] = () => { throw new Error("Preset catalog is unavailable"); };
  p.view.element.querySelector('[aria-label="Refresh"]').click();
  await flush();
  expect(p.view.element.textContent).toContain("Preset catalog is unavailable");
  expect(p.view.element.textContent).not.toContain("Import");
  p.view.dispose();
});
