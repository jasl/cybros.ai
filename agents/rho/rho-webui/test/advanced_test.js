import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { advancedSection, editedSetting } from "../webui/features/settings/advanced.js";
import { kernelToolRows, kernelToolSelection, firstSentence } from "../webui/features/settings/kernel_tools.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const CATALOG = [
  { canonical_name: "nexus.memory.read", name: "memory_read", description: "Read a memory document. Paths are literal.", effect_profile: {} },
  { canonical_name: "nexus.memory.write", name: "memory_write", description: "Write a memory document.", effect_profile: {} },
  { canonical_name: "nexus.graph.delegate_task", name: "delegate_task", description: "Delegate.", effect_profile: {} },
  { canonical_name: "nexus.future.verb", name: "future_verb", description: "Does a new thing. Carefully.", effect_profile: {} },
];
const ROWS = [{ id: "default", source: "gem", default: true }, { id: "glm-5.3", source: "gem", default: false }, { id: "mock", source: "local", default: false }];
const MODELS = [{ ref: "dev/mock-text", display_name: "Mock" }, { ref: "dev/other" }];
const TITLE_MODELS = [{ ref: "dev/title", display_name: "Title", available: true, capabilities: { tool_calls: false } },
  { ref: "dev/mock-text", display_name: "Mock", available: true, capabilities: { tool_calls: true } },
  { ref: "dev/unavailable", available: false, capabilities: { tool_calls: false } }];

const saved = (settings = {}) => ({ settings: { default_model: "local/fallback", fallback_models: ["dev/other"], adaptations: "auto", adaptations_dir: null, kernel_tools: ["nexus.memory.read"],
  runner: "runner-gone", workspace: null, tools_root: "/work", nexus_public_url: "https://nexus.example", subagent_default: true, conversation_title_model: "follow_current", ...settings } });

function advanced({ document = saved(), connected = true, save = async () => null, catalog = CATALOG, eligible = MODELS, titleModels = TITLE_MODELS } = {}) {
  const requests = [];
  const shell = { call: async (path) => {
    requests.push(path);
    if (path === "/runners") return { runners: [{ public_id: "runner-own", display_name: "Laptop" }] };
    if (path === "/workspaces") return { workspaces: [{ public_id: "w-1", name: "Home" }] };
    if (path === "/adaptations/rows") return { knob: "auto", rows: ROWS };
    if (path === "/kernel_tools") { if (!catalog) throw new Error("kernel unavailable"); return { tools: catalog }; }
    if (path === "/models?workload=text_generation") { if (!titleModels) throw new Error("models unavailable"); return { models: titleModels }; }
    throw new Error(`unexpected ${path}`);
  } };
  let props = { document, status: { connected, model: { eligible } }, save };
  const view = advancedSection(shell, props);
  globalThis.document.body.append(view.element);
  return { view, requests, element: view.element, update: (changes) => { props = { ...props, ...changes }; view.update(props); } };
}
const named = (root, name) => root.querySelector(`[name="${name}"]`);
const options = (box) => box.options.map((option) => option.textContent);
const edit = (input, value) => { input.value = value; input.dispatchEvent(new Event("input")); };
const choose = (box, value) => { box.value = value; box.dispatchEvent(new Event("change")); };
const toggle = (root, tool) => { const box = root.querySelector(`[name="kernel_tools"][value="${tool}"]`); box.checked = !box.checked; box.dispatchEvent(new Event("change")); };
const submit = async (input) => { input.closest("form").dispatchEvent(new Event("submit")); await flush(); };
const toolRows = (root) => root.querySelectorAll(".toolset__row").map((row) => row.dataset.tool);

test("a blank text field clears its setting and a blank adaptation choice is automatic", () => {
  expect(editedSetting("text", "   ")).toBeNull();
  expect(editedSetting("runner", "")).toBeNull();
  expect(editedSetting("model", "")).toBeNull();
  expect(editedSetting("adaptation", "")).toBe("auto");
  expect(editedSetting("adaptation", "off")).toBe("off");
  expect(editedSetting("text", " /work ")).toBe("/work");
});

