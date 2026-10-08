import { test, expect } from "bun:test";
import { promptSettings } from "../webui/prompt_settings.js";

// Double only the DOM seam. The ordinary form callbacks own draft changes,
// server refreshes and save outcomes; product E2E covers native interaction.
async function withDocument(run) {
  const previous = globalThis.document;
  const node = (tag) => ({ tag, nodeType: 1, children: [], listeners: {}, value: "", textContent: "", checked: false, hidden: false,
    setAttribute(name, value) { this[name] = ["disabled", "hidden", "checked"].includes(name) ? true : value; },
    addEventListener(name, handler) { this.listeners[name] = handler; },
    append(child) { this.children.push(child); },
  });
  globalThis.document = { createElement: node, createTextNode: (text) => ({ nodeType: 3, textContent: text, children: [] }) };
  try { await run(); } finally { globalThis.document = previous; }
}

const descendants = (node) => [node, ...node.children.flatMap(descendants)];
const field = (panel, name) => descendants(panel.element).find((node) => node.name === name);
const button = (panel, label) => descendants(panel.element).find((node) => node.tag === "button" && node.textContent === label);
const fields = (panel) => descendants(panel.element).find((node) => node.tag === "fieldset");
const submit = (panel) => descendants(panel.element).find((node) => node.tag === "form").listeners.submit({ preventDefault() {} });
const edit = (panel, name, value) => { const input = field(panel, name); input.value = value; input.listeners.input(); };
const replaceBase = (panel, value) => { const input = field(panel, "replace_base_prompt"); input.checked = value; input.listeners.change(); };
const configuration = (settings = {}) => ({ settings: {
  default_model: "example/model", tools_root: "/work", work_preset: "standard", custom_instructions: null, base_prompt: null, ...settings,
} });

test("changing a work preset preserves additional instructions and saves only that explicit choice", async () => withDocument(async () => {
  let saved = configuration({ custom_instructions: "  Keep my preference.\n" });
  const calls = [];
  const panel = promptSettings({ showError: (error) => { throw error; }, save: async (changes) => {
    calls.push(changes); saved = configuration({ ...saved.settings, ...changes }); return saved;
  } });
  expect(fields(panel).disabled).toBe(true);
  panel.update(saved);
  expect(fields(panel).disabled).toBe(false);
  expect(field(panel, "work_preset").value).toBe("standard");
  await submit(panel);
  expect(calls).toEqual([]);

  edit(panel, "work_preset", "compact");
  await submit(panel);
  expect(calls).toEqual([{ work_preset: "compact" }]);
  expect(field(panel, "custom_instructions").value).toBe("  Keep my preference.\n");
  expect(saved.settings.tools_root).toBe("/work");
  expect(field(panel, "replace_base_prompt").checked).toBe(false);
}));

test("both prompt fields preserve literal multiline text and surrounding whitespace", async () => withDocument(async () => {
  const calls = [];
  const panel = promptSettings({ showError: (error) => { throw error; }, save: async (changes) => {
    calls.push(changes); return configuration(changes);
  } });
  panel.update(configuration());
  const additional = "  使用中文。\n\n    Keep indentation.  \n";
  const base = "\n<instructions>{rho}</instructions>\n  Final line.  ";
  edit(panel, "custom_instructions", additional);
  replaceBase(panel, true);
  edit(panel, "base_prompt", base);
  await submit(panel);

  expect(calls).toEqual([{ custom_instructions: additional, base_prompt: base }]);
  expect(field(panel, "custom_instructions").value).toBe(additional);
  expect(field(panel, "base_prompt").value).toBe(base);
  expect(field(panel, "replace_base_prompt").checked).toBe(true);
}));

test("an enabled empty replacement stays distinct from restoring the selected built-in preset", async () => withDocument(async () => {
  let saved = configuration({ work_preset: "compact", custom_instructions: "Keep this." });
  const calls = [];
  const panel = promptSettings({ showError: (error) => { throw error; }, save: async (changes) => {
    calls.push(changes); saved = configuration({ ...saved.settings, ...changes }); return saved;
  } });
  panel.update(saved);
  replaceBase(panel, true);
  await submit(panel);
  expect(calls).toEqual([{ base_prompt: "" }]);
  expect(field(panel, "replace_base_prompt").checked).toBe(true);
  expect(field(panel, "base_prompt").value).toBe("");
  const replacementNotice = descendants(panel.element).find((node) => node.textContent.startsWith("A base prompt replacement takes priority"));
  expect(replacementNotice.hidden).toBe(false);

  button(panel, "Restore built-in prompt").listeners.click();
  expect(calls).toHaveLength(1);
  expect(field(panel, "replace_base_prompt").checked).toBe(false);
  expect(button(panel, "Restore built-in prompt").disabled).toBe(true);
  expect(replacementNotice.hidden).toBe(true);
  await submit(panel);
  expect(calls[1]).toEqual({ base_prompt: null });
  expect(saved.settings.work_preset).toBe("compact");
  expect(saved.settings.custom_instructions).toBe("Keep this.");

  panel.update(configuration({ base_prompt: "Previously saved base." }));
  replaceBase(panel, false);
  await submit(panel);
  expect(calls[2]).toEqual({ base_prompt: null });
}));

