import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, type, flush } from "./support/dom.js";
import { pluginForm } from "../webui/features/plugins/plugin_form.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const schema = { type: "object", properties: {
  port: { type: "integer", minimum: 1, maximum: 65535, default: 3773, description: "Listening port" },
  verbose: { type: "boolean", default: false },
  token: { type: "string", writeOnly: true },
} };
const row = (overrides = {}, secretSet = true) => ({ id: "example", name: "Example", enabled: true, active: true, configurable: true,
  configuration: { schema, overrides, value: { port: 3773, verbose: false, ...overrides }, diagnostics: [], secrets: [{ path: ["token"], set: secretSet }] } });
// The shim submits a form for every button click; non-submit buttons are pressed directly.
const press = (node) => { if (!node.disabled) node.dispatchEvent(new Event("click")); };
const button = (root, label) => root.querySelectorAll("button").find((node) => node.textContent === label);
const control = (root, label) => {
  const target = root.querySelectorAll("label").find((node) => node.textContent === label);
  return document.getElementById(target.getAttribute("for"));
};

function form(initial = row(), answers = {}) {
  const requests = [];
  const accepted = [];
  let refreshes = 0;
  const shell = {
    call: async (path, options) => { requests.push([path, options.method, options.body]); return answers.patch(options.body); },
    setup: { refresh: async () => {} },
    inventory: { accept: async (answer) => accepted.push(answer), refresh: async () => { refreshes += 1; } },
  };
  let props = { plugin: initial, refresh: () => shell.inventory.refresh(), visible: true };
  const view = pluginForm(shell, props);
  document.body.append(view.element);
  const submit = async () => { view.element.dispatchEvent(new Event("submit")); await flush(); };
  return { view, requests, accepted, submit, refreshes: () => refreshes, element: view.element,
    update: (changes) => { props = { ...props, ...changes }; view.update(props); } };
}

test("fields come from the schema with their labels, hints, sources and per-field defaults", () => {
  const f = form();
  const port = control(f.element, "port");
  expect(port.value).toBe("3773");
  expect(f.element.textContent).toContain("Listening port");
  expect(f.element.textContent).toContain("Inherited default or file fallback.");
  expect(control(f.element, "verbose").value).toBe("false");
  expect(button(f.element, "Save").disabled).toBe(true);
  type(port, "4373");
  expect(f.element.textContent).toContain("Explicit override.");
  expect(button(f.element, "Save").disabled).toBe(false);
  type(port, "70000");
  expect(f.element.querySelector(".field__error").textContent).toBe("Enter at most 65535.");
  expect(button(f.element, "Save").disabled).toBe(true);
});

test("a save sends only the draft's operations, applies the answer's row and reports what happened", async () => {
  const f = form(row(), { patch: () => ({ saved: true, applied: true, plugin: row({ port: 4373 }) }) });
  type(control(f.element, "port"), "4373");
  await f.submit();
  expect(f.requests).toEqual([["/extensions/example/configuration", "PATCH", { operations: [{ op: "set", path: ["port"], value: 4373 }] }]]);
  expect(f.accepted).toHaveLength(1);
  expect(f.element.querySelector(".plugin-form__feedback").textContent).toBe("Saved and applied.");
  expect(button(f.element, "Save").disabled).toBe(true);
});

test("choosing Not set in a choice field restores its default instead of saving a value", async () => {
  const f = form(row({ verbose: true }), { patch: () => ({ saved: true, applied: true, plugin: row() }) });
  const verbose = control(f.element, "verbose");
  expect(verbose.value).toBe("true");
  verbose.value = "";
  verbose.dispatchEvent(new Event("change"));
  expect(verbose.value).toBe("");
  expect(verbose.closest(".plugin-form__field").querySelector(".plugin-form__source").textContent).toBe("Inherited default or file fallback.");
  await f.submit();
  expect(f.requests[0][2]).toEqual({ operations: [{ op: "unset", path: ["verbose"] }] });
});

test("a secret is never prefilled; keep, replace and clear are explicit", async () => {
  const f = form(row(), { patch: (body) => ({ saved: true, applied: true, plugin: row({}, false), body }) });
  const secret = control(f.element, "token replacement");
  const status = () => secret.closest(".plugin-form__field").querySelector(".plugin-form__source").textContent;
  expect(secret.value).toBe("");
  expect(secret.getAttribute("type")).toBe("password");
  expect(status()).toBe("Configured. Current value is never shown.");
  type(secret, "new-token");
  expect(status()).toBe("Replacement pending.");
  press(button(secret.closest(".plugin-form__field"), "Keep"));
  expect(secret.value).toBe("");
  expect(status()).toBe("Configured. Current value is never shown.");
  press(button(secret.closest(".plugin-form__field"), "Clear"));
  expect(status()).toBe("Will clear on save.");
  await f.submit();
  expect(f.requests[0][2]).toEqual({ operations: [{ op: "unset", path: ["token"] }] });
  expect(f.element.querySelector(".plugin-form__raw")).toBeNull();
  expect(f.element.querySelector("textarea[aria-label]").value).not.toContain("token");
});

test("a lost response keeps the draft and the next save reads the saved state first", async () => {
  let attempt = 0;
  const f = form(row(), { patch: () => { attempt += 1; if (attempt === 1) throw new TypeError("Failed to fetch"); return { saved: true, applied: true, plugin: row({ port: 4000 }) }; } });
  type(control(f.element, "port"), "4000");
  await f.submit();
  expect(f.element.querySelector(".plugin-form__feedback").textContent).toContain("Save outcome is unknown");
  expect(control(f.element, "port").value).toBe("4000");
  expect(f.refreshes()).toBe(0);
  await f.submit();
  expect(f.refreshes()).toBe(1);
  expect(f.requests).toHaveLength(2);
});