test("the Subagent default saves a boolean for new Main Agent conversations and preserves unsaved edits on refresh", async () => {
  const saves = [];
  const a = advanced({ save: async (changes) => { saves.push(changes); return saved(changes); } });
  await flush();
  const box = named(a.element, "subagent_default");
  expect(box.checked).toBe(true);
  expect(box.closest(".field").textContent).toContain("new Main Agent conversations");
  expect(box.closest(".field").textContent).toContain("Each Bot has its own Subagent setting.");
  box.checked = false;
  box.dispatchEvent(new Event("change"));
  a.update({ document: saved({ subagent_default: true }) });
  expect(box.checked).toBe(false);
  await submit(box);
  expect(saves).toEqual([{ subagent_default: false }]);
  expect(box.checked).toBe(false);
  a.view.dispose();
});

test("the title model defaults to the current model and offers usable text models without requiring tools", async () => {
  const a = advanced();
  await flush();
  const box = named(a.element, "conversation_title_model");
  expect(box.tagName).toBe("SELECT");
  expect(box.value).toBe("follow_current");
  expect(options(box)).toEqual(["None", "Follow current model", "Title · dev/title", "Mock · dev/mock-text"]);
  expect(a.element.querySelectorAll('[name="conversation_title_model"]')).toHaveLength(1);
  expect(box.closest(".field").textContent).toContain("first message");
  a.view.dispose();
});

test("the title model saves None, a chosen model and follow-current as distinct settings without rewriting defaults", async () => {
  const saves = [];
  let current = {};
  const a = advanced({ save: async (changes) => { saves.push(changes); current = { ...current, ...changes }; return saved(current); } });
  await flush();
  const box = named(a.element, "conversation_title_model");
  for (const [choice, value] of [["", null], ["dev/title", "dev/title"], ["follow_current", "follow_current"]]) {
    choose(box, choice);
    await submit(box);
    expect(saves.at(-1)).toEqual({ conversation_title_model: value });
    expect(box.value).toBe(choice);
    a.update({ document: saved(current) });
    expect(box.value).toBe(choice);
  }
  choose(box, "follow_current");
  await submit(box);
  expect(saves).toHaveLength(3);
  a.view.dispose();
});

test("a saved unavailable title model is retained when the catalog fails, and a refused change keeps its draft", async () => {
  const a = advanced({ document: saved({ conversation_title_model: "retired/title" }), titleModels: null,
    save: async () => { throw new Error("Title model is unavailable"); } });
  await flush();
  const box = named(a.element, "conversation_title_model");
  expect(options(box)).toEqual(["None", "Follow current model", "retired/title · currently unavailable"]);
  expect(box.value).toBe("retired/title");
  choose(box, "");
  a.update({ document: saved({ conversation_title_model: "retired/title" }) });
  await submit(box);
  expect(box.value).toBe("");
  expect(a.element.querySelectorAll(".alert--error").map((node) => node.textContent)).toEqual(["Title model is unavailable"]);
  a.view.dispose();
});

test("a title model catalog arriving after an edit keeps the choice and adds the usable options", async () => {
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  const shell = { call: async (path) => {
    if (path === "/models?workload=text_generation") { await pending; return { models: TITLE_MODELS }; }
    return {};
  } };
  const view = advancedSection(shell, { document: saved(), status: { connected: true, model: { eligible: MODELS } }, save: async () => null });
  const box = named(view.element, "conversation_title_model");
  choose(box, "");
  release();
  await flush();
  expect(box.value).toBe("");
  expect(options(box)).toEqual(["None", "Follow current model", "Title · dev/title", "Mock · dev/mock-text"]);
  view.dispose();
});

