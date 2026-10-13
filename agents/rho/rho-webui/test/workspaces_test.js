import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush, type } from "./support/dom.js";
import { createWorkspaces, WORKSPACE_KEY } from "./../webui/shell/workspaces.js";
import { workspaceSwitcher, workspaceDetail } from "../webui/shell/workspace_switcher.js";
import { hueOf, initialOf } from "../webui/kernel/format.js";
import { createList } from "../webui/features/conversation/list.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const ROWS = [
  { public_id: "w-own", name: "rho", access_mode: "private", dedicated: true },
  { public_id: "w-home", name: "Home", access_mode: "private", dedicated: false },
  { public_id: "w-team", name: "Team", access_mode: "account_wide", dedicated: false },
];

function memory(entries = {}) {
  const map = new Map(Object.entries(entries));
  return { getItem: (key) => map.get(key) ?? null, setItem: (key, value) => map.set(key, value), removeItem: (key) => map.delete(key), map };
}

function harness({ address = {}, storage = memory(), rows = ROWS, selection = "w-own", create = null } = {}) {
  let location = { panel: null, conversation: null, workspace: null, plugin: null, ...address };
  const pushes = [];
  const listeners = new Set();
  const router = { read: () => ({ ...location }), push(changes) { location = { ...location, ...changes }; pushes.push(changes); },
    replace(changes) { location = { ...location, ...changes }; }, subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    // A popstate: the address changed under the page.
    pop(changes) { location = { ...location, ...changes }; for (const listener of [...listeners]) listener({ ...location }); } };
  const requests = [];
  const call = async (path, options = {}) => {
    requests.push([options.method || "GET", path, options.body]);
    if (options.method === "POST") return create ? create(options.body) : { workspace: { public_id: "w-new", name: options.body.name, access_mode: "private", dedicated: false } };
    return { workspaces: rows, workspace: rows.find((row) => row.public_id === selection) || null };
  };
  const controller = new AbortController();
  const workspaces = createWorkspaces({ call, signal: controller.signal, router, storage });
  return { workspaces, router, pushes, requests, storage, controller, location: () => location };
}

test("the current workspace is the address's, else the remembered one, else the daemon's; an unlisted memory falls back", async () => {
  const addressed = harness({ address: { workspace: "w-team" }, storage: memory({ [WORKSPACE_KEY]: "w-home" }) });
  expect(addressed.workspaces.current()).toBe("w-team");
  await addressed.workspaces.refresh();
  expect(addressed.workspaces.current()).toBe("w-team");
  expect(addressed.storage.map.get(WORKSPACE_KEY)).toBe("w-team");

  const remembered = harness({ storage: memory({ [WORKSPACE_KEY]: "w-home" }) });
  expect(remembered.workspaces.current()).toBe("w-home");
  await remembered.workspaces.refresh();
  expect(remembered.workspaces.state.get()).toMatchObject({ current: "w-home", selection: "w-own", loaded: true });

  const stale = harness({ storage: memory({ [WORKSPACE_KEY]: "w-gone" }) });
  // A reader waiting on `ready()` sees the corrected choice, never the stale memory.
  let settled = false;
  const waited = stale.workspaces.ready().then(() => { settled = true; return stale.workspaces.current(); });
  await Promise.resolve();
  expect(settled).toBe(false);
  await stale.workspaces.refresh();
  expect(await waited).toBe("w-own");
  expect(stale.workspaces.current()).toBe("w-own");
  expect(stale.storage.map.has(WORKSPACE_KEY)).toBe(false);
  expect(stale.workspaces.row()).toMatchObject({ name: "rho" });
});

test("switching remembers the choice, addresses it only when it is not the daemon's, and clears the open conversation", async () => {
  const h = harness({ address: { conversation: "c-1", workspace: "w-own" } });
  await h.workspaces.refresh();
  expect(h.workspaces.switchTo("w-home")).toBe(true);
  expect(h.pushes.at(-1)).toEqual({ panel: null, plugin: null, conversation: null, workspace: "w-home" });
  expect(h.storage.map.get(WORKSPACE_KEY)).toBe("w-home");
  expect(h.workspaces.addressed()).toBe("w-home");
  expect(h.workspaces.switchTo("w-home")).toBe(false);
  h.workspaces.switchTo("w-own");
  expect(h.pushes.at(-1)).toEqual({ panel: null, plugin: null, conversation: null, workspace: null });
  expect(h.storage.map.has(WORKSPACE_KEY)).toBe(false);
  // Following an opened conversation into its workspace rewrites nothing.
  const pushed = h.pushes.length;
  h.workspaces.adopt("w-team");
  expect(h.workspaces.current()).toBe("w-team");
  expect(h.pushes).toHaveLength(pushed);
  h.workspaces.adopt("w-unknown");
  expect(h.workspaces.current()).toBe("w-team");
});

