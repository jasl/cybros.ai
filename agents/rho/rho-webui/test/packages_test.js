import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { packageActivation, packageActionMessage, packageCheckMessage, packagesCard } from "../webui/features/plugins/packages.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const first = "a".repeat(64);
const second = "b".repeat(64);
const row = (version, facts = {}) => ({ name: "notes", id: "personal.notes", description: "Personal notes", version, configuration_version: 1,
  state_schema: "v1", dependencies: {}, selected: false, active: false, enabled: false, previous: false, ...facts });
const settle = async () => { for (let index = 0; index < 10; index += 1) await flush(); };

function fixture(initial = []) {
  let rows = initial;
  let post = async () => { throw new Error("Unexpected mutation"); };
  const calls = [];
  const refreshes = [];
  const session = new AbortController();
  const shell = { signal: session.signal, inventory: { refresh: () => refreshes.push(1) },
    call: async (path, options = {}) => {
      calls.push([path, options.method || "GET", options.body]);
      if (options.method === "POST") return post(options.body);
      return { packages: structuredClone(rows) };
    } };
  const card = packagesCard(shell);
  document.body.append(card.element);
  return { card, calls, refreshes, session, element: card.element, rows: (next) => { rows = next; }, post: (handler) => { post = handler; },
    posts: () => calls.filter((entry) => entry[1] === "POST") };
}
const control = (root, label) => document.getElementById(root.querySelectorAll("label").find((node) => node.textContent === label).getAttribute("for"));
const button = (root, label) => root.querySelectorAll("button").find((node) => node.textContent === label || node.getAttribute("aria-label") === label);
const click = async (root, label) => { button(root, label).click(); await settle(); };
const notes = (f) => f.element.querySelector('[data-package-name="notes"]');

test("activation preserves configuration by omission and only sends explicit JSON overrides", () => {
  expect(packageActivation("notes", first, " \n ")).toEqual({ action: "activate", name: "notes", version: first });
  expect(packageActivation("notes", first, "{}").configuration).toEqual({});
  expect(packageActivation("notes", first, '{"label":"home"}').configuration).toEqual({ label: "home" });
  for (const invalid of ["{", "[]", "null", '"text"']) expect(() => packageActivation("notes", first, invalid)).toThrow("Configuration overrides");
});

test("check feedback distinguishes test files, failed or timed-out tests and structure-only checks", () => {
  expect(packageCheckMessage({ passed: true, tests: 0 })).toContain("no tests ran");
  expect(packageCheckMessage({ passed: true, tests: 1 })).toBe("Checks passed (1 test file).");
  expect(packageCheckMessage({ passed: true, tests: 2 })).toBe("Checks passed (2 test files).");
  expect(packageCheckMessage({ passed: false, tests: 1, exit_status: 1 })).toBe("Checks failed (exit 1).");
  expect(packageCheckMessage({ passed: false, timed_out: true })).toContain("timed out");
});

test("operation feedback preserves saved, applied, restart, announcement and durability facts", () => {
  expect(packageActionMessage({ installed: true, active: false })).toContain("Candidate installed");
  expect(packageActionMessage({ saved: true, applied: true })).toBe("Selection saved and applied.");
  expect(packageActionMessage({ saved: true, applied: false, restart_required: true })).toContain("saved, but not applied. Restart rho");
  expect(packageActionMessage({ saved: true, applied: true, published: false })).toContain("Platform announcement was not completed");
  expect(packageActionMessage({ saved: true, applied: true, persistence: "published_durability_uncertain", warning: "Storage warning." })).toContain("Do not repeat this operation");
  expect(packageActionMessage({ saved: true, applied: true, cleanup_pending: ["notes"], failures: [{ extension: "notes", error_class: "IOError" }] }))
    .toContain("Cleanup failures: notes (IOError)");
});

test("the group reads packages on refresh; installing copies a candidate and shows it without activating", async () => {
  const f = fixture();
  expect(f.calls).toEqual([]);
  expect(f.element.querySelector(".group__title").textContent).toBe("Managed packages");
  await f.card.refresh();
  await settle();
  expect(f.element.textContent).toContain("No managed packages are installed.");
  control(f.element, "Source directory").value = "/home/runner/notes";
  f.post(async (body) => {
    expect(body).toEqual({ action: "install", path: "/home/runner/notes" });
    f.rows([row(first)]);
    return { installed: true, active: false, name: "notes", version: first };
  });
  f.element.querySelector("form").dispatchEvent(new Event("submit"));
  await settle();
  expect(f.posts()).toHaveLength(1);
  expect(notes(f).open).toBe(true);
  expect(control(notes(f), "Installed version").value).toBe(first);
  expect(notes(f).textContent).toContain("Saved: None · Running: None");
  expect(button(notes(f), "Roll back").disabled).toBe(true);
  expect(button(notes(f), "Disable package").disabled).toBe(true);
  expect(f.refreshes).toHaveLength(1);
});

