import { test, expect } from "bun:test";
import { packageActivation, packageActionMessage, packageCheckMessage, packageSettings } from "../webui/package_settings.js";

const first = "a".repeat(64);
const second = "b".repeat(64);
const row = (version, facts = {}) => ({ name: "notes", id: "personal.notes", description: "Personal notes",
  version, configuration_version: 1, state_schema: "v1", dependencies: {},
  selected: false, active: false, enabled: false, previous: false, ...facts });

// The same small DOM seam as the composer tests: real callbacks, requests and
// response ordering run here; rendered layout is checked in a browser.
async function withDocument(run) {
  const previous = globalThis.document;
  const node = (tag = "") => ({ tag, nodeType: 1, children: [], listeners: {}, value: "", textContent: "", hidden: false,
    setAttribute(name, value) { this[name] = value; },
    addEventListener(name, handler) { this.listeners[name] = handler; },
    append(child) { child.parent = this; this.children.push(child); },
    replaceChildren(...children) { this.children = []; for (const child of children) this.append(child); },
    remove() { this.parent.children = this.parent.children.filter((child) => child !== this); },
  });
  globalThis.document = { createElement: node, createTextNode: (text) => ({ nodeType: 3, textContent: text, children: [] }) };
  try { await run(); } finally { globalThis.document = previous; }
}
const nodes = (node) => [node, ...node.children.flatMap(nodes)];
const text = (node) => node.textContent + node.children.map(text).join("");
const control = (root, label) => nodes(root).find((node) => node.tag === "label" && node.children[0].textContent === label).children.at(-1);
const button = (root, label) => nodes(root).find((node) => node.tag === "button" && node.textContent === label);
const click = (root, label) => button(root, label).listeners.click();
const card = (panel) => nodes(panel.element).find((node) => node["data-package-name"] === "notes");
const submit = (panel) => nodes(panel.element).find((node) => node.tag === "form").listeners.submit({ preventDefault() {} });

function fixture(initial = []) {
  let rows = initial;
  let post = async () => { throw new Error("Unexpected mutation"); };
  const calls = [];
  const errors = [];
  const session = new AbortController();
  const panel = packageSettings({ signal: session.signal, showError: (error) => errors.push(error), call: async (path, options = {}) => {
    calls.push([path, options.method || "GET", options.body]);
    if (options.method === "POST") return post(options.body);
    return { packages: structuredClone(rows) };
  } });
  return { panel, calls, errors, session, rows: (next) => { rows = next; }, post: (handler) => { post = handler; } };
}

test("activation preserves configuration by omission and only sends explicit JSON overrides", () => {
  expect(packageActivation("notes", first, " \n ")).toEqual({ action: "activate", name: "notes", version: first });
  expect(packageActivation("notes", first, "{}").configuration).toEqual({});
  expect(packageActivation("notes", first, '{"label":"home"}').configuration).toEqual({ label: "home" });
  for (const invalid of ["{", "[]", "null", '"text"']) expect(() => packageActivation("notes", first, invalid)).toThrow("Configuration overrides");
});

test("check feedback distinguishes test files, failed or timed-out tests and structure-only checks", () => {
  expect(packageCheckMessage({ passed: true, tests: 0 })).toContain("no tests ran");
  expect(packageCheckMessage({ passed: true, tests: 2 })).toBe("Checks passed (2 test files).");
  expect(packageCheckMessage({ passed: false, tests: 1, exit_status: 1 })).toBe("Checks failed (exit 1).");
  expect(packageCheckMessage({ passed: false, timed_out: true })).toContain("timed out");
});

test("operation feedback preserves saved, applied, restart, announcement and durability facts", () => {
  expect(packageActionMessage({ installed: true, active: false })).toContain("Candidate installed");
  expect(packageActionMessage({ saved: true, applied: true })).toBe("Selection saved and applied.");
  expect(packageActionMessage({ saved: true, applied: false, restart_required: true })).toContain("saved, but not applied. Restart rho");
  expect(packageActionMessage({ saved: true, applied: true, published: false })).toContain("Platform announcement was not completed");
  expect(packageActionMessage({ saved: true, applied: true, persistence: "published_durability_uncertain", warning: "Storage warning." }))
    .toContain("Do not repeat this operation");
  expect(packageActionMessage({ saved: true, applied: true, cleanup_pending: ["notes"], failures: [{ extension: "notes", error_class: "IOError" }] }))
    .toContain("Cleanup failures: notes (IOError)");
});

test("installation only copies a candidate and chooses its complete installed version without activating", async () => withDocument(async () => {
  const f = fixture();
  await f.panel.refresh();
  expect(text(f.panel.element)).toContain("No managed packages are installed.");
  control(f.panel.element, "Source directory").value = "/home/runner/notes";
  f.post(async (body) => {
    expect(body).toEqual({ action: "install", path: "/home/runner/notes" });
    f.rows([row(first)]);
    return { installed: true, active: false, name: "notes", version: first };
  });
  await submit(f.panel);
  expect(f.calls.filter((entry) => entry[1] === "POST")).toHaveLength(1);
  expect(card(f.panel).open).toBe(true);
  expect(control(card(f.panel), "Installed version").value).toBe(first);
  expect(text(card(f.panel))).toContain("Saved: None · Running: None");
  expect(button(card(f.panel), "Roll back").disabled).toBe(true);
  expect(button(card(f.panel), "Disable package").disabled).toBe(true);
}));