test("Back and Forward move the address and the page's workspace follows; an unknown one is ignored", async () => {
  const h = harness();
  await h.workspaces.refresh();
  h.workspaces.switchTo("w-home");
  const pushed = h.pushes.length;
  h.router.pop({ workspace: null, conversation: null });
  expect(h.workspaces.current()).toBe("w-own");
  expect(h.storage.map.has(WORKSPACE_KEY)).toBe(false);
  h.router.pop({ workspace: "w-team", conversation: "c-9" });
  expect(h.workspaces.current()).toBe("w-team");
  expect(h.storage.map.get(WORKSPACE_KEY)).toBe("w-team");
  h.router.pop({ workspace: "w-unknown" });
  expect(h.workspaces.current()).toBe("w-team");
  expect(h.pushes).toHaveLength(pushed);
  h.controller.abort();
  h.router.pop({ workspace: "w-home" });
  expect(h.workspaces.current()).toBe("w-team");
});

test("opening a conversation refreshes an old workspace directory and cannot pull a later address back", async () => {
  const rows = [...ROWS];
  const h = harness({ rows });
  await h.workspaces.refresh();
  rows.push({ public_id: "w-later", name: "Later Bot home" });
  h.router.pop({ workspace: "w-later", conversation: "bot-current" });
  h.workspaces.adopt("w-later");
  await flush();
  expect(h.workspaces.current()).toBe("w-later");
  expect(h.workspaces.row().name).toBe("Later Bot home");
  expect(h.pushes).toEqual([]);

  rows.push({ public_id: "w-newer", name: "Another home" });
  h.router.pop({ workspace: "w-newer", conversation: "other-current" });
  h.workspaces.adopt("w-newer");
  h.router.pop({ workspace: "w-team", conversation: "main-current" });
  await flush();
  expect(h.workspaces.current()).toBe("w-team");
  expect(h.location()).toMatchObject({ workspace: "w-team", conversation: "main-current" });
});

test("the first read writes a remembered workspace into a hero address and a stale one out, and leaves a conversation's alone", async () => {
  const remembered = harness({ storage: memory({ [WORKSPACE_KEY]: "w-home" }) });
  await remembered.workspaces.refresh();
  expect(remembered.location().workspace).toBe("w-home");
  const stale = harness({ address: { workspace: "w-gone" } });
  await stale.workspaces.refresh();
  expect(stale.location().workspace).toBeNull();
  const opened = harness({ address: { conversation: "c-1" }, storage: memory({ [WORKSPACE_KEY]: "w-home" }) });
  await opened.workspaces.refresh();
  expect(opened.location()).toMatchObject({ conversation: "c-1", workspace: null });
  expect(opened.workspaces.current()).toBe("w-home");
});

test("creating a workspace posts its name, reads the list again and switches to it", async () => {
  const h = harness({ create: (body) => ({ workspace: { public_id: "w-new", name: body.name } }) });
  await h.workspaces.refresh();
  h.requests.length = 0;
  const row = await h.workspaces.create("Side project");
  expect(row).toEqual({ public_id: "w-new", name: "Side project" });
  expect(h.requests.map(([method, path]) => `${method} ${path}`)).toEqual(["POST /workspaces", "GET /workspaces"]);
  expect(h.requests[0][2]).toEqual({ name: "Side project" });
  expect(h.workspaces.current()).toBe("w-new");
  expect(h.pushes.at(-1)).toEqual({ panel: null, plugin: null, conversation: null, workspace: "w-new" });
});

test("the conversation list reads the page's workspace", async () => {
  const paths = [];
  let scope = null;
  const list = createList({ call: async (path) => { paths.push(path); return { conversations: [], pagination: {} }; }, signal: new AbortController().signal, workspace: () => scope });
  await list.refresh();
  expect(paths.at(-1)).toBe("/conversations?scope=main&limit=40&archived=0");
  scope = "w-team";
  await list.refresh();
  expect(paths.at(-1)).toBe("/conversations?scope=main&limit=40&archived=0&workspace_public_id=w-team");
});