test("version checks keep literal output per version and are not an activation requirement", async () => {
  const f = fixture([row(first), row(second)]);
  await f.card.refresh();
  f.post(async (body) => ({ name: body.name, version: body.version, checked: true, passed: false, tests: 1, exit_status: 1, output: "<script>literal failure</script>" }));
  await click(notes(f), "Check version");
  expect(notes(f).querySelector(".package__output").textContent).toBe("<script>literal failure</script>");
  expect(button(notes(f), "Activate version").disabled).toBe(false);
  const selector = control(notes(f), "Installed version");
  selector.value = second; selector.dispatchEvent(new Event("change"));
  const result = notes(f).querySelector(".package__check");
  expect(result.hidden).toBe(true);
  await f.card.refresh();
  expect(selector.value).toBe(second);
  selector.value = first; selector.dispatchEvent(new Event("change"));
  expect(result.hidden).toBe(false);
  expect(result.textContent).toContain("Checks failed (exit 1)");
  expect(f.refreshes).toHaveLength(0);
});

test("activate, roll back and disable use their operations and show saved versus running versions", async () => {
  const f = fixture([row(first, { selected: true, active: true, enabled: true }), row(second)]);
  await f.card.refresh();
  control(notes(f), "Installed version").value = second;
  control(notes(f), "Configuration overrides").value = '{"label":"home"}';
  f.post(async (body) => {
    expect(body).toEqual({ action: "activate", name: "notes", version: second, configuration: { label: "home" } });
    f.rows([row(first, { active: true, previous: true }), row(second, { selected: true, enabled: true })]);
    return { saved: true, applied: false, restart_required: true };
  });
  await click(notes(f), "Activate version");
  expect(notes(f).textContent).toContain("Saved: bbbbbbbbbbbb (enabled) · Running: aaaaaaaaaaaa · Previous: aaaaaaaaaaaa");
  expect(notes(f).textContent).toContain("Restart rho");
  expect(control(notes(f), "Configuration overrides").value).toBe("");
  f.post(async (body) => { expect(body).toEqual({ action: "rollback", name: "notes" }); f.rows([row(first, { selected: true, enabled: true, active: true }), row(second, { previous: true })]); return { saved: true, applied: true }; });
  await click(notes(f), "Roll back");
  f.post(async (body) => { expect(body).toEqual({ action: "disable", name: "notes" }); f.rows([row(first, { selected: true }), row(second, { previous: true })]); return { saved: true, applied: true }; });
  await click(notes(f), "Disable package");
  expect(notes(f).textContent).toContain("Saved: aaaaaaaaaaaa (disabled) · Running: None");
  expect(f.refreshes).toHaveLength(3);
});

test("a refused activation keeps the configuration draft and the daemon's reason without retrying", async () => {
  const f = fixture([row(first), row(second)]);
  await f.card.refresh();
  const configuration = control(notes(f), "Configuration overrides");
  configuration.value = '{"label":"keep"}';
  f.post(async () => { throw Object.assign(new Error("Business state schema differs; recover state first."), { status: 422 }); });
  await click(notes(f), "Activate version");
  expect(configuration.value).toBe('{"label":"keep"}');
  expect(notes(f).textContent).toContain("Business state schema differs");
  expect(f.posts()).toHaveLength(1);
  f.card.clearSecrets();
  expect(configuration.value).toBe("");
});

test("an uncertain write requires reading the state before another change and never retries on its own", async () => {
  const f = fixture([row(first, { selected: true, active: true, enabled: true }), row(second, { previous: true })]);
  await f.card.refresh();
  f.post(async () => { throw new Error("Connection closed"); });
  await click(notes(f), "Roll back");
  expect(notes(f).textContent).toContain("outcome is unknown");
  await click(notes(f), "Roll back");
  expect(f.posts()).toHaveLength(1);
  f.rows([row(first, { previous: true }), row(second, { selected: true, active: true, enabled: true })]);
  await f.card.refresh();
  expect(f.posts()).toHaveLength(1);
  expect(notes(f).textContent).toContain("Saved: bbbbbbbbbbbb (enabled) · Running: bbbbbbbbbbbb");
});

test("an ended session discards late answers and duplicate clicks cannot start overlapping writes", async () => {
  const f = fixture([row(first)]);
  await f.card.refresh();
  let complete;
  f.post(() => new Promise((resolve) => { complete = resolve; }));
  button(notes(f), "Activate version").click();
  await click(notes(f), "Activate version");
  expect(f.posts()).toHaveLength(1);
  f.session.abort();
  complete({ saved: true, applied: true });
  await settle();
  expect(f.calls.filter((entry) => entry[1] === "GET")).toHaveLength(1);
  expect(notes(f).textContent).not.toContain("Selection saved and applied");
});
