import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, key, flush } from "./support/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { conversationBrowser } from "../webui/features/conversation/browser.js";
import { fakeBots } from "./support/bots.js";

let restore;
beforeEach(() => { restore = installDocument({ url: "http://localhost/" }); });
afterEach(() => restore());

const minutesAgo = (minutes) => new Date(Date.now() - minutes * 60_000).toISOString();
// Every row is rho's own unless it names another answerer.
const row = (id, fields = {}) => ({ public_id: id, title: `Title ${id}`, workspace_public_id: `w-${id}`, updated_at: minutesAgo(3), answering_user_public_id: "u-rho", ...fields });
const REVIEWER = { public_id: "u-reviewer", name: "reviewer", display_name: "Reviewer", scope: "steward", description: "Reviews pull requests" };

function browser(rows = [row("a"), row("b")], listFields = {}, { bots: listed = [] } = {}) {
  localStorage.removeItem("rho.browser.folded");
  const list = observable({ rows, next: null, archived: false, loading: false, loaded: true, error: null, ...listFields });
  const selection = observable({ id: "a" });
  const calls = [];
  const conversations = {
    list, selection,
    select: (...args) => calls.push(["select", ...args]),
    startNew: (options) => calls.push(["startNew", options]),
    rename: async (...args) => { calls.push(["rename", ...args]); return true; },
    archive: async (id) => calls.push(["archive", id]),
    restore: async (id) => calls.push(["restore", id]),
    setArchived: (flag) => { calls.push(["setArchived", flag]); list.update((value) => ({ ...value, archived: flag })); },
    refreshList: (options) => calls.push(["refreshList", options]),
  };
  const bots = fakeBots({ bots: listed });
  const view = conversationBrowser({ conversations, bots, settings: (bot) => calls.push(["settings", bot.name]) });
  document.body.append(view.element);
  const links = () => view.element.querySelectorAll(".browser__link");
  const groups = () => view.element.querySelectorAll(".browser__group");
  return { view, list, selection, calls, links, groups, bots, element: view.element };
}

test("rows link to their conversation, mark the open one and select in place on a plain click", () => {
  const b = browser();
  const [first, second] = b.links();
  expect(first.getAttribute("href")).toBe("/workspaces/w-a/conversations/a");
  expect(first.getAttribute("aria-current")).toBe("page");
  expect(second.hasAttribute("aria-current")).toBe(false);
  expect(second.querySelector(".browser__title").textContent).toBe("Title b");
  const plain = new Event("click", { button: 0 });
  second.dispatchEvent(plain);
  expect(plain.defaultPrevented).toBe(true);
  const tab = new Event("click", { button: 0, metaKey: true });
  second.dispatchEvent(tab);
  expect(tab.defaultPrevented).toBe(false);
  expect(b.calls).toEqual([["select", "b", { workspace: "w-b" }]]);
  b.selection.set({ id: "b" });
  expect(b.links()[1].getAttribute("aria-current")).toBe("page");
  expect(b.links()[0].hasAttribute("aria-current")).toBe(false);
});

test("a running row shows a spinner, an attention row a warning dot, and archived rows are marked", () => {
  const b = browser([row("a", { active_turn_public_id: "t" }), row("b", { attention: { reason: "waiting" } }), row("c", { archived_at: "now" })]);
  const [running, attention, archived] = b.element.querySelectorAll(".browser__row");
  expect(running.querySelector(".browser__lead .spinner")).not.toBeNull();
  expect(running.querySelector(".sr-only").textContent).toBe("Working · 3 minutes ago");
  expect(attention.querySelector(".browser__lead .dot--warn")).not.toBeNull();
  expect(attention.querySelector(".sr-only").textContent).toBe("Needs your attention · 3 minutes ago");
  expect(archived.className).toContain("browser__row--archived");
  // The lead column stays in an idle row, so titles align; the visible time
  // is the compact form and the full phrase is spoken.
  expect(archived.querySelector(".browser__lead").childNodes.length).toBe(0);
  expect(archived.querySelector(".sr-only").textContent).toBe("3 minutes ago");
  const time = running.querySelector(".browser__time");
  expect(time.textContent).toBe("3m");
  expect(time.getAttribute("aria-hidden")).toBe("true");
});

test("an ingress-bound row carries the channel glyph, named in full for the tooltip and the screen reader", () => {
  const bound = { channel: "telegram", label: "Telegram · Chat 42 · Topic 7", chat_id: 42, topic_id: 7 };
  const b = browser([row("a", { ingresses: [bound], active_turn_public_id: "t" }), row("b")]);
  const [marked, plain] = b.element.querySelectorAll(".browser__row");
  const mark = marked.querySelector(".browser__channel");
  expect(mark.hidden).toBe(false);
  expect(mark.querySelector(".icon").dataset.icon).toBe("channel");
  expect(mark.dataset.tip).toBe("Telegram · Chat 42 · Topic 7");
  expect(marked.querySelector(".sr-only").textContent).toBe("Working · Connected to Telegram · Chat 42 · Topic 7 · 3 minutes ago");
  expect(plain.querySelector(".browser__channel").hidden).toBe(true);
  expect(plain.querySelector(".sr-only").textContent).toBe("3 minutes ago");
  // The channel moved on: the mark goes with it.
  b.list.update((value) => ({ ...value, rows: value.rows.map((entry) => ({ ...entry, ingresses: [] })) }));
  expect(mark.hidden).toBe(true);
  expect("tip" in mark.dataset).toBe(false);
  expect(marked.querySelector(".sr-only").textContent).toBe("Working · 3 minutes ago");
});

