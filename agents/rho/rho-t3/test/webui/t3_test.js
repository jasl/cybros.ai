import { test, expect, beforeEach, afterEach } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { installDocument, type, flush } from "../../../rho-webui/test/support/dom.js";
import { createSlots } from "../../../rho-webui/webui/kernel/slots.js";
import { keyedOutlet, listOutlet } from "../../../rho-webui/webui/kernel/outlets.js";
import { createHandle } from "../../../rho-webui/webui/kernel/handle.js";
import { translator } from "../../../rho-webui/webui/kernel/i18n.js";
import { el } from "../../../rho-webui/webui/kernel/dom.js";
import { primitives } from "../../../rho-webui/webui/primitives/index.js";
import { createToasts } from "../../../rho-webui/webui/primitives/toast.js";
import { register } from "../../webui/index.js";
import english from "../../webui/locales/en.js";
import { agentChoices, projectChoices } from "../../webui/choices.js";
import { connectionOperations } from "../../webui/options.js";

// The module runs against the shell's real kernel and primitives; only the
// control API is a fake, answering by method and path and recording every
// request.
const ID = "rho.t3";
const CONFIGURATION = `PATCH /extensions/${ID}/configuration`;
const WEBUI = fileURLToPath(new URL("../../webui/", import.meta.url));
const t = translator({ en: english });

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const aborted = () => Object.assign(new Error("The operation was aborted."), { name: "AbortError" });

const PROJECTS = [{ id: "fixture-project", title: "Fixture", workspaceRoot: "/work/fixture" }];
const PROVIDERS = [
  { agent: "Codex", harness: "Codex", available: true, default_model: "fixture-code", models: [] },
  { agent: "Review Claude", harness: "Claude Code", available: false, reason: "not ready (starting)", models: [] },
];

const t3Document = ({ status = {}, configuration = {}, ...rest } = {}) => ({
  status: { server: "host", url: "http://127.0.0.1:3773", project_id: "fixture-project", bearer: "saved", configured: true, issues: [], ...status },
  configuration: { server: "host", url: "http://127.0.0.1:3773", listen_port: 3773,
    project_id: "fixture-project", default_agent: "", workspace: { type: "root" }, ...configuration },
  service: { reachable: true, orchestration_protocol: 2 },
  projects: PROJECTS, providers: PROVIDERS, ...rest,
});
const applied = { saved: true, applied: true, published: true, restart_required: false, diagnostics: [], plugin: {} };

// Toasts go through the shell's own shelf, which refuses a tone it lacks.
function handleFor(slots, call = async () => t3Document(), { toasts = [], refreshes = { count: 0 }, navigations = [] } = {}) {
  const shelf = createToasts({ hold: null });
  return createHandle({ id: ID, slots, call,
    toast: (text, options = {}) => { shelf.toast(text, options); toasts.push([text, options.tone]); },
    navigate: (key) => navigations.push(key), dock: { open() {} }, primitives, el, translator,
    inventory: { refresh: async () => { refreshes.count += 1; } } });
}

// One owner side for the module's body: the Plugins page's keyed outlet for
// this plugin (the generic form whenever no module occupies the cell), or
// the frame's `main` outlet, which keeps a hidden page.
function mount(routes = {}, { page = false } = {}) {
  const slots = createSlots();
  const requests = [];
  const toasts = [];
  const refreshes = { count: 0 };
  const answers = {
    "GET /t3": () => t3Document(),
    "POST /t3/project": () => ({ project: PROJECTS[0], saved: true, applied: true, restart_required: false }),
    [CONFIGURATION]: () => applied, ...routes,
  };
  const handle = handleFor(slots, async (path, { method = "GET", body, signal } = {}) => {
    requests.push({ path, method, body, signal });
    if (signal?.aborted) throw aborted();
    return answers[`${method} ${path}`]({ body, signal });
  }, { toasts, refreshes });
  register(handle.ui);
  const container = el("div");
  const outlet = page ? keyedOutlet(slots, "main", container, { retain: true })
    : keyedOutlet(slots, "plugins.item.config", container, { fallback: () => ({ element: el("p", { text: "generic form" }) }) });
  if (page) outlet.show("t3", {}); else outlet.show(ID, { plugin: { id: ID }, refresh: async () => {} });
  return { slots, handle, outlet, container, requests, toasts, refreshes };
}

