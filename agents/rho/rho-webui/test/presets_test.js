import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush, type } from "./support/dom.js";
import { orderedModels } from "../webui/features/settings/model_choices.js";
import { presetsSection } from "../webui/features/settings/presets.js";
import { advancedSection } from "../webui/features/settings/advanced.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());
const MODELS = [{ ref: "dev/first", display_name: "First" }, { ref: "dev/second" }, { ref: "dev/third" }];
const TOOLS = [{ name: "delegate_task", kind: "kernel" }, { name: "mcp__research__search", kind: "agent" }, { name: "read", kind: "runner" }, { name: "bash", kind: "runner" }];
const PRESETS = [
  { public_id: "preset-main", name: "Probius", description: "General work", configuration: { system_prompt: "Be useful.", model: null,
    model_mode: "default", fallback_models: null, tools: null, runner_tool_names: null, approval_mode: "ask", prompt_template: { before: ["custom"] } }, role: null },
  { public_id: "preset-bot", name: "Adjutant", description: "Bot behavior", configuration: {}, role: null },
  { public_id: "preset-review", name: "Reviewer", description: "Review changes", configuration: { model_mode: "follow", fallback_models: [], tools: [], runner_tool_names: ["read"] },
    role: { name: "reviewer", description: "Review the change" } },
];
const named = (root, name) => root.querySelector(`[name="${name}"]`);
const button = (root, text) => [...root.querySelectorAll("button")].find((node) => node.textContent === text);
const submit = async (root) => { root.querySelector("form").requestSubmit(); await flush(); };

function harness({ fail = null, request = null } = {}) {
  let catalog = { presets: structuredClone(PRESETS), main_preset_public_id: "preset-main", default_bot_preset_public_id: "preset-bot" };
  const requests = [];
  const calls = [];
  const shell = { toast: (text) => calls.push(text), settings: { open: (...args) => calls.push(args) }, bots: { refresh: async () => {} }, call: async (path, options = {}) => {
    const method = options.method || "GET";
    const body = options.body;
    requests.push({ path, method, body });
    const failure = fail?.(path, method, body);
    if (failure) throw new Error(failure);
    if (path === "/presets/tools") return { tools: TOOLS };
    if (path.startsWith("/presets/export?")) {
      const query = new URLSearchParams(path.split("?")[1]);
      const row = catalog.presets.find((row) => row.public_id === query.get("public_id"));
      return { name: row.name, format: query.get("format"), content: JSON.stringify({ name: row.name, description: row.description, configuration: row.configuration }) };
    }
    if (method === "GET") return structuredClone(catalog);
    let preset = catalog.presets.find((row) => row.public_id === body.public_id);
    if (path === "/presets/defaults") Object.assign(catalog, body);
    else if (path === "/presets/rm") catalog.presets = catalog.presets.filter((row) => row !== preset);
    else if (path === "/presets/role") preset.role = method === "DELETE" ? null : { name: body.name, description: body.description };
    else if (path === "/presets/duplicate") {
      preset = { ...structuredClone(preset), public_id: "preset-copy", name: body.name, role: null };
      catalog.presets.push(preset);
    } else if (path === "/presets/import_document") {
      preset = { public_id: "preset-imported", ...JSON.parse(body.content), role: null };
      if (body.name) preset.name = body.name;
      catalog.presets.push(preset);
    } else if (path === "/presets/import") {
      return { ...structuredClone(catalog), imported: [], skipped: [{ path: "/work/.agents/agents/review.md", reason: "Unsupported Preset fields: audience" }], missing: [] };
    } else if (method === "POST") {
      preset = { public_id: "preset-new", ...body, role: null }; catalog.presets.push(preset);
    } else Object.assign(preset, body);
    return structuredClone({ ...catalog, preset });
  } };
  let props = { status: { connected: true, model: { eligible: MODELS } }, visible: true, request, refresh: async () => {} };
  const view = presetsSection(shell, props);
  document.body.append(view.element);
  const open = (id) => view.element.querySelector(`[data-preset="${id}"] .preset-catalog__name`).click();
  return { view, requests, calls, open, update(changes) { props = { ...props, ...changes }; view.update(props); },
    writes: () => requests.filter((request) => request.method !== "GET") };
}

