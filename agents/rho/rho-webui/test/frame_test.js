import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, key } from "./support/dom.js";
import { createSlots } from "../webui/kernel/slots.js";
import { observable } from "../webui/kernel/observable.js";
import { el } from "../webui/kernel/dom.js";
import { createFrame } from "../webui/shell/frame.js";
import { createWorkspaces } from "../webui/shell/workspaces.js";
import { fakeBots } from "./support/bots.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => { restore(); });

function harness({ width = 1440 } = {}) {
  globalThis.innerWidth = width;
  const slots = createSlots();
  const navigation = observable("conversation");
  const router = { read: () => ({ panel: null }), push() {}, replace() {}, subscribe: () => () => {} };
  const selection = observable({ id: "c-1", workspace: "w-1" });
  const controller = new AbortController();
  // The real conversation browser mounts in the sidebar; it needs a
  // controller-shaped object and renders its empty state.
  const conversations = {
    selection, list: observable({ rows: [], next: null, archived: false, loading: false, error: null }),
    select() {}, startNew() {}, refreshList() {}, setArchived() {}, rename: async () => true, archive() {}, restore() {},
  };
  const workspaces = createWorkspaces({ call: async () => ({ workspaces: [{ public_id: "w-1", name: "Personal", access_mode: "private", dedicated: false }],
    workspace: { public_id: "w-1" } }), signal: controller.signal, router, storage: null });
  const opened = [];
  const shell = {
    signal: controller.signal, navigation, navigate: (next) => navigation.set(next), router, renderError: (error) => { throw error; },
    setup: { state: observable({ daemon: { workspace: { state: "adopted" } }, error: null }) },
    conversations, workspaces, bots: fakeBots(), settings: { open: () => { opened.push("settings"); navigation.set("settings"); } }, toast() {},
  };
  slots.register("main", { key: "conversation" }, () => ({ element: el("section", { class: "conversation-panel", text: "conversation" }), update: () => {} }));
  slots.register("main", { key: "plugins" }, () => ({ element: el("section", { class: "plugins-page", text: "plugins" }) }));
  slots.register("main", { key: "settings" }, () => ({ element: el("section", { class: "settings-page", text: "settings" }) }));
  slots.register("main", { key: "nexus" }, () => ({ element: el("section", { class: "nexus-page", text: "nexus" }) }));
  slots.register("sidebar.panellist", { id: "plugins", order: 10 }, (props) => ({ element: el("button", { class: "panel-row", text: `plugins:${props.collapsed}` }) }));
  const root = el("div", { id: "root" });
  document.body.append(root);
  const frame = createFrame({ root, slots, shell, ui: {} });
  frame.mount();
  return { frame, root, shell, navigation, slots, controller, selection, opened };
}

test("the sidebar's foot links Nexus and Settings; each opens its page in place and marks itself current", () => {
  const { root, opened } = harness();
  const [nexus, settings] = root.querySelectorAll(".sidebar__settings");
  expect(nexus.getAttribute("href")).toBe("/panels/nexus");
  expect(nexus.getAttribute("aria-label")).toBe("Nexus");
  const toNexus = new Event("click", { button: 0 });
  nexus.dispatchEvent(toNexus);
  expect(toNexus.defaultPrevented).toBe(true);
  expect(root.querySelector(".nexus-page").hidden).toBe(false);
  expect(nexus.getAttribute("aria-current")).toBe("page");
  expect(settings.getAttribute("href")).toBe("/panels/settings");
  expect(settings.hasAttribute("aria-current")).toBe(false);
  const click = new Event("click", { button: 0 });
  settings.dispatchEvent(click);
  expect(click.defaultPrevented).toBe(true);
  expect(opened).toEqual(["settings"]);
  expect(root.querySelector(".settings-page").hidden).toBe(false);
  expect(root.querySelector(".conversation-panel").hidden).toBe(true);
  expect(settings.getAttribute("aria-current")).toBe("page");
  const tab = new Event("click", { button: 0, metaKey: true });
  settings.dispatchEvent(tab);
  expect(tab.defaultPrevented).toBe(false);
});

test("the Main conversation browser does not incorporate the Bot directory", () => {
  const { root, shell } = harness();
  shell.bots.set({ bots: [{ public_id: "bot-new", name: "new", display_name: "New bot", model_standing: "available" }] });
  expect(root.querySelector(".sidebar__browser").textContent).not.toContain("New bot");
});