test("a refused save keeps the draft with the daemon's reason; a published-but-unapplied answer acknowledges", async () => {
  let reply = () => { throw Object.assign(new Error("port is reserved"), { status: 422, details: { saved: false } }); };
  const f = form(row(), { patch: () => reply() });
  type(control(f.element, "port"), "4000");
  await f.submit();
  expect(f.element.querySelector(".plugin-form__feedback").textContent).toBe("port is reserved");
  expect(button(f.element, "Save").disabled).toBe(false);
  reply = () => { throw Object.assign(new Error("apply failed"), { status: 503, details: { saved: true, applied: false, plugin: row({ port: 4000 }) } }); };
  await f.submit();
  expect(f.element.querySelector(".plugin-form__feedback").textContent).toContain("Saved, but not applied");
  expect(button(f.element, "Save").disabled).toBe(true);
  expect(f.accepted).toHaveLength(1);
});

test("Advanced JSON edits the same draft and invalid JSON blocks Save; Discard drops every edit", () => {
  const f = form(row({ port: 10 }));
  const raw = f.element.querySelector(".plugin-form__json textarea");
  expect(JSON.parse(raw.value)).toEqual({ port: 10 });
  type(raw, "{");
  expect(f.element.querySelector(".plugin-form__json .field__error").hidden).toBe(false);
  expect(button(f.element, "Save").disabled).toBe(true);
  type(raw, JSON.stringify({ port: 11, verbose: true }));
  expect(control(f.element, "port").value).toBe("11");
  expect(control(f.element, "verbose").value).toBe("true");
  press(button(f.element, "Discard"));
  expect(control(f.element, "port").value).toBe("10");
  expect(button(f.element, "Save").disabled).toBe(true);
});

test("Restore defaults unsets every override and saved secret", () => {
  const f = form(row({ port: 10 }));
  press(button(f.element, "Restore defaults"));
  expect(control(f.element, "port").value).toBe("3773");
  expect(f.element.textContent).toContain("Will clear on save.");
});

test("a refreshed row keeps edits, and a hidden page drops typed secrets", () => {
  const f = form();
  type(control(f.element, "port"), "4100");
  type(control(f.element, "token replacement"), "typed-secret");
  f.update({ plugin: { ...row(), active: false } });
  expect(control(f.element, "port").value).toBe("4100");
  expect(control(f.element, "token replacement").value).toBe("typed-secret");
  f.update({ visible: false });
  expect(control(f.element, "token replacement").value).toBe("");
  expect(control(f.element, "port").value).toBe("4100");
});

const MODEL_ROW = (overrides = {}) => ({ id: "rho.images", name: "Images", enabled: true, active: true, configurable: true,
  configuration: { schema: { type: "object", properties: {
    model: { type: ["string", "null"], title: "Image model", "x-rho-choices": { source: "models", workload: "image_generation" } },
    note: { type: ["string", "null"] },
  } }, overrides, value: { model: null, note: null, ...overrides }, diagnostics: [], secrets: [] } });

function catalogForm(initial, models) {
  const requests = [];
  const shell = {
    call: async (path, options) => {
      requests.push(path);
      if (path.startsWith("/models?")) { if (!models) throw new Error("member_plane_unavailable"); return { models }; }
      return { saved: true, applied: true, plugin: initial };
    },
    setup: { refresh: async () => {} },
    inventory: { accept: async () => {}, refresh: async () => {} },
  };
  const view = pluginForm(shell, { plugin: initial, refresh: async () => {}, visible: true });
  document.body.append(view.element);
  return { view, requests, element: view.element, submit: async () => { view.element.dispatchEvent(new Event("submit")); await flush(); } };
}

test("a field with x-rho-choices is chosen from the daemon's model catalog for its workload", async () => {
  const f = catalogForm(MODEL_ROW({ model: "dev/retired" }), [{ ref: "dev/paint", display_name: "Paint" }, { ref: "dev/sketch" }]);
  await flush();
  expect(f.requests).toEqual(["/models?workload=image_generation"]);
  const model = control(f.element, "Image model");
  expect(model.localName).toBe("select");
  expect(model.options.map((option) => option.textContent)).toEqual(["Not set", "Paint · dev/paint", "dev/sketch", "dev/retired · unavailable"]);
  expect(model.value).toBe("dev/retired");
  model.value = "dev/paint";
  model.dispatchEvent(new Event("change"));
  await f.submit();
  expect(f.requests.at(-1)).toBe("/extensions/rho.images/configuration");
  model.value = "";
  model.dispatchEvent(new Event("change"));
  expect(f.element.textContent).toContain("Not set.");
});

test("a catalog that cannot be read leaves the saved choice selectable, and a nullable string is plain text", async () => {
  const f = catalogForm(MODEL_ROW({ model: "dev/paint", note: "kept" }), null);
  await flush();
  const model = control(f.element, "Image model");
  expect(model.options.map((option) => option.textContent)).toEqual(["Not set", "dev/paint · unavailable"]);
  expect(model.value).toBe("dev/paint");
  const note = control(f.element, "note");
  expect(note.localName).toBe("input");
  expect(note.value).toBe("kept");
  type(note, "a plain sentence, no quotes");
  expect(f.element.querySelectorAll(".field__error").filter((node) => !node.hidden)).toEqual([]);
  expect(f.element.textContent).toContain("Explicit override.");
  type(note, "");
  expect(f.element.textContent).toContain("Not set.");
});