const field = (container, name) => container.querySelector(`[name="${name}"]`);
const button = (container, label) => container.querySelectorAll("button")
  .find((node) => node.textContent === label || node.getAttribute("aria-label") === label);
const shown = (node) => node.nodeType === 3 ? node.data : node.hidden ? "" : node.childNodes.map(shown).join("\n");
const facts = (container) => container.querySelectorAll(".settings-row").map(shown).join("\n");
const labels = (select) => select.options.map((option) => option.textContent);
const sent = (requests) => requests.map(({ method, path }) => `${method} ${path}`);
const bodies = (requests, line) => requests.filter(({ method, path }) => `${method} ${path}` === line).map(({ body }) => body);
const visibleAlert = (container) => container.querySelector('[role="alert"]:not([hidden]), .alert--warning:not([hidden])');
const contributions = (slots) => Object.keys(slots.catalog)
  .flatMap((name) => slots.entries(name).map((entry) => [name, entry.cell, entry.owner]));

test("registers the sidebar row, the T3 page and the Plugins configuration body", () => {
  const slots = createSlots();
  const first = handleFor(slots);
  register(first.ui);
  expect(contributions(slots)).toEqual([["main", "t3", ID], ["sidebar.panellist", "t3", ID], ["plugins.item.config", ID, ID]]);
  expect(slots.entries("sidebar.panellist")[0].order).toBe(30);
  // Enabling the plugin again registers the cached module with a fresh handle.
  first.dispose();
  expect(contributions(slots)).toEqual([]);
  register(handleFor(slots).ui);
  expect(contributions(slots)).toHaveLength(3);
});

test("the sidebar row opens the T3 page and follows the current panel and the rail", () => {
  const slots = createSlots();
  const navigations = [];
  register(handleFor(slots, undefined, { navigations }).ui);
  const nav = el("nav");
  const outlet = listOutlet(slots, "sidebar.panellist", nav, { current: "conversation", collapsed: false });
  const row = nav.querySelector('a[href="/panels/t3"]');
  expect(row.textContent).toBe("T3");
  expect(row.querySelector('[data-icon="terminal"]')).not.toBeNull();
  expect(row.hasAttribute("aria-current")).toBe(false);
  row.click();
  expect(navigations).toEqual(["t3"]);
  outlet.update({ current: "t3", collapsed: true });
  expect(row.getAttribute("aria-current")).toBe("page");
  expect(row.getAttribute("aria-label")).toBe("T3");
});

test("the T3 page holds the same body under its own heading and reads again whenever it is shown", async () => {
  const page = mount({}, { page: true });
  await flush();
  expect(page.container.querySelector("h1").textContent).toBe("T3 coding agents");
  expect(page.container.querySelectorAll("h2").map((node) => node.textContent)).toEqual(["Status", "Connection", "Project", "Coding agent"]);
  expect(field(page.container, "project_id")).not.toBeNull();
  expect(sent(page.requests)).toEqual(["GET /t3"]);
  page.outlet.show("conversation", {});
  page.outlet.show("t3", {});
  await flush();
  expect(sent(page.requests)).toEqual(["GET /t3", "GET /t3"]);

  const plugin = mount();
  await flush();
  expect(plugin.container.querySelector("h1")).toBeNull();
  expect(plugin.container.querySelectorAll("h3").map((node) => node.textContent)).toEqual(["Status", "Connection", "Project", "Coding agent"]);
});

test("the status card says where T3 runs, whether it answered and what setup still needs", async () => {
  const reachable = mount();
  expect(shown(reachable.container)).toContain("Reading the T3 status…");
  await flush();
  let text = facts(reachable.container);
  expect(text).toContain("On another host");
  expect(text).toContain("http://127.0.0.1:3773");
  expect(text).toContain("Connected");
  expect(text).toContain("Orchestration protocol 2");
  expect(text).toContain("Ready for coding work");
  // A saved bearer and installed programs are the normal state: the card says nothing of them.
  expect(text).not.toContain("Bearer");
  expect(text).not.toContain("Missing programs");
  expect(shown(reachable.container)).not.toContain("Reading the T3 status…");

  const unreachable = mount({ "GET /t3": () => t3Document({
    status: { server: "local", configured: false, bearer: "none", issues: ["Select a T3 project with rho t3 project or rho t3 create"],
      installed: { t3: true, codex: true, claude: false } },
    service: { reachable: false, error: "T3 RPC failed; reconcile the existing work" }, projects: null, providers: null }) });
  await flush();
  text = facts(unreachable.container);
  expect(text).toContain("Started by rho on this machine");
  expect(text).toContain("Not available");
  expect(text).toContain("T3 RPC failed; reconcile the existing work");
  expect(text).toContain("Needs setup");
  expect(text).toContain("Select a T3 project with rho t3 project or rho t3 create");
  expect(text).toContain("Bearer\n\n\nNot set");
  expect(text).not.toContain("t3: installed");
  expect(text).toContain("claude: not found");
  expect(shown(unreachable.container)).toContain("T3's project list could not be read. Check the status, then refresh.");
  expect(shown(unreachable.container)).toContain("T3's agent list could not be read. Check the status, then refresh.");
  expect(button(unreachable.container, "Create project").disabled).toBe(true);

  const unset = mount({ "GET /t3": () => t3Document({ status: { url: "" } }) });
  await flush();
  expect(facts(unset.container)).toContain("No service URL is set.");
});