test("ordered fallbacks distinguish inherited, disabled and full overrides, preserve unavailable refs and never insert the initial model", () => {
  const changes = [];
  const picker = orderedModels({ value: null, models: MODELS, inherit: true, onChange: () => changes.push(picker.read()) });
  document.body.append(picker.element);
  const mode = named(picker.element, "fallback_models_mode");
  expect(picker.read()).toBeNull();
  type(mode, "off"); expect(picker.read()).toEqual([]);
  type(mode, "custom");
  const add = (model) => { type(named(picker.element, "fallback_model_add"), model); button(picker.element, "Add model").click(); };
  add("dev/second"); add("dev/third");
  expect(picker.read()).toEqual(["dev/second", "dev/third"]);
  picker.element.querySelector('[data-model="dev/third"] [data-move="up"]').click();
  expect(picker.read()).toEqual(["dev/third", "dev/second"]);
  expect(named(picker.element, "fallback_model_add").options.map((row) => row.value)).toEqual(["", "dev/first"]);
  picker.update([MODELS[0]]);
  expect(picker.read()).toEqual(["dev/third", "dev/second"]);
  expect(picker.element.textContent).toContain("dev/third · unavailable");
  type(mode, "inherit"); expect(picker.read()).toBeNull();
  type(mode, "custom"); expect(picker.read()).toEqual(["dev/third", "dev/second"]);
  button(picker.element.querySelector('[data-model="dev/third"]'), "Remove").click();
  expect(picker.read()).toEqual(["dev/second"]);
  expect(changes.length).toBeGreaterThan(5);
});

test("global defaults save an ordered fallback list independently from the initial model", async () => {
  const writes = [];
  let current = { default_model: "dev/first", fallback_models: ["dev/second", "dev/third"] };
  const props = { document: { settings: current }, status: { connected: false, model: { eligible: MODELS } }, save: async (body) => {
    writes.push(body); current = { ...current, ...body }; return { settings: current };
  } };
  const view = advancedSection({ call: async () => ({ rows: [] }) }, props);
  document.body.append(view.element);
  view.element.querySelector('[data-model="dev/third"] [data-move="up"]').click();
  await submit(view.element);
  expect(writes).toEqual([{ fallback_models: ["dev/third", "dev/second"] }]);
  type(named(view.element, "fallback_models_mode"), "off");
  await submit(view.element);
  expect(writes[1]).toEqual({ fallback_models: [] });
  expect(named(view.element, "default_model").value).toBe("dev/first");
  view.dispose();
});

test("Preset defaults save UUID references and editing preserves configuration outside the form", async () => {
  const h = harness(); await flush();
  expect(h.view.element.querySelectorAll("[data-preset]")).toHaveLength(3);
  type(named(h.view.element, "main_preset_public_id"), "preset-review");
  await submit(h.view.element);
  expect(h.writes()[0]).toEqual({ path: "/presets/defaults", method: "PUT", body: { main_preset_public_id: "preset-review" } });
  h.open("preset-main");
  const editor = h.view.element.querySelector(".preset-editor");
  type(named(editor, "preset_name"), "Cowork");
  type(named(editor, "system_prompt"), "Check your work.");
  type(named(editor, "model"), "dev/second");
  editor.requestSubmit(); await flush();
  expect(h.writes()[1].body).toEqual({ public_id: "preset-main", name: "Cowork", description: "General work", configuration: {
    system_prompt: "Check your work.", model: "dev/second", model_mode: "default", fallback_models: null, tools: null, runner_tool_names: null,
    approval_mode: "ask", prompt_template: { before: ["custom"] },
  } });
  expect(h.view.element.querySelector('[data-preset="preset-main"]').textContent).toContain("Cowork");
  h.view.dispose();
});