test("the frame lays out three columns from the viewport and shows the navigated main panel", () => {
  const { frame, root, shell } = harness();
  expect(frame.element.dataset.sidebar).toBe("expanded");
  expect(frame.element.dataset.dock).toBe("closed");
  expect(frame.element.style.getPropertyValue("--sidebar-width")).toBe("280px");
  expect(root.querySelector(".frame__main .conversation-panel")).not.toBeNull();
  expect(root.querySelector(".sidebar__browser").childElementCount).toBeGreaterThan(0);
  shell.navigate("plugins");
  expect(root.querySelector(".plugins-page").hidden).toBe(false);
  expect(root.querySelector(".conversation-panel").hidden).toBe(true);
  expect(root.querySelector(".panel-row").textContent).toBe("plugins:false");
});

test("the sidebar collapses to a rail by choice or below 1024px, and Mod+Alt+B toggles it", () => {
  const { frame, root } = harness({ width: 1000 });
  expect(frame.element.dataset.sidebar).toBe("rail");
  expect(frame.element.style.getPropertyValue("--sidebar-width")).toBe("56px");
  expect(root.querySelector(".sidebar").classList.contains("sidebar--rail")).toBe(true);
  expect(root.querySelector(".panel-row").textContent).toBe("plugins:true");
  // The rail is the expanded column's order with the text gone: the toggle,
  // then the workspace mark, then New and the panels; one icon per row.
  const sidebar = root.querySelector(".sidebar");
  expect([...sidebar.children].slice(0, 3).map((node) => node.className)).toEqual(["sidebar__brand", "sidebar__workspace", "sidebar__new"]);
  expect(sidebar.querySelector(".sidebar__brand .sidebar__toggle")).not.toBeNull();
  expect(sidebar.querySelector(".sidebar__brand .sidebar__wordmark").textContent).toBe("rho");
  key(window, "b", { metaKey: true, altKey: true });
  expect(frame.element.dataset.sidebar).toBe("expanded");
  expect(JSON.parse(localStorage.getItem("rho.layout")).collapsed).toBe(false);
  root.querySelector(".sidebar__toggle").click();
  expect(frame.element.dataset.sidebar).toBe("rail");
});

test("below 768px the sidebar is a drawer: the leading button opens it, Escape and navigation close it", () => {
  const { frame, root, shell, selection } = harness({ width: 390 });
  expect(frame.element.dataset.sidebar).toBe("hidden");
  const leading = root.querySelector(".frame__leading");
  expect(leading.hidden).toBe(false);
  leading.click();
  expect(frame.element.classList.contains("frame--drawer")).toBe(true);
  expect(root.querySelector(".frame__main").inert).toBe(true);
  key(window, "Escape");
  expect(frame.element.classList.contains("frame--drawer")).toBe(false);
  expect(document.activeElement).toBe(leading);
  key(window, "b", { ctrlKey: true, altKey: true });
  shell.navigate("plugins");
  expect(frame.element.classList.contains("frame--drawer")).toBe(false);
  leading.click();
  selection.set({ id: "c-2", workspace: "w-1" });
  expect(frame.element.classList.contains("frame--drawer")).toBe(false);
});

test("opening the dock gives it a track on a wide viewport, makes room on a medium one and fills a phone", () => {
  const wide = harness({ width: 1440 });
  wide.frame.dock.open("task", { params: {} });
  expect(wide.frame.element.dataset.dock).toBe("docked");
  expect(wide.frame.element.style.getPropertyValue("--dock-width")).toBe("648px");
  expect(wide.root.hasAttribute("data-dock-open")).toBe(true);
  wide.frame.dock.close();
  expect(wide.frame.element.dataset.dock).toBe("closed");
  wide.frame.dispose();
  const medium = harness({ width: 900 });
  key(window, "b", { metaKey: true, altKey: true });
  expect(medium.frame.element.dataset.sidebar).toBe("expanded");
  medium.frame.dock.open("task", { params: {} });
  expect(medium.frame.element.dataset.sidebar).toBe("rail");
  expect(medium.frame.element.dataset.dock).toBe("docked");
  key(window, "b", { metaKey: true, altKey: true });
  expect(medium.frame.element.dataset.dock).toBe("overlay");
  expect(medium.frame.element.style.getPropertyValue("--dock-width")).toBe("0px");
  medium.frame.dispose();
  const phone = harness({ width: 390 });
  phone.frame.dock.open("task", { params: {} });
  expect(phone.frame.element.dataset.dock).toBe("fullscreen");
});

test("resize handles move by keyboard within the limits and persist the layout", () => {
  const { frame } = harness();
  const handle = frame.element.querySelector(".frame__handle");
  key(handle, "ArrowRight");
  expect(frame.layout.get().sidebar).toBe(296);
  key(handle, "End");
  expect(frame.layout.get().sidebar).toBe(420);
  key(handle, "Home");
  expect(frame.layout.get().sidebar).toBe(264);
  expect(JSON.parse(localStorage.getItem("rho.layout")).sidebar).toBe(264);
});