test("the project is chosen from T3's list, keeping an unlisted saved project selectable", async () => {
  expect(projectChoices(PROJECTS, ["", ""], t)).toEqual([{ value: "", label: "Not set" }, { value: "fixture-project", label: "Fixture · /work/fixture" }]);
  expect(projectChoices(null, ["old-project", "old-project"], t).map(({ label }) => label)).toEqual(["Not set", "old-project"]);

  let current = t3Document({ configuration: { project_id: "old-project" } });
  const page = mount({
    "GET /t3": () => current,
    "POST /t3/project": ({ body }) => {
      current = t3Document({ configuration: { project_id: body.id } });
      return { project: PROJECTS[0], saved: true, applied: true, restart_required: false };
    },
    [CONFIGURATION]: ({ body }) => {
      current = t3Document({ configuration: { project_id: "" } });
      return { ...applied, operations: body.operations };
    },
  });
  await flush();
  const { container, requests } = page;
  const select = field(container, "project_id");
  expect(labels(select)).toEqual(["Not set", "Fixture · /work/fixture", "old-project · unavailable"]);
  expect(select.value).toBe("old-project");
  expect(button(container, "Use project").disabled).toBe(true);

  type(select, "fixture-project");
  expect(button(container, "Use project").disabled).toBe(false);
  select.form.requestSubmit();
  await flush();
  expect(sent(requests)).toEqual(["GET /t3", "POST /t3/project", "GET /t3"]);
  expect(bodies(requests, "POST /t3/project")).toEqual([{ id: "fixture-project" }]);
  expect(page.toasts).toEqual([["Coding work now uses Fixture.", "success"]]);
  expect(page.refreshes.count).toBe(1);
  expect(labels(select)).toEqual(["Not set", "Fixture · /work/fixture"]);
  expect(select.value).toBe("fixture-project");

  type(select, "");
  select.form.requestSubmit();
  await flush();
  expect(bodies(requests, CONFIGURATION)).toEqual([{ operations: [{ op: "unset", path: ["project_id"] }] }]);
  expect(page.toasts.at(-1)).toEqual(["No T3 project is selected.", "success"]);
  expect(page.refreshes.count).toBe(2);
});

test("creating a project posts an absolute path and refuses a relative one beside the field", async () => {
  const page = mount({ "POST /t3/project": ({ body }) => ({
    project: { id: "created-project", title: "app", workspaceRoot: body.path }, saved: true, applied: true, restart_required: false }) });
  await flush();
  const { container, requests } = page;
  const path = field(container, "path");
  const error = path.closest(".field").querySelector(".field__error");
  type(path, "work/app");
  path.form.requestSubmit();
  await flush();
  expect(sent(requests)).toEqual(["GET /t3"]);
  expect(error.hidden).toBe(false);
  expect(error.textContent).toBe("Enter an absolute path, starting with /.");
  expect(path.hasAttribute("aria-invalid")).toBe(true);

  type(path, " /work/app ");
  expect(error.hidden).toBe(true);
  button(container, "Create project").click();
  await flush();
  expect(sent(requests)).toEqual(["GET /t3", "POST /t3/project", "GET /t3"]);
  expect(bodies(requests, "POST /t3/project")).toEqual([{ path: "/work/app" }]);
  expect(path.value).toBe("");
  expect(page.toasts).toEqual([["Coding work now uses app.", "success"]]);
  expect(page.refreshes.count).toBe(1);
});