test("Main conversations remain a flat list independent of the Bot directory", () => {
  const b = browser([row("a"), row("b")], {}, { bots: [REVIEWER] });
  expect(b.groups()).toHaveLength(0);
  expect(b.links()).toHaveLength(2);
  expect(b.element.textContent).not.toContain("Reviewer");
  b.bots.set({ bots: [] });
  expect(b.links()).toHaveLength(2);
  b.view.dispose();
});

test("rows keep their nodes across list refreshes, so focus inside a row stays", () => {
  const b = browser();
  const first = b.links()[0];
  first.focus();
  b.list.update((value) => ({ ...value, rows: [row("c"), ...value.rows] }));
  expect(b.links()[1]).toBe(first);
  expect(document.activeElement).toBe(first);
  b.list.update((value) => ({ ...value, rows: value.rows.filter((entry) => entry.public_id !== "a") }));
  expect(first.isConnected).toBe(false);
});

test("the row menu renames in place and archives or restores; an ingress-bound row cannot be changed", async () => {
  const b = browser([row("a"), row("b", { archived_at: "now" }), row("c", { ingresses: [{ channel: "telegram", label: "Telegram · Chat 1" }] })]);
  const menus = b.element.querySelectorAll(".browser__menu");
  menus[0].click();
  document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent === "Rename").click();
  const field = b.element.querySelector(".browser__rename");
  expect(field.value).toBe("Title a");
  field.value = "Renamed a";
  key(field, "Enter");
  await flush();
  expect(b.calls).toEqual([["rename", "a", "Renamed a"]]);
  expect(b.element.querySelector(".browser__rename")).toBeNull();
  expect(b.links()[0].querySelector(".browser__title").textContent).toBe("Renamed a");
  menus[0].click();
  document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent === "Archive").click();
  menus[1].click();
  document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent === "Restore").click();
  await flush();
  expect(b.calls.slice(1)).toEqual([["archive", "a"], ["restore", "b"]]);
  menus[2].click();
  expect(document.body.querySelectorAll("[role=menuitem]").filter((item) => item.disabled).map((item) => item.textContent)).toEqual(["Rename", "Archive"]);
});

test("Escape cancels a rename without writing", () => {
  const b = browser();
  b.element.querySelectorAll(".browser__menu")[1].click();
  document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent === "Rename").click();
  const field = b.element.querySelector(".browser__rename");
  field.value = "Not saved";
  key(field, "Escape");
  expect(b.calls).toEqual([]);
  expect(b.links()[1].hidden).toBe(false);
  expect(document.activeElement).toBe(b.links()[1]);
});

test("the options menu shows archived conversations and refreshes; paging shows more", () => {
  const b = browser([row("a")], { next: "cursor" });
  const options = b.element.querySelector(".browser__head button");
  expect(options.getAttribute("aria-label")).toBe("Conversation list options");
  options.click();
  const archived = document.body.querySelector("[role=menuitemcheckbox]");
  expect(archived.textContent).toBe("Show archived");
  expect(archived.getAttribute("aria-checked")).toBe("false");
  archived.click();
  options.click();
  document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent === "Refresh").click();
  b.element.querySelector(".browser__more").click();
  expect(b.calls).toEqual([["setArchived", true], ["refreshList", undefined], ["refreshList", { more: true }]]);
});

test("empty, loading and failed lists each say so — nothing final before the first read — and the rail hides the browser", () => {
  const b = browser([]);
  // Before the first read answers, the sidebar shows a skeleton, not "no conversations yet".
  b.list.update((value) => ({ ...value, loaded: false }));
  expect(b.element.querySelector(".browser__empty")).toBeNull();
  expect(b.element.querySelector(".browser__status .skeleton")).not.toBeNull();
  b.list.update((value) => ({ ...value, loaded: true }));
  expect(b.element.querySelector(".browser__empty").textContent).toBe("Your conversations will appear here.");
  b.list.update((value) => ({ ...value, archived: true }));
  expect(b.element.querySelector(".browser__empty").textContent).toBe("No archived conversations.");
  b.list.update((value) => ({ ...value, loading: true }));
  expect(b.element.querySelector(".browser__status .skeleton")).not.toBeNull();
  b.list.update((value) => ({ ...value, loading: false, error: new Error("Nexus is unreachable") }));
  expect(b.element.querySelector(".browser__empty").textContent).toBe("Nexus is unreachable");
  b.view.update({ collapsed: true });
  expect(b.element.hidden).toBe(true);
  b.view.update({ collapsed: false });
  expect(b.element.hidden).toBe(false);
});