test("a fresh settings status reloads title model availability without replacing an unsaved choice", async () => {
  const models = [...TITLE_MODELS];
  const a = advanced({ titleModels: models });
  await flush();
  const box = named(a.element, "conversation_title_model");
  choose(box, "dev/title");
  models.splice(0, 1, { ref: "dev/other-title", display_name: "Other title", available: true });
  a.update({ status: { connected: true, model: { eligible: MODELS } } });
  await flush();
  expect(box.value).toBe("dev/title");
  expect(options(box)).toEqual(["None", "Follow current model", "Other title · dev/other-title", "Mock · dev/mock-text", "dev/title · currently unavailable"]);
  a.view.dispose();
});

test("the tool selection keeps the saved order for kept names and appends new ones in catalog order", () => {
  const checked = new Set(["nexus.memory.read", "nexus.graph.delegate_task", "nexus.future.verb"]);
  expect(kernelToolSelection(["nexus.graph.delegate_task", "nexus.memory.read"], CATALOG, checked))
    .toEqual(["nexus.graph.delegate_task", "nexus.memory.read", "nexus.future.verb"]);
  expect(kernelToolSelection(["nexus.memory.read"], CATALOG, new Set(["nexus.memory.read"]))).toEqual(["nexus.memory.read"]);
  expect(kernelToolSelection(["nexus.memory.read"], CATALOG, new Set())).toEqual([]);
  expect(firstSentence("Read a memory document. Paths are literal.")).toBe("Read a memory document.");
  expect(firstSentence("")).toBe("");
});

test("tool rows group the catalog with known groups first and flag saved names the kernel no longer serves", () => {
  const rows = kernelToolRows(["nexus.memory.read", "nexus.retired.verb"], CATALOG);
  expect(rows.map(({ group, tools }) => [group, tools.map((tool) => tool.canonical_name)])).toEqual([
    ["graph", ["nexus.graph.delegate_task"]],
    ["memory", ["nexus.memory.read", "nexus.memory.write"]],
    ["future", ["nexus.future.verb"]],
    ["retired", ["nexus.retired.verb"]],
  ]);
  expect(rows.at(-1).tools[0].unavailable).toBe(true);
  // Without a catalog the saved names are the rows, not flagged: nothing is known about them.
  expect(kernelToolRows(["nexus.memory.read"], null)).toEqual([{ group: "memory", tools: [{ canonical_name: "nexus.memory.read", name: null, description: "", unavailable: false }] }]);
});

test("the Nexus tools card lists the kernel's catalog as switches with the saved names on", async () => {
  const a = advanced({ document: saved({ kernel_tools: ["nexus.memory.read", "nexus.retired.verb"] }) });
  await flush();
  expect(a.requests).toEqual(["/adaptations/rows", "/runners", "/workspaces", "/kernel_tools", "/models?workload=text_generation"]);
  expect(toolRows(a.element)).toEqual(["nexus.graph.delegate_task", "nexus.memory.read", "nexus.memory.write", "nexus.future.verb", "nexus.retired.verb"]);
  const on = a.element.querySelectorAll('[name="kernel_tools"]').filter((box) => box.checked).map((box) => box.value);
  expect(on).toEqual(["nexus.memory.read", "nexus.retired.verb"]);
  const read = a.element.querySelector('[data-tool="nexus.memory.read"]');
  expect(read.querySelector(".settings-row__label").textContent).toBe("Read memorymemory_read");
  expect(read.querySelector(".settings-row__description").textContent).toBe("Read a memory document.");
  expect(read.querySelector('[role="switch"]').getAttribute("aria-label")).toBe("Read memory");
  const future = a.element.querySelector('[data-tool="nexus.future.verb"]');
  expect(future.querySelector(".settings-row__label").textContent).toBe("future_verbfuture_verb");
  expect(future.querySelector(".settings-row__description").textContent).toBe("Does a new thing.");
  const retired = a.element.querySelector('[data-tool="nexus.retired.verb"]');
  expect(retired.querySelector(".tag--warning").textContent).toBe("not served");
  expect(retired.querySelector(".settings-row__description").textContent).toContain("new runs get no Nexus tools at all");
  expect(a.element.querySelectorAll(".toolset__title").map((node) => node.textContent)).toEqual(["Delegation", "Memory", "future", "retired"]);
});