test("refreshes and a completed save retain edits made after the submitted draft", async () => withDocument(async () => {
  let finish;
  const calls = [];
  const panel = promptSettings({ showError: (error) => { throw error; }, save: async (changes) => {
    calls.push(changes);
    if (calls.length === 1) return new Promise((resolve) => { finish = resolve; });
    return configuration({ work_preset: "compact", base_prompt: "Remote base", ...changes });
  } });
  panel.update(configuration());
  edit(panel, "custom_instructions", "My draft");
  panel.update(configuration({ work_preset: "compact", custom_instructions: "Remote text", base_prompt: "Remote base" }));
  expect(field(panel, "work_preset").value).toBe("compact");
  expect(field(panel, "custom_instructions").value).toBe("My draft");
  expect(field(panel, "base_prompt").value).toBe("Remote base");

  const pending = submit(panel);
  expect(fields(panel).disabled).toBe(true);
  await submit(panel);
  expect(calls).toEqual([{ custom_instructions: "My draft" }]);
  edit(panel, "custom_instructions", "A newer edit");
  finish(configuration({ work_preset: "compact", custom_instructions: "My draft", base_prompt: "Remote base" }));
  await pending;
  expect(fields(panel).disabled).toBe(false);
  expect(field(panel, "custom_instructions").value).toBe("A newer edit");
  await submit(panel);
  expect(calls[1]).toEqual({ custom_instructions: "A newer edit" });
}));

test("a refused save keeps the draft through refresh and requires another deliberate save", async () => withDocument(async () => {
  const calls = [];
  const errors = [];
  const panel = promptSettings({ showError: (error) => errors.push(error), save: async (changes) => {
    calls.push(changes);
    if (calls.length === 1) throw new Error("The combined prompt is too long.");
    if (calls.length === 2) return null;
    return configuration(changes);
  } });
  panel.update(configuration());
  edit(panel, "custom_instructions", "  Keep this draft.  ");
  await submit(panel);
  expect(errors.map((error) => error.message)).toEqual(["The combined prompt is too long."]);
  expect(fields(panel).disabled).toBe(false);
  panel.update(configuration());
  expect(field(panel, "custom_instructions").value).toBe("  Keep this draft.  ");
  expect(calls).toHaveLength(1);
  await submit(panel);
  expect(field(panel, "custom_instructions").value).toBe("  Keep this draft.  ");
  await submit(panel);
  expect(calls).toEqual(Array(3).fill({ custom_instructions: "  Keep this draft.  " }));
}));

test("clearing additional instructions uses null while whitespace remains literal content", async () => withDocument(async () => {
  const calls = [];
  const panel = promptSettings({ showError: (error) => { throw error; }, save: async (changes) => {
    calls.push(changes); return configuration(changes);
  } });
  panel.update(configuration({ custom_instructions: "Previous instructions" }));
  edit(panel, "custom_instructions", "");
  await submit(panel);
  expect(calls[0]).toEqual({ custom_instructions: null });
  edit(panel, "custom_instructions", " \n  ");
  await submit(panel);
  expect(calls[1]).toEqual({ custom_instructions: " \n  " });
}));

test("a saved prompt can be explicitly republished after a failed publication and refresh", async () => withDocument(async () => {
  let saved = configuration();
  const calls = [];
  const panel = promptSettings({ showError: (error) => { throw error; }, save: async (changes) => {
    calls.push(changes);
    saved = configuration({ ...saved.settings, ...changes });
    // The shared save callback reports a publication refusal and returns null,
    // even though the daemon already saved and applied the prompt locally.
    return calls.length === 1 ? null : saved;
  } });
  panel.update(saved);
  edit(panel, "custom_instructions", "Republish these instructions.");
  await submit(panel);
  panel.update(saved);
  expect(calls).toHaveLength(1);

  await submit(panel);
  expect(calls).toEqual([{ custom_instructions: "Republish these instructions." },
    { custom_instructions: "Republish these instructions." }]);
  await submit(panel);
  expect(calls).toHaveLength(2);
}));
