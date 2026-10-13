import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush, type } from "./support/dom.js";
import { createSlots } from "../webui/kernel/slots.js";
import { register } from "../webui/features/settings/index.js";
import { rolesSection } from "../webui/features/settings/roles.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());
const PRESETS = [
  { public_id: "main", name: "Probius", description: "General work", configuration: { system_prompt: "Help the owner", model: "dev/first", tools: [] }, role: null },
  { public_id: "review", name: "Review configuration", description: "Review instructions", configuration: { system_prompt: "Find defects", model_mode: "follow" },
    role: { name: "reviewer", description: "Review completed work" } },
];
const named = (root, name) => root.querySelector(`[name="${name}"]`);
const button = (root, text) => [...root.querySelectorAll("button")].find((node) => node.textContent === text);

function harness({ fail = null, request = null, presets = PRESETS } = {}) {
  let catalog = { presets: structuredClone(presets) };
  const requests = [], navigations = [], toasts = [];
  const shell = {
    settings: { open: (...args) => navigations.push(args) }, toast: (text) => toasts.push(text),
    call: async (path, options = {}) => {
      const method = options.method || "GET", body = options.body;
      requests.push({ path, method, body });
      const problem = fail?.(path, method, body);
      if (problem) throw new Error(problem);
      if (method !== "GET") {
        const preset = catalog.presets.find((row) => row.public_id === body.public_id);
        preset.role = method === "DELETE" ? null : { name: body.name, description: body.description };
      }
      return structuredClone(catalog);
    },
  };
  let props = { status: { connected: true }, visible: true, request, refresh: () => {} };
  const view = rolesSection(shell, props);
  document.body.append(view.element);
  return { view, requests, navigations, toasts, catalog: () => catalog,
    update(changes) { props = { ...props, ...changes }; view.update(props); },
    writes: () => requests.filter((row) => row.method !== "GET"),
    editor: () => view.element.querySelector(".role-editor"),
    open(id) { view.element.querySelector(`[data-role="${id}"] .preset-catalog__name`).click(); },
    async submit() { view.element.querySelector(".role-editor").requestSubmit(); await flush(); },
  };
}

test("Settings exposes Subagent roles beside the Preset library", () => {
  const slots = createSlots();
  register({ slots }, {});
  expect(slots.entries("settings.section").map((row) => [row.cell, row.meta.label()])).toEqual([
    ["general", "General"], ["presets", "Agent Presets"], ["roles", "Subagent roles"], ["advanced", "Defaults"], ["deployment", "System upgrade"],
  ]);
});

test("roles list selection metadata and reference their existing Preset editor", async () => {
  const h = harness(); await flush();
  expect(h.view.element.querySelectorAll("[data-role]")).toHaveLength(1);
  const row = h.view.element.querySelector('[data-role="review"]');
  expect(row.textContent).toContain("reviewer");
  expect(row.textContent).toContain("Review completed work");
  expect(row.textContent).toContain("Preset: Review configuration");
  button(row, "Edit Preset").click();
  expect(h.navigations).toEqual([["presets", "review"]]);
  h.open("review");
  expect(named(h.editor(), "preset_public_id").disabled).toBe(true);
  expect(named(h.editor(), "system_prompt")).toBeNull();
  expect(named(h.editor(), "model")).toBeNull();
  expect(named(h.editor(), "preset_tools")).toBeNull();
  button(h.editor(), "Edit Preset").click();
  expect(h.navigations.at(-1)).toEqual(["presets", "review"]);
  expect(h.writes()).toEqual([]); h.view.dispose();
});

test("publishing, editing and unpublishing changes metadata without changing Preset configuration or creating identities", async () => {
  const h = harness(); await flush();
  button(h.view.element, "New role").click();
  const choice = named(h.editor(), "preset_public_id");
  expect(choice.options.map((option) => option.value)).toEqual(["", "main"]);
  type(choice, "main"); type(named(h.editor(), "role_name"), "builder"); type(named(h.editor(), "role_description"), "  Implement a bounded task  ");
  await h.submit();
  expect(h.writes()[0]).toEqual({ path: "/presets/role", method: "PUT", body: { public_id: "main", name: "builder", description: "Implement a bounded task" } });
  expect(h.view.element.querySelector('[data-role="main"]').textContent).toContain("builder");
  type(named(h.editor(), "role_name"), "worker"); type(named(h.editor(), "role_description"), "Execute a supplied plan");
  await h.submit();
  expect(h.writes()[1].body).toEqual({ public_id: "main", name: "worker", description: "Execute a supplied plan" });
  button(h.editor(), "Unpublish role").click(); await flush();
  expect(h.writes()[2]).toEqual({ path: "/presets/role", method: "DELETE", body: { public_id: "main" } });
  expect(h.view.element.querySelector('[data-role="main"]')).toBeNull();
  expect(h.editor()).toBeNull();
  expect(h.catalog().presets[0]).toEqual(PRESETS[0]);
  expect(h.requests.some((row) => row.path.startsWith("/agents"))).toBe(false);
  expect(h.toasts.at(-1)).toContain("Preset and accepted work are unchanged"); h.view.dispose();
});

test("opening from a Preset selects its publication and can open an unpublished Preset", async () => {
  const h = harness({ request: { section: "roles", item: "review" } }); await flush();
  expect(named(h.editor(), "role_name").value).toBe("reviewer");
  h.update({ request: { section: "roles", item: "main" } });
  expect(named(h.editor(), "preset_public_id").value).toBe("main");
  expect(named(h.editor(), "preset_public_id").disabled).toBe(false);
  expect(named(h.editor(), "role_name").value).toBe("");
  h.update({ request: { section: "roles", item: null } });
  expect(h.editor()).toBeNull(); h.view.dispose();
});

test("rejected saves and refreshes preserve the role draft and allow retry", async () => {
  let rejected = true;
  const h = harness({ fail: (_path, method) => method === "PUT" && rejected ? "Role name already published" : null });
  await flush(); h.open("review");
  type(named(h.editor(), "role_name"), "new-reviewer"); type(named(h.editor(), "role_description"), "Keep this draft");
  await h.submit();
  expect(h.editor().textContent).toContain("Role name already published");
  expect(h.editor().querySelector("fieldset").disabled).toBe(false);
  h.update({ visible: false }); h.update({ visible: true }); await flush();
  expect(named(h.editor(), "role_description").value).toBe("Keep this draft");
  rejected = false; await h.submit();
  expect(h.catalog().presets[1].role).toEqual({ name: "new-reviewer", description: "Keep this draft" });
  expect(h.writes()).toHaveLength(2); h.view.dispose();
});

test("empty and unavailable catalogs show actionable state without enabling an invalid publication", async () => {
  const empty = harness({ presets: [{ ...PRESETS[0], role: null }] }); await flush();
  expect(empty.view.element.textContent).toContain("No roles are published");
  expect(button(empty.view.element, "New role").disabled).toBe(false); empty.view.dispose();
  const all = harness({ presets: [PRESETS[1]] }); await flush();
  expect(button(all.view.element, "New role").disabled).toBe(true); all.view.dispose();
  const down = harness({ fail: () => "Nexus unavailable" }); await flush();
  expect(down.view.element.textContent).toContain("Nexus unavailable");
  expect(button(down.view.element, "New role").disabled).toBe(true);
  expect(button(down.view.element, "Refresh").disabled).toBe(false); down.view.dispose();
});