test("saving a Preset preserves empty permissions separately from selected Runner tools and retains a draft through refresh", async () => {
  const h = harness(); await flush(); h.open("preset-review");
  const editor = h.view.element.querySelector(".preset-editor");
  type(named(editor, "preset_description"), "Unsaved review notes");
  type(named(editor, "fallback_models_mode"), "inherit");
  h.update({ visible: false }); h.update({ visible: true }); await flush();
  expect(named(editor, "preset_description").value).toBe("Unsaved review notes");
  editor.requestSubmit(); await flush();
  expect(h.writes()[0].body.configuration).toMatchObject({ model_mode: "follow", model: null, fallback_models: null, tools: [], runner_tool_names: ["read"] });
  expect(h.writes()[0].body.description).toBe("Unsaved review notes");
  h.view.dispose();
});

test("Preset application callables can be selected independently from Runner tools and survive refresh", async () => {
  const h = harness(); await flush(); h.open("preset-review");
  const editor = h.view.element.querySelector(".preset-editor");
  expect(editor.textContent).toContain("Nexus and application tools");
  const callable = editor.querySelector('[name="preset_tools"][value="mcp__research__search"]');
  expect(callable).not.toBeNull();
  callable.checked = true;
  callable.dispatchEvent(new Event("change", { bubbles: true }));
  h.update({ visible: false }); h.update({ visible: true }); await flush();
  expect(editor.querySelector('[name="preset_tools"][value="mcp__research__search"]').checked).toBe(true);
  editor.requestSubmit(); await flush();
  expect(h.writes()[0].body.configuration).toMatchObject({ tools: ["mcp__research__search"], runner_tool_names: ["read"] });
  h.view.dispose();
});

test("Preset creation, duplication and removal use catalog operations without creating Bot identities", async () => {
  const h = harness(); await flush(); button(h.view.element, "New Preset").click();
  let editor = h.view.element.querySelector(".preset-editor");
  type(named(editor, "preset_name"), "Writer"); type(named(editor, "preset_description"), "Write drafts");
  editor.requestSubmit(); await flush();
  expect(h.writes()[0].path).toBe("/presets"); expect(h.writes()[0].method).toBe("POST");
  button(h.view.element.querySelector('[data-preset="preset-review"]'), "Duplicate").click();
  let dialog = document.querySelector("dialog");
  type(named(dialog, "duplicate_name"), "Second reviewer"); button(dialog, "Duplicate").click(); await flush();
  expect(h.writes()[1]).toEqual({ path: "/presets/duplicate", method: "POST", body: { public_id: "preset-review", name: "Second reviewer" } });
  expect(named(h.view.element, "role_name")).toBeNull();
  expect(button(h.view.element.querySelector('[data-preset="preset-main"]'), "Remove").disabled).toBe(true);
  button(h.view.element.querySelector('[data-preset="preset-copy"]'), "Remove").click();
  dialog = document.querySelector("dialog"); button(dialog, "Remove").click(); await flush();
  expect(h.writes()[2]).toEqual({ path: "/presets/rm", method: "POST", body: { public_id: "preset-copy" } });
  expect(h.view.element.querySelector('[data-preset="preset-copy"]')).toBeNull();
  h.view.dispose();
});

test("a Preset links to its role manager without a second role editor", async () => {
  const h = harness(); await flush(); h.open("preset-review");
  expect(h.view.element.textContent).toContain("Published as reviewer");
  expect(named(h.view.element, "role_name")).toBeNull();
  button(h.view.element, "Manage Subagent role").click();
  expect(h.calls).toEqual([["roles", "preset-review"]]);
  h.open("preset-main");
  button(h.view.element, "Manage Subagent role").click();
  expect(h.calls.at(-1)).toEqual(["roles", "preset-main"]);
  expect(h.writes()).toEqual([]);
  h.view.dispose();
});