test("switching tools saves the list in saved-then-catalog order, and an untouched list is not written", async () => {
  const saves = [];
  let current = { kernel_tools: ["nexus.memory.write", "nexus.memory.read"] };
  const a = advanced({ document: saved(current), save: async (changes) => { saves.push(changes); current = { ...current, ...changes }; return saved(current); } });
  await flush();
  toggle(a.element, "nexus.graph.delegate_task");
  toggle(a.element, "nexus.memory.write");
  await submit(a.element.querySelector('[name="kernel_tools"]'));
  expect(saves).toEqual([{ kernel_tools: ["nexus.memory.read", "nexus.graph.delegate_task"] }]);
  a.update({ document: saved(current) });
  const on = a.element.querySelectorAll('[name="kernel_tools"]').filter((box) => box.checked).map((box) => box.value);
  expect(on).toEqual(["nexus.graph.delegate_task", "nexus.memory.read"]);
  toggle(a.element, "nexus.memory.write");
  toggle(a.element, "nexus.memory.write");
  await submit(a.element.querySelector('[name="kernel_tools"]'));
  expect(saves).toHaveLength(1);
});

test("without the catalog the saved names stay switchable and the card says why the list is short", async () => {
  const a = advanced({ catalog: null, document: saved({ kernel_tools: ["nexus.memory.read", "nexus.memory.write"] }) });
  await flush();
  expect(toolRows(a.element)).toEqual(["nexus.memory.read", "nexus.memory.write"]);
  expect(a.element.querySelector(".toolset .field__hint").textContent).toContain("tool catalog is unavailable");
  expect(a.element.querySelectorAll(".tag--warning")).toHaveLength(0);
  const saves = [];
  a.update({ save: async (changes) => { saves.push(changes); return saved(changes); } });
  toggle(a.element, "nexus.memory.write");
  await submit(a.element.querySelector('[name="kernel_tools"]'));
  expect(saves).toEqual([{ kernel_tools: ["nexus.memory.read"] }]);
});

test("a catalog that arrives after a switch was flipped repaints around the edit", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const requests = [];
  const shell = { call: async (path) => {
    requests.push(path);
    if (path === "/kernel_tools") { await gate; return { tools: CATALOG }; }
    if (path === "/adaptations/rows") return { rows: ROWS };
    return { runners: [], workspaces: [] };
  } };
  const view = advancedSection(shell, { document: saved(), status: { connected: true, model: { eligible: [] } }, save: async () => null });
  globalThis.document.body.append(view.element);
  await flush();
  expect(view.element.querySelector(".toolset .field__hint").textContent).toBe("Loading available tools…");
  toggle(view.element, "nexus.memory.read");
  release();
  await flush();
  expect(toolRows(view.element)).toEqual(["nexus.graph.delegate_task", "nexus.memory.read", "nexus.memory.write", "nexus.future.verb"]);
  expect(view.element.querySelector('[name="kernel_tools"][value="nexus.memory.read"]').checked).toBe(false);
  expect(view.element.querySelector(".toolset .field__hint").hidden).toBe(true);
});

test("the initial model and the adaptation row are chosen from what exists, keeping an unavailable saved value", async () => {
  const a = advanced({ document: saved({ default_model: "gone/model", adaptations: "vanished" }) });
  await flush();
  const fallback = named(a.element, "default_model");
  expect(options(fallback)).toEqual(["Choose a model", "Mock · dev/mock-text", "dev/other", "gone/model · unavailable"]);
  expect(fallback.value).toBe("gone/model");
  const adaptations = named(a.element, "adaptations");
  expect(options(adaptations)).toEqual(["Automatic · match the default model", "Off · standard tool names and instructions", "default · gem", "glm-5.3 · gem", "mock · local",
    "vanished · currently unavailable"]);
  expect(adaptations.value).toBe("vanished");
  a.update({ document: saved({ default_model: null, adaptations: "off" }) });
  expect(fallback.value).toBe("");
  expect(adaptations.value).toBe("off");
  expect(options(adaptations)).toHaveLength(5);
});