for (const oldPageFirst of [true, false]) {
  test(`a previous workspace's page arriving ${oldPageFirst ? "before" : "after"} the new list cannot change it`, async () => {
    const h = harness();
    await h.workspaces.refresh();
    const reads = [];
    const list = createList({
      call: (path) => new Promise((resolve) => reads.push({ path, resolve })),
      signal: h.controller.signal, workspace: () => h.workspaces.current(),
    });
    const initial = list.refresh();
    await flush();
    reads[0].resolve({ conversations: [{ public_id: "own-first" }], pagination: { next_after: "own-next" } });
    await initial;

    const oldPage = list.refresh({ more: true });
    await flush();
    expect(reads[1].path).toBe("/conversations?scope=main&limit=40&archived=0&workspace_public_id=w-own&after=own-next");
    h.workspaces.switchTo("w-team");
    const newList = list.refresh();
    await flush();
    expect(reads[2].path).toBe("/conversations?scope=main&limit=40&archived=0&workspace_public_id=w-team");

    const finishOldPage = async () => {
      reads[1].resolve({ conversations: [{ public_id: "own-late" }], pagination: { next_after: "own-later" } });
      await oldPage;
    };
    if (oldPageFirst) {
      await finishOldPage();
      expect(list.state.get().loading).toBe(true);
      expect(list.state.get().rows.map((row) => row.public_id)).toEqual(["own-first"]);
    }
    reads[2].resolve({ conversations: [{ public_id: "team-first" }], pagination: { next_after: "team-next" } });
    await newList;
    if (!oldPageFirst) await finishOldPage();
    expect(list.state.get()).toMatchObject({
      rows: [{ public_id: "team-first" }], next: "team-next", loading: false, loaded: true, error: null,
    });
    h.controller.abort();
  });
}

test("a named mark is the first character, and its colour follows the id, not the name", () => {
  expect(initialOf("  home office")).toBe("H");
  expect(initialOf("研究")).toBe("研");
  expect(initialOf("👩‍💻 dev")).toBe("👩");
  expect(initialOf("   ")).toBe("");
  const hue = hueOf("0199c7f4-1c2e-7d3a-9b1e-7c2f3a4b5c6d");
  expect(Number.isInteger(hue) && hue >= 0 && hue < 360).toBe(true);
  expect(hueOf("0199c7f4-1c2e-7d3a-9b1e-7c2f3a4b5c6d")).toBe(hue);
  expect(hueOf("0199c7f4-1c2e-7d3a-9b1e-7c2f3a4b5c6e")).not.toBe(hue);
});

test("the switcher names the current workspace, lists every one with the current checked, and creates one from a dialog", async () => {
  const h = harness({ storage: memory({ [WORKSPACE_KEY]: "w-home" }) });
  const toasts = [];
  const shell = { workspaces: h.workspaces, toast: (text, options) => toasts.push([text, options?.tone]) };
  const switcher = workspaceSwitcher({ shell });
  document.body.append(switcher.element);
  const mark = switcher.element.querySelector(".sidebar__workspace .mark");
  const label = switcher.element.querySelector(".sidebar__workspace-name");
  // Before the account answers, the mark is rho's own glyph.
  expect(label.textContent).toBe("rho");
  expect(mark.querySelector('.icon[data-icon="rho"]')).not.toBeNull();
  expect(mark.classList.contains("mark--named")).toBe(false);
  await h.workspaces.refresh();
  expect(label.textContent).toBe("Home");
  expect(switcher.element.getAttribute("aria-label")).toBe("Workspace: Home");
  // A named workspace wears its initial on a colour its id picks.
  expect(mark.textContent).toBe("H");
  expect(mark.classList.contains("mark--named")).toBe(true);
  expect(mark.style.getPropertyValue("--hue")).toBe(String(hueOf("w-home")));
  switcher.element.click();
  const items = document.querySelectorAll('[role="menu"] [role^="menuitem"]');
  expect(items.map((node) => [node.querySelector(".menu__label").textContent, node.getAttribute("aria-checked")])).toEqual([
    ["rho", "false"], ["Home", "true"], ["Team", "false"], ["New workspace…", null],
  ]);
  expect(items[0].querySelector(".menu__detail").textContent).toBe("rho's own workspace · rho's default");
  expect(items[2].querySelector(".menu__detail").textContent).toBe("Shared with the account");
  expect(workspaceDetail(ROWS[1], "w-home")).toBe("Private · rho's default");
  items[2].click();
  expect(h.workspaces.current()).toBe("w-team");
  expect(label.textContent).toBe("Team");
  expect(mark.textContent).toBe("T");
  expect(mark.style.getPropertyValue("--hue")).toBe(String(hueOf("w-team")));

  switcher.element.click();
  document.querySelectorAll('[role="menu"] [role="menuitem"]').at(-1).click();
  const dialog = document.querySelector("dialog.modal");
  expect(dialog.open).toBe(true);
  const name = dialog.querySelector('input[name="name"]');
  name.form.requestSubmit();
  expect(dialog.querySelector(".field__error").textContent).toBe("Give the workspace a name.");
  type(name, "  Side project ");
  name.form.requestSubmit();
  await flush();
  expect(h.requests.find(([method]) => method === "POST")[2]).toEqual({ name: "Side project" });
  expect(h.workspaces.current()).toBe("w-new");
  expect(toasts).toEqual([["Side project is your current workspace.", "success"]]);
  expect(document.querySelector("dialog.modal")).toBeNull();
  switcher.dispose();
});