test("a refused or uncertain project choice stays beside the forms with the choice kept", async () => {
  const page = mount({ "POST /t3/project": () => {
    throw Object.assign(new Error("T3 project creation was not confirmed; inspect rho t3 projects before creating again"),
      { status: 502, details: { code: "t3_uncertain" } });
  } });
  await flush();
  const path = field(page.container, "path");
  type(path, "/work/app");
  path.form.requestSubmit();
  await flush();
  expect(visibleAlert(page.container).textContent).toBe("T3 project creation was not confirmed; inspect rho t3 projects before creating again");
  expect(path.value).toBe("/work/app");
  expect(path.closest("fieldset").disabled).toBe(false);
  expect(sent(page.requests)).toEqual(["GET /t3", "POST /t3/project"]);
  expect(page.refreshes.count).toBe(0);
});

test("the default agent is chosen from T3's agents; one that is not ready shows its reason and cannot be picked", async () => {
  expect(agentChoices(PROVIDERS, ["", ""], t)).toEqual([
    { value: "", label: "Automatic" },
    { value: "Codex", label: "Codex", disabled: false },
    { value: "Review Claude", label: "Review Claude · Claude Code · not ready (starting)", disabled: true },
  ]);
  expect(agentChoices(PROVIDERS, ["Gone", "Gone"], t).at(-1)).toEqual({ value: "Gone", label: "Gone · unavailable" });

  let current = t3Document();
  const answers = [applied, { saved: true, applied: false, published: false, restart_required: true, plugin: {} }];
  const page = mount({
    "GET /t3": () => current,
    [CONFIGURATION]: ({ body }) => {
      const [operation] = body.operations;
      current = t3Document({ configuration: { default_agent: operation.op === "set" ? operation.value : "" } });
      return answers.shift();
    },
  });
  await flush();
  const { container, requests } = page;
  const select = field(container, "default_agent");
  expect(labels(select)).toEqual(["Automatic", "Codex", "Review Claude · Claude Code · not ready (starting)"]);
  expect(select.options.map((option) => option.disabled)).toEqual([false, false, true]);
  expect(select.value).toBe("");
  expect(button(container, "Save agent").disabled).toBe(true);

  type(select, "Codex");
  select.form.requestSubmit();
  await flush();
  expect(select.value).toBe("Codex");
  type(select, "");
  select.form.requestSubmit();
  await flush();
  expect(bodies(requests, CONFIGURATION)).toEqual([
    { operations: [{ op: "set", path: ["default_agent"], value: "Codex" }] },
    { operations: [{ op: "unset", path: ["default_agent"] }] },
  ]);
  // A restart-only local service keeps the second save pending, and the page keeps saying so.
  expect(page.toasts).toEqual([["The default coding agent is saved.", "success"]]);
  const pending = visibleAlert(container);
  expect(pending.className).toBe("alert alert--warning");
  expect(pending.textContent).toBe("Saved. Restart rho to apply this change; the running T3 service keeps its current settings.");
  expect(page.refreshes.count).toBe(2);
  expect(select.value).toBe("");
});

test("connection options save only what changed, with the workspace as one object and the bearer write-only", () => {
  const saved = t3Document().configuration;
  const form = { server: "host", url: "http://127.0.0.1:3773", listenPort: "3773", token: "", clearToken: false,
    workspace: { type: "root", worktreePath: "", baseRef: "", branch: "" } };
  expect(connectionOperations(saved, form)).toEqual([]);
  expect(connectionOperations(saved, { ...form, token: " pasted-bearer " })).toEqual([{ op: "set", path: ["token"], value: "pasted-bearer" }]);
  expect(connectionOperations(saved, { ...form, token: "ignored", clearToken: true })).toEqual([{ op: "unset", path: ["token"] }]);
  expect(connectionOperations(saved, { server: "local", url: " ", listenPort: "3774",
    workspace: { type: "worktree", worktreePath: "", baseRef: " main ", branch: " rho/work " } })).toEqual([
    { op: "set", path: ["server"], value: "local" },
    { op: "unset", path: ["url"] },
    { op: "set", path: ["listen_port"], value: 3774 },
    { op: "set", path: ["workspace"], value: { type: "worktree", baseRef: "main", branch: "rho/work" } },
  ]);
  const worktree = { ...saved, workspace: { type: "existing_worktree", worktreePath: "/work/tree", branch: "unused" } };
  expect(connectionOperations(worktree, { ...form, workspace: { type: "existing_worktree", worktreePath: "/work/tree", baseRef: "", branch: "" } })).toEqual([]);
});