test("each group saves only the fields it changed, compared with the saved document", async () => {
  const saves = [];
  let current = {};
  const a = advanced({ save: async (changes) => { saves.push(changes); current = { ...current, ...changes }; return saved(current); } });
  await flush();
  choose(named(a.element, "default_model"), "local/fallback");
  choose(named(a.element, "adaptations"), "mock");
  edit(named(a.element, "tools_root"), "/elsewhere");
  await submit(named(a.element, "default_model"));
  expect(saves).toEqual([{ adaptations: "mock" }]);
  a.update({ document: saved(current) });
  expect(named(a.element, "tools_root").value).toBe("/elsewhere");
  await submit(named(a.element, "tools_root"));
  expect(saves[1]).toEqual({ tools_root: "/elsewhere" });
  a.update({ document: saved(current) });
  choose(named(a.element, "adaptations"), "");
  choose(named(a.element, "default_model"), "");
  await submit(named(a.element, "default_model"));
  expect(saves[2]).toEqual({ default_model: null, adaptations: "auto" });
});

test("runner and workspace choices come from the member plane and keep an unavailable saved value", async () => {
  const a = advanced();
  await flush();
  const runner = named(a.element, "runner");
  expect(options(runner)).toEqual(["Automatic · rho's own runner", "Laptop", "runner-gone · currently unavailable"]);
  expect(runner.value).toBe("runner-gone");
  expect(options(named(a.element, "workspace"))).toEqual(["Automatic · rho's workspace", "Home"]);
});

test("member-plane choices load once rho connects, and refreshes repaint only untouched fields", async () => {
  const a = advanced({ connected: false, eligible: [] });
  await flush();
  expect(a.requests).toEqual(["/adaptations/rows"]);
  expect(options(named(a.element, "adaptations"))).toHaveLength(5);
  expect(options(named(a.element, "default_model"))).toEqual(["Choose a model", "local/fallback · unavailable"]);
  edit(named(a.element, "tools_root"), "/typed");
  a.update({ document: saved({ tools_root: "/remote", adaptations: "off" }), status: { connected: true, model: { eligible: MODELS } } });
  await flush();
  expect(a.requests).toEqual(["/adaptations/rows", "/adaptations/rows", "/runners", "/workspaces", "/kernel_tools", "/models?workload=text_generation"]);
  expect(named(a.element, "tools_root").value).toBe("/typed");
  expect(named(a.element, "adaptations").value).toBe("off");
  expect(options(named(a.element, "default_model"))).toEqual(["Choose a model", "Mock · dev/mock-text", "dev/other", "local/fallback · unavailable"]);
});

test("a refused save keeps the group's edits and says why", async () => {
  const a = advanced({ save: async () => { throw new Error("nexus_public_url must be an http(s) URL"); } });
  edit(named(a.element, "nexus_public_url"), "ftp://nexus");
  await submit(named(a.element, "nexus_public_url"));
  expect(named(a.element, "nexus_public_url").value).toBe("ftp://nexus");
  expect(a.element.querySelectorAll(".alert--error").map((node) => node.textContent)).toEqual(["nexus_public_url must be an http(s) URL"]);
});


test("default model options refresh around an unsaved choice, including newly enabled and removed models", async () => {
  const saves = [];
  const a = advanced({ save: async (changes) => { saves.push(changes); return saved(changes); } });
  await flush();
  const box = named(a.element, "default_model");
  choose(box, "dev/other");
  const eligible = [{ ref: "dev/new" }];
  a.update({ status: { connected: true, model: { eligible } } });
  expect(box.value).toBe("dev/other");
  expect(options(box)).toEqual(["Choose a model", "dev/new", "dev/other · unavailable"]);
  eligible.push({ ref: "dev/other" });
  a.update({ status: { connected: true, model: { eligible } } });
  expect(options(box)).toEqual(["Choose a model", "dev/new", "dev/other"]);
  expect(saves).toEqual([]);
  choose(box, "dev/new");
  await submit(box);
  expect(saves).toEqual([{ default_model: "dev/new" }]);
  a.view.dispose();
});