test("version checks keep literal output per version and do not make checks an activation requirement", async () => withDocument(async () => {
  const f = fixture([row(first), row(second)]);
  await f.panel.refresh();
  f.post(async (body) => ({ name: body.name, version: body.version, checked: true, passed: false, tests: 1, exit_status: 1, output: "<script>literal failure</script>" }));
  await click(card(f.panel), "Check version");
  expect(text(card(f.panel))).toContain("<script>literal failure</script>");
  expect(button(card(f.panel), "Activate version").disabled).not.toBe(true);
  const selector = control(card(f.panel), "Installed version");
  selector.value = second; selector.listeners.change();
  const result = nodes(card(f.panel)).find((node) => node.className === "package-check");
  expect(result.hidden).toBe(true);
  await f.panel.refresh();
  expect(selector.value).toBe(second);
  selector.value = first; selector.listeners.change();
  expect(result.hidden).toBe(false);
  expect(text(result)).toContain("Checks failed (exit 1)");
}));

test("activation, rollback and disable use their existing API operations and display saved versus running versions", async () => withDocument(async () => {
  const f = fixture([row(first, { selected: true, active: true, enabled: true }), row(second)]);
  await f.panel.refresh();
  control(card(f.panel), "Installed version").value = second;
  control(card(f.panel), "Configuration overrides").value = '{"label":"home"}';
  f.post(async (body) => {
    expect(body).toEqual({ action: "activate", name: "notes", version: second, configuration: { label: "home" } });
    f.rows([row(first, { active: true, previous: true }), row(second, { selected: true, enabled: true })]);
    return { saved: true, applied: false, restart_required: true, selected: second, active: first };
  });
  await click(card(f.panel), "Activate version");
  expect(text(card(f.panel))).toContain("Saved: bbbbbbbbbbbb (enabled) · Running: aaaaaaaaaaaa · Previous: aaaaaaaaaaaa");
  expect(text(card(f.panel))).toContain("Restart rho");
  expect(control(card(f.panel), "Configuration overrides").value).toBe("");
  f.post(async (body) => {
    expect(body).toEqual({ action: "rollback", name: "notes" });
    f.rows([row(first, { selected: true, enabled: true, active: true }), row(second, { previous: true })]);
    return { saved: true, applied: true };
  });
  await click(card(f.panel), "Roll back");
  f.post(async (body) => {
    expect(body).toEqual({ action: "disable", name: "notes" });
    f.rows([row(first, { selected: true }), row(second, { previous: true })]);
    return { saved: true, applied: true };
  });
  await click(card(f.panel), "Disable package");
  expect(text(card(f.panel))).toContain("Saved: aaaaaaaaaaaa (disabled) · Running: None");
}));

test("a refused activation retains the configuration draft and exposes the backend reason without retries", async () => withDocument(async () => {
  const f = fixture([row(first), row(second)]);
  await f.panel.refresh();
  const configuration = control(card(f.panel), "Configuration overrides");
  configuration.value = '{"label":"keep"}';
  f.post(async () => { throw Object.assign(new Error("Business state schema differs; recover state first."), { status: 422 }); });
  await click(card(f.panel), "Activate version");
  expect(configuration.value).toBe('{"label":"keep"}');
  expect(text(card(f.panel))).toContain("Business state schema differs");
  expect(f.calls.filter((entry) => entry[1] === "POST")).toHaveLength(1);
  f.panel.clearSecrets();
  expect(configuration.value).toBe("");
}));

test("an uncertain mutation requires reading state before another action and never retries on its own", async () => withDocument(async () => {
  const f = fixture([row(first, { selected: true, active: true, enabled: true }), row(second, { previous: true })]);
  await f.panel.refresh();
  f.post(async () => { throw new Error("Connection closed"); });
  await click(card(f.panel), "Roll back");
  expect(text(card(f.panel))).toContain("outcome is unknown");
  await click(card(f.panel), "Roll back");
  expect(f.calls.filter((entry) => entry[1] === "POST")).toHaveLength(1);
  f.rows([row(first, { previous: true }), row(second, { selected: true, active: true, enabled: true })]);
  await click(f.panel.element, "Refresh packages");
  expect(f.calls.filter((entry) => entry[1] === "POST")).toHaveLength(1);
  expect(text(card(f.panel))).toContain("Saved: bbbbbbbbbbbb (enabled) · Running: bbbbbbbbbbbb");
}));

test("aborted sessions discard late responses and duplicate clicks cannot start overlapping package writes", async () => withDocument(async () => {
  const f = fixture([row(first)]);
  await f.panel.refresh();
  let complete;
  f.post(() => new Promise((resolve) => { complete = resolve; }));
  const pending = click(card(f.panel), "Activate version");
  await click(card(f.panel), "Activate version");
  expect(f.calls.filter((entry) => entry[1] === "POST")).toHaveLength(1);
  f.session.abort();
  complete({ saved: true, applied: true });
  await pending;
  expect(f.calls.filter((entry) => entry[1] === "GET")).toHaveLength(1);
  expect(text(card(f.panel))).not.toContain("Selection saved and applied");
}));