test("the options show only the fields the chosen location and workspace use, and save through the plugin configuration", async () => {
  const page = mount({ [CONFIGURATION]: () => {
    throw Object.assign(new Error("Settings were saved, but applying them failed."), { status: 503,
      details: { code: "plugin_configuration_unapplied", saved: true, applied: false } });
  } });
  const { container, requests } = page;
  const hidden = (name) => field(container, name).closest(".field").hidden;
  // Arranged before the first read answers, while the form is still closed.
  expect(["url", "listen_port", "worktree_path", "base_ref", "branch"].map(hidden)).toEqual([false, true, true, true, true]);
  await flush();
  expect(["url", "listen_port", "worktree_path", "base_ref", "branch"].map(hidden)).toEqual([false, true, true, true, true]);
  expect(button(container, "Save").disabled).toBe(true);

  type(field(container, "server"), "local");
  type(field(container, "workspace"), "existing_worktree");
  expect(["url", "listen_port", "worktree_path", "base_ref", "branch"].map(hidden)).toEqual([true, false, false, true, true]);
  expect(field(container, "url").disabled).toBe(true);
  expect(field(container, "worktree_path").required).toBe(true);
  type(field(container, "worktree_path"), "/work/tree");
  type(field(container, "listen_port"), "3774");
  button(container, "Save").click();
  await flush();
  expect(bodies(requests, CONFIGURATION)).toEqual([{ operations: [
    { op: "set", path: ["server"], value: "local" },
    { op: "set", path: ["listen_port"], value: 3774 },
    { op: "set", path: ["workspace"], value: { type: "existing_worktree", worktreePath: "/work/tree" } },
  ] }]);
  // Saved but not applied: the edit is done, the warning stays and the page reads again.
  const warning = visibleAlert(container);
  expect(warning.className).toBe("alert alert--warning");
  expect(warning.textContent).toBe("Settings were saved, but applying them failed.");
  expect(sent(requests).at(-1)).toBe("GET /t3");
  expect(page.refreshes.count).toBe(1);
  expect(field(container, "server").value).toBe("host");
});

test("a host bearer is typed and saved write-only, a saved one can be cleared, and a local one is issued by rho", async () => {
  let bearer = "none";
  const page = mount({
    "GET /t3": () => t3Document({ status: { bearer } }),
    [CONFIGURATION]: ({ body }) => { bearer = body.operations.some((op) => op.path[0] === "token" && op.op === "set") ? "saved"
      : body.operations.some((op) => op.path[0] === "token") ? "none" : bearer; return applied; },
    "POST /t3/token": ({ body }) => { expect(body).toEqual({}); bearer = "saved"; return { bearer: "saved", saved: true, applied: false, restart_required: true }; },
  });
  await flush();
  const { container, requests } = page;
  const token = field(container, "token");
  const hint = () => token.closest(".field").querySelector(".field__hint").textContent;
  expect(facts(container)).toContain("Bearer\n\n\nNot set");
  expect(token.type).toBe("password");
  expect(hint()).toBe("Paste the bearer the T3 service issued for rho. It is saved privately and never shown again.");
  expect(field(container, "clear_token").closest(".stack").hidden).toBe(true);
  type(token, "pasted-bearer");
  button(container, "Save").click();
  await flush();
  expect(bodies(requests, CONFIGURATION)).toEqual([{ operations: [{ op: "set", path: ["token"], value: "pasted-bearer" }] }]);
  // The typed bearer is gone from the form; the saved one is named, never shown.
  expect(token.value).toBe("");
  expect(hint()).toBe("A bearer is saved. Enter another to replace it.");
  expect(facts(container)).not.toContain("Bearer");
  expect(container.textContent).not.toContain("pasted-bearer");
  const clear = field(container, "clear_token");
  expect(clear.closest(".stack").hidden).toBe(false);
  clear.checked = true; clear.dispatchEvent(new Event("change", { bubbles: true }));
  expect(token.disabled).toBe(true);
  button(container, "Save").click();
  await flush();
  expect(bodies(requests, CONFIGURATION).at(-1)).toEqual({ operations: [{ op: "unset", path: ["token"] }] });
  expect(hint()).toBe("Paste the bearer the T3 service issued for rho. It is saved privately and never shown again.");
  expect(facts(container)).toContain("Bearer\n\n\nNot set");

  // A local service: no field to type into; rho issues and saves a bearer itself.
  type(field(container, "server"), "local");
  expect(token.closest(".field").hidden).toBe(true);
  const issue = button(container, "Issue a bearer");
  expect(issue.closest(".stack").hidden).toBe(false);
  issue.click();
  await flush();
  expect(sent(requests)).toContain("POST /t3/token");
  expect(visibleAlert(container).textContent).toBe("Saved. Restart rho to apply this change; the running T3 service keeps its current settings.");
  expect(button(container, "Issue a new bearer")).toBeDefined();
});

