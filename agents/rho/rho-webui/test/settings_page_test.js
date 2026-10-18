import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, key } from "./support/dom.js";
import { createSlots } from "../webui/kernel/slots.js";
import { observable } from "../webui/kernel/observable.js";
import { el } from "../webui/kernel/dom.js";
import { settingsPage } from "../webui/features/settings/page.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

function harness(section = null) {
  const slots = createSlots();
  const state = observable({ document: { settings: { default_model: "a" } }, status: { connected: true }, identity: {}, loading: false, error: null });
  const refreshes = [];
  const shell = { slots, renderError: () => {}, setup: { state, refresh: async () => { refreshes.push(1); }, save: async () => null },
    settings: { request: observable(section ? { section } : null) } };
  const seen = [];
  slots.register("settings.section", { key: "general", order: 0, label: () => "General" }, (props) => ({
    element: el("div", { text: `general:${props.document.settings.default_model}` }), update: (next) => seen.push(next.document.settings.default_model),
  }));
  slots.register("settings.section", { key: "advanced", order: 20, label: () => "Defaults" }, () => ({ element: el("div", { text: "advanced" }) }));
  const view = settingsPage(shell);
  document.body.append(view.element);
  const tabs = () => [...view.element.querySelectorAll("[role=tab]")];
  const content = () => view.element.querySelector(".settings-page__content");
  const heading = () => view.element.querySelector(".settings-page__section-title").textContent;
  return { slots, state, shell, view, seen, refreshes, tabs, content, heading };
}

test("the page shows the first section, lists every section in order and rereads the documents when it comes into view", () => {
  const h = harness();
  expect(h.view.element.querySelector(".page__title").textContent).toBe("Settings");
  expect(h.tabs().map((tab) => tab.textContent)).toEqual(["General", "Defaults"]);
  expect(h.tabs()[0].getAttribute("aria-selected")).toBe("true");
  expect(h.heading()).toBe("General");
  expect(h.content().textContent).toBe("general:a");
  expect(h.content().getAttribute("aria-labelledby")).toBe(h.tabs()[0].id);
  expect(h.refreshes).toHaveLength(1);
  // Kept behind another panel, then shown again: the documents are reread once.
  h.view.update({ visible: false });
  h.view.update({ visible: false });
  expect(h.refreshes).toHaveLength(1);
  h.view.update({ visible: true });
  h.view.update({ visible: true });
  expect(h.refreshes).toHaveLength(2);
});

test("a tab swaps the section, an opener's section lands on it and moves it later, and sections see document changes", () => {
  const h = harness("advanced");
  expect(h.content().textContent).toBe("advanced");
  expect(h.heading()).toBe("Defaults");
  h.tabs()[0].click();
  expect(h.content().textContent).toBe("general:a");
  h.state.set({ ...h.state.get(), document: { settings: { default_model: "b" } } });
  expect(h.seen).toEqual(["b"]);
  h.shell.settings.request.set({ section: "advanced" });
  expect(h.content().textContent).toBe("advanced");
  // Arrow keys walk the tabs.
  const [general, advanced] = h.tabs();
  advanced.focus();
  key(advanced, "ArrowDown");
  expect(document.activeElement).toBe(general);
  key(general, "ArrowUp");
  expect(document.activeElement).toBe(advanced);
});

test("a section registered later appears without reopening, and the page survives a removed section", () => {
  const h = harness("advanced");
  const dispose = h.slots.register("settings.section", { key: "telegram", order: 10, label: () => "Telegram" }, () => ({ element: el("div", { text: "telegram" }) }));
  expect(h.tabs().map((tab) => tab.textContent)).toEqual(["General", "Telegram", "Defaults"]);
  dispose();
  expect(h.tabs().map((tab) => tab.textContent)).toEqual(["General", "Defaults"]);
  expect(h.content().textContent).toBe("advanced");
  h.view.dispose();
  expect(h.view.element.isConnected).toBe(false);
});

test("a failed refresh explains how to retry without replacing the selected section or its draft", () => {
  const h = harness("advanced");
  const draft = el("input", { value: "unsaved directory" });
  h.content().append(draft);
  h.state.update((value) => ({ ...value, error: new Error("Nexus is unreachable") }));

  const notice = h.view.element.querySelector(".alert--error");
  expect(notice?.textContent).toContain("Nexus is unreachable");
  expect(notice.textContent).toContain("try Refresh again");
  expect(notice.hidden).toBe(false);
  expect(h.heading()).toBe("Defaults");
  expect(draft.isConnected).toBe(true);
  expect(draft.value).toBe("unsaved directory");

  h.state.update((value) => ({ ...value, loading: true }));
  expect(notice.hidden).toBe(false);
  h.state.update((value) => ({ ...value, loading: false, error: null }));
  expect(notice.hidden).toBe(true);
  expect(draft.value).toBe("unsaved directory");
});