test("a rejected Preset save preserves edits and remains retryable; catalog failure offers Refresh", async () => {
  let rejected = true;
  const h = harness({ fail: (path, method) => path === "/presets" && method === "PUT" && rejected ? "Preset name already exists" : null });
  await flush(); h.open("preset-main");
  const editor = h.view.element.querySelector(".preset-editor");
  type(named(editor, "preset_name"), "Keep my draft"); editor.requestSubmit(); await flush();
  expect(editor.querySelector(".alert__text").textContent).toBe("Preset name already exists");
  expect(named(editor, "preset_name").value).toBe("Keep my draft");
  expect(editor.querySelector("fieldset").disabled).toBe(false);
  rejected = false; editor.requestSubmit(); await flush();
  expect(h.writes()).toHaveLength(2); h.view.dispose();
  const down = harness({ fail: (path) => path === "/presets" ? "Nexus unavailable" : null }); await flush();
  expect(down.view.element.querySelector(".alert__text").textContent).toBe("Nexus unavailable");
  expect(button(down.view.element, "Refresh").disabled).toBe(false);
  expect(button(down.view.element, "New Preset").disabled).toBe(true); down.view.dispose();
});

test("a selected Preset request opens after catalog loading and can change within the same settings section", async () => {
  const h = harness({ request: { section: "presets", item: "preset-review" } });
  await flush();
  expect(named(h.view.element.querySelector(".preset-editor"), "preset_name").value).toBe("Reviewer");
  h.update({ request: { section: "presets", item: "preset-bot" } });
  expect(named(h.view.element.querySelector(".preset-editor"), "preset_name").value).toBe("Adjutant");
  h.update({ request: { section: "presets", item: null } });
  expect(h.view.element.querySelector(".preset-editor")).toBeNull();
  h.view.dispose();
});

test("Preset document import keeps rejected drafts editable and creates configuration through the Preset door", async () => {
  let reject = true;
  const h = harness({ fail: (path) => path === "/presets/import_document" && reject ? "Document is invalid" : null });
  await flush();
  button(h.view.element, "Import Preset").click();
  const dialog = document.querySelector("dialog");
  const file = named(dialog, "preset_file");
  const content = JSON.stringify({ name: "Review", description: "Checks work", configuration: { fallback_models: [], tools: [] } });
  file.files = [{ name: "review.json", text: async () => content }]; file.value = "review.json";
  file.dispatchEvent(new Event("change")); await flush();
  await submit(dialog);
  expect(dialog.textContent).toContain("Document is invalid");
  expect(document.querySelector("dialog")).toBe(dialog);
  reject = false;
  named(dialog, "import_name").value = "Imported review";
  await submit(dialog);
  expect(h.writes().at(-1)).toEqual({ path: "/presets/import_document", method: "POST", body: { content, filename: "review.json", format: "json", name: "Imported review" } });
  expect(document.querySelector("dialog")).toBeNull();
  expect(named(h.view.element.querySelector(".preset-editor"), "preset_name").value).toBe("Imported review");
  expect(h.requests.some((row) => row.path.startsWith("/agents"))).toBe(false);
  h.view.dispose();
});

test("project Preset imports display rejected file reasons", async () => {
  const h = harness(); await flush();
  button(h.view.element, "Import project Presets").click(); await flush();
  expect(h.writes().at(-1)).toEqual({ path: "/presets/import", method: "POST", body: {} });
  expect(h.view.element.textContent).toContain("0 Presets imported");
  expect(h.view.element.textContent).toContain("Unsupported Preset fields: audience");
  h.view.dispose();
});

test("Preset exports use the selected public identity and download the server document", async () => {
  const h = harness();
  const blobs = [], downloads = [];
  const create = URL.createObjectURL;
  URL.createObjectURL = (blob) => { blobs.push(blob); return "blob:preset"; };
  document.body.addEventListener("click", (event) => { if (event.target.tagName === "A") downloads.push(event.target.getAttribute("download")); });
  try {
    await flush(); h.open("preset-review");
    for (const label of ["Export Markdown", "Export JSON"]) { button(h.view.element, label).click(); await flush(); }
    expect(h.requests.filter((row) => row.path.startsWith("/presets/export")).map((row) => row.path)).toEqual([
      "/presets/export?public_id=preset-review&format=md", "/presets/export?public_id=preset-review&format=json",
    ]);
    expect(downloads).toEqual(["Reviewer.md", "Reviewer.json"]);
    expect(JSON.parse(await blobs[0].text())).toEqual({ name: "Reviewer", description: "Review changes", configuration: PRESETS[2].configuration });
    expect(h.writes()).toEqual([]);
  } finally { URL.createObjectURL = create; h.view.dispose(); }
});