test("choices and options being edited survive a re-read and a props update", async () => {
  const page = mount();
  await flush();
  const { container } = page;
  const project = field(container, "project_id");
  type(project, "");
  type(field(container, "default_agent"), "Codex");
  type(field(container, "path"), "/work/draft");
  button(container, "Refresh").click();
  await flush();
  expect(sent(page.requests)).toEqual(["GET /t3", "GET /t3"]);
  page.outlet.update({ plugin: { id: ID, readiness: { ready: true } }, refresh: async () => {} });
  expect(field(container, "project_id")).toBe(project);
  expect(["project_id", "default_agent", "path"].map((name) => field(container, name).value))
    .toEqual(["", "Codex", "/work/draft"]);
  expect(button(container, "Use project").disabled).toBe(false);
  expect(sent(page.requests)).toEqual(["GET /t3", "GET /t3"]);
});

test("a failed read shows the refusal, keeps the forms closed, and Refresh reads again", async () => {
  let reads = 0;
  const page = mount({ "GET /t3": () => {
    reads += 1;
    if (reads === 1) throw Object.assign(new Error("T3 status could not be read."), { status: 502 });
    return t3Document();
  } });
  await flush();
  const { container } = page;
  const closed = () => ["project_id", "path", "default_agent", "server"].map((name) => field(container, name).closest("fieldset.stack").disabled);
  expect(visibleAlert(container).textContent).toBe("T3 status could not be read.");
  expect(shown(container)).not.toContain("Reading the T3 status…");
  expect(closed()).toEqual([true, true, true, true]);
  button(container, "Refresh").click();
  await flush();
  expect(visibleAlert(container)).toBeNull();
  expect(closed()).toEqual([false, false, false, false]);
});

test("dispose aborts the read in flight, whether the page leaves or the module goes away", async () => {
  const pending = { "GET /t3": ({ signal }) => new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(aborted()))) };
  const leaving = mount(pending);
  const [read] = leaving.requests;
  expect(read.signal.aborted).toBe(false);
  leaving.outlet.dispose();
  expect(read.signal.aborted).toBe(true);
  await flush();
  expect(leaving.container.childNodes).toHaveLength(0);

  const removed = mount(pending);
  removed.handle.dispose();
  expect(removed.requests[0].signal.aborted).toBe(true);
  await flush();
  expect(shown(removed.container)).toBe("generic form");

  const page = mount(pending, { page: true });
  page.outlet.dispose();
  expect(page.requests[0].signal.aborted).toBe(true);
});

const modules = readdirSync(WEBUI, { recursive: true }).filter((name) => name.endsWith(".js")).sort();
const source = (name) => readFileSync(join(WEBUI, name), "utf8");

test("every import in webui/ is relative and stays inside webui/", () => {
  expect(modules).toContain("index.js");
  for (const name of modules) {
    const specifiers = [...source(name).matchAll(/\bfrom\s*["']([^"']+)["']|\bimport\s*\(?\s*["']([^"']+)["']/g)]
      .map((match) => match[1] ?? match[2]);
    for (const specifier of specifiers) {
      expect(specifier, `${name} imports ${specifier}`).toMatch(/^\.\.?\//);
      const target = relative(WEBUI, resolve(dirname(join(WEBUI, name)), specifier));
      expect(target.startsWith(".."), `${name} imports ${specifier} from outside webui/`).toBe(false);
      expect(modules, `${name} imports a missing ${specifier}`).toContain(target);
    }
  }
});

test("every literal t() key exists in the catalog and every catalog key is used", () => {
  const code = modules.filter((name) => !name.startsWith("locales")).map(source).join("\n");
  const used = new Set([...code.matchAll(/\bt\(\s*"([^"]+)"/g)].map((match) => match[1]));
  expect(used.size).toBeGreaterThan(50);
  expect([...used].filter((key) => !Object.hasOwn(english, key))).toEqual([]);
  expect(Object.keys(english).filter((key) => !used.has(key))).toEqual([]);
});
