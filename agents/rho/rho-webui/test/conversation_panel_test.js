import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, key, type, flush } from "./support/dom.js";
import { el } from "../webui/kernel/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { fakeBots } from "./support/bots.js";
import { createSlots } from "../webui/kernel/slots.js";
import { createConversations } from "../webui/features/conversation/controller.js";
import { createWorkspaces } from "../webui/shell/workspaces.js";
import { conversationPanel } from "../webui/features/conversation/panel.js";
import { conversationBrowser } from "../webui/features/conversation/browser.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const named = (root, label) => root.querySelectorAll("button").find((node) => node.getAttribute("aria-label") === label);
const settle = async () => { for (let index = 0; index < 30; index += 1) await Promise.resolve(); await flush(); };
const turn = (position, fields = {}) => ({ public_id: `t-${position}`, position, role: position % 2 ? "user" : "assistant", status: "completed",
  active_variant: { public_id: `v-${position}`, content: `message ${position}` }, ...fields });

function page({ address = {}, detail = { public_id: "c-1", title: "First", workspace_public_id: "w-1" }, latest = [turn(3), turn(4)], rows = [] } = {}) {
  const requests = [];
  const documents = { detail, latest };
  const handlers = {
    "POST /followers/attach": () => ({}),
    "GET /conversations/detail": ({ query }) => ({ conversation: { ...documents.detail, public_id: query.get("public_id") } }),
    "GET /conversations/turns": ({ query }) => (query.get("before_position")
      ? { turns: [turn(1), turn(2)], pagination: { before_position: null, has_older: false } }
      : { turns: documents.latest, pagination: { before_position: 3, has_older: true } }),
    "GET /conversations/modes": () => ({ modes: { available: true, code_mode_available: true, code_mode: true, subagent: true } }),
    "GET /asks": () => ({ asks: [] }), "GET /inputs": () => ({ inputs: [] }), "GET /followers": () => ({ followers: [] }),
    "GET /models": () => ({ models: [{ ref: "local/model" }] }), "GET /runners": () => ({ runners: [{ public_id: "runner-own", display_name: "Laptop", own: true }] }),
    "GET /workspaces": () => ({ workspace: { public_id: "w-1", display_name: "Default" }, workspaces: [{ public_id: "w-1", display_name: "Default" }] }),
    "GET /conversations": () => ({ conversations: rows, pagination: {} }),
    "PATCH /conversations": () => ({}),
  };
  const call = async (path, options = {}) => {
    const method = options.method || "GET";
    const route = path.split("?")[0];
    requests.push({ method, route, body: options.body });
    const handler = handlers[`${method} ${route}`];
    if (!handler) throw new Error(`unexpected ${method} ${path}`);
    return handler({ query: new URLSearchParams(path.split("?")[1] || "") });
  };
  const streams = [];
  const follow = (_id, { signal, onFrame }) => new Promise((_resolve, reject) => {
    streams.push({ onFrame });
    signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })), { once: true });
  });
  let location = { panel: null, conversation: null, workspace: null, plugin: null, ...address };
  const router = { read: () => ({ ...location }), push(changes) { location = { ...location, ...changes }; }, replace(changes) { location = { ...location, ...changes }; }, subscribe: () => () => {} };
  const setup = { state: observable({ document: { settings: { default_model: "local/model" } }, status: { connected: true, model: { ready: true }, defaults: { conversation_modes: { available: true, code_mode_available: true, code_mode: true, subagent: true } } } }),
    progress: () => ({ step: "ready", title: "rho is ready to use", ready: true }) };
  const session = new AbortController();
  const workspaces = createWorkspaces({ call, signal: session.signal, router, storage: null });
  const conversations = createConversations({ call, follow, artifactBytes: async () => new Blob(), signal: session.signal, toast: () => {},
    router, setup, workspaces, openDock: () => {}, openSettings: () => {} });
  const slots = createSlots();
  const toggles = [];
  const shell = { slots, setup, renderError: (error) => { throw error; }, inventory: { state: observable({ plugins: [] }) }, bots: fakeBots(),
    dock: { toggle: () => toggles.push(1), open: () => {} }, settings: { open: () => {} }, openPlugin: () => {} };
  const panel = conversationPanel({ conversations, shell });
  document.body.append(panel.element);
  workspaces.refresh();
  conversations.start();
  return { conversations, panel, requests, documents, handlers, streams, slots, toggles, element: panel.element };
}

test("a new conversation shows the hero with the composer; an opened one shows its transcript above the same composer", async () => {
  const p = page();
  await settle();
  expect(p.element.dataset.layout).toBe("hero");
  expect(p.element.querySelector(".hero__title").textContent).toBe("What should rho work on?");
  const composer = p.element.querySelector(".composer");
  expect(composer.parentNode.className).toBe("hero__composer");
  expect(p.element.querySelector("h1").textContent).toBe("New conversation");
  type(composer.querySelector("textarea"), "draft for a new one");
  await p.conversations.select("c-1");
  await settle();
  expect(p.element.dataset.layout).toBe("thread");
  expect(p.element.querySelector(".composer")).toBe(composer);
  expect(composer.parentNode.className).toBe("seat__composer");
  expect(composer.querySelector("textarea").value).toBe("");
  expect(p.element.querySelector("h1").textContent).toBe("First");
  expect(p.element.querySelectorAll(".transcript__turns > .turn").map((node) => node.textContent.includes("message"))).toEqual([true, true]);
  p.conversations.startNew();
  expect(composer.querySelector("textarea").value).toBe("draft for a new one");
});

test("a generated title read updates the open header and sidebar through the existing conversation cache", async () => {
  const detail = { public_id: "c-1", title: "Untitled", workspace_public_id: "w-1" };
  const p = page({ address: { conversation: "c-1" }, detail, rows: [detail] });
  const browser = conversationBrowser({ conversations: p.conversations });
  document.body.append(browser.element);
  await settle();
  expect(p.element.querySelector("h1").textContent).toBe("Untitled");
  expect(browser.element.querySelector(".browser__title").textContent).toBe("Untitled");
  p.documents.detail = { ...detail, title: "Review the <plan> and implementation" };
  await p.conversations.refresh();
  await settle();
  expect(p.element.querySelector("h1").textContent).toBe("Review the <plan> and implementation");
  expect(browser.element.querySelector(".browser__title").textContent).toBe("Review the <plan> and implementation");
  expect(browser.element.querySelectorAll(".browser__row")).toHaveLength(1);
  expect(p.element.querySelector("h1").querySelector("plan")).toBeNull();
  expect(p.requests.filter((request) => request.method === "PATCH")).toEqual([]);
  browser.dispose(); p.panel.dispose(); p.conversations.dispose();
});

test("saving a mode preserves both saved highlights and only changes the accepted choice", async () => {
  const p = page({ address: { conversation: "c-1" } });
  await settle();
  const code = named(p.element, "Code mode · On");
  const subagent = named(p.element, "Subagent · On");
  let accept, reject;
  p.handlers["PATCH /conversations/modes"] = () => new Promise((resolve, refuse) => { accept = resolve; reject = refuse; });
  const saved = (toggle, enabled) => {
    expect(toggle.classList.contains("is-on")).toBe(enabled);
    expect(toggle.getAttribute("aria-pressed")).toBe(String(enabled));
    expect(toggle.classList.contains("is-unavailable")).toBe(false);
  };
  try {
    code.click();
    await settle();
    saved(code, true); saved(subagent, true);
    expect(code.disabled).toBe(true);
    expect(subagent.disabled).toBe(true);
    subagent.click();
    expect(p.requests.filter((request) => request.method === "PATCH")).toHaveLength(1);
    accept({ modes: { available: true, code_mode_available: true, code_mode: false, subagent: true } });
    await settle();
    saved(code, false); saved(subagent, true);
    expect(code.disabled).toBe(false);
    expect(subagent.disabled).toBe(false);
    subagent.click();
    await settle();
    saved(code, false); saved(subagent, true);
    reject(new Error("Mode save failed"));
    await settle();
    saved(code, false); saved(subagent, true);
    expect(code.disabled).toBe(false);
    expect(subagent.disabled).toBe(false);
    expect(p.element.textContent).toContain("Mode save failed");
    expect(p.requests.filter((request) => request.method === "PATCH").map((request) => request.body))
      .toEqual([{ public_id: "c-1", workspace_public_id: "w-1", code_mode: false },
        { public_id: "c-1", workspace_public_id: "w-1", subagent: false }]);
  } finally { p.panel.dispose(); p.conversations.dispose(); }
});

test("loading earlier messages prepends them and keeps the reading position", async () => {
  const p = page({ address: { conversation: "c-1" } });
  await settle();
  const scroller = p.element.querySelector(".conversation__scroller");
  const more = p.element.querySelector(".transcript__more");
  expect(more.hidden).toBe(false);
  scroller.scrollHeight = 1000; scroller.scrollTop = 40;
  more.click();
  scroller.scrollHeight = 1600;
  await settle();
  expect(p.element.querySelectorAll(".transcript__turns .markdown").map((node) => node.textContent)).toEqual(["message 1", "message 2", "message 3", "message 4"]);
  expect(scroller.scrollTop).toBe(640);
  expect(more.hidden).toBe(true);
});

test("jump to latest appears away from the end and scrolls back to it", async () => {
  const p = page({ address: { conversation: "c-1" } });
  await settle();
  const scroller = p.element.querySelector(".conversation__scroller");
  const jump = p.element.querySelector(".jump");
  scroller.scrollHeight = 2000; scroller.clientHeight = 500; scroller.scrollTop = 0;
  scroller.dispatchEvent(new Event("scroll"));
  expect(jump.hidden).toBe(false);
  jump.click();
  expect(scroller.scrollTop).toBe(2000);
  expect(jump.hidden).toBe(true);
});

test("an upward gesture stops live following even within one line of the end; Jump resumes it", async () => {
  const p = page({ address: { conversation: "c-1" }, detail: { public_id: "c-1", active_turn_public_id: "t-4" } });
  await settle();
  const scroller = p.element.querySelector(".conversation__scroller");
  const jump = p.element.querySelector(".jump");
  scroller.scrollHeight = 2000; scroller.clientHeight = 500; scroller.scrollTop = 1500;
  scroller.dispatchEvent(new Event("scroll"));
  scroller.dispatchEvent(new Event("wheel", { deltaY: -24 }));
  scroller.scrollTop = 1476;
  scroller.dispatchEvent(new Event("scroll"));
  p.streams[0].onFrame("snapshot", { turn: "t-4", text: "A new paragraph arrives." });
  await settle();
  expect(scroller.scrollTop).toBe(1476);
  expect(jump.hidden).toBe(false);
  jump.click();
  scroller.scrollHeight = 2200;
  p.streams[0].onFrame("snapshot", { turn: "t-4", text: "A new paragraph arrives. Then another." });
  await settle();
  expect(scroller.scrollTop).toBe(2200);
  expect(jump.hidden).toBe(true);
});

test("touch and keyboard reading gestures stop following before the next frame without treating text editing as scrolling", async () => {
  const p = page({ address: { conversation: "c-1" }, detail: { public_id: "c-1", active_turn_public_id: "t-4" } });
  await settle();
  const scroller = p.element.querySelector(".conversation__scroller");
  const jump = p.element.querySelector(".jump");
  scroller.scrollHeight = 2000; scroller.clientHeight = 500; scroller.scrollTop = 1500;
  scroller.dispatchEvent(new Event("touchstart", { touches: [{ clientY: 200 }] }));
  scroller.dispatchEvent(new Event("touchmove", { touches: [{ clientY: 230 }] }));
  p.streams[0].onFrame("snapshot", { turn: "t-4", text: "Touch reading." });
  await settle();
  expect(scroller.scrollTop).toBe(1500);
  jump.click();
  scroller.scrollTop = 1500;
  key(scroller, "PageUp");
  p.streams[0].onFrame("snapshot", { turn: "t-4", text: "Keyboard reading." });
  await settle();
  expect(scroller.scrollTop).toBe(1500);
  jump.click();
  scroller.scrollTop = 1500;
  key(p.element.querySelector("textarea"), "ArrowUp");
  p.streams[0].onFrame("snapshot", { turn: "t-4", text: "Editing the draft." });
  await settle();
  expect(scroller.scrollTop).toBe(2000);
});

test("opening another conversation starts at its latest message after reading old history", async () => {
  const p = page({ address: { conversation: "c-1" } });
  await settle();
  const scroller = p.element.querySelector(".conversation__scroller");
  scroller.scrollHeight = 2000; scroller.clientHeight = 500; scroller.scrollTop = 100;
  scroller.dispatchEvent(new Event("scroll"));
  await p.conversations.select("c-2");
  await settle();
  expect(scroller.scrollTop).toBe(2000);
  expect(p.element.querySelector(".jump").hidden).toBe(true);
});

test("collapsing content at the bottom keeps following when the browser clamps the scroll position", async () => {
  const p = page({ address: { conversation: "c-1" }, detail: { public_id: "c-1", active_turn_public_id: "t-4" } });
  await settle();
  const scroller = p.element.querySelector(".conversation__scroller");
  scroller.scrollHeight = 2000; scroller.clientHeight = 500; scroller.scrollTop = 1500;
  scroller.dispatchEvent(new Event("scroll"));
  // Closing a disclosure removes height while the viewport stays at its end.
  scroller.scrollHeight = 1700; scroller.scrollTop = 1200;
  scroller.dispatchEvent(new Event("scroll"));
  scroller.scrollHeight = 1740;
  p.streams[0].onFrame("snapshot", { turn: "t-4", text: "The answer continues after reasoning is folded." });
  await settle();
  expect(scroller.scrollTop).toBe(1740);
  expect(p.element.querySelector(".jump").hidden).toBe(true);
});

test("a running turn shows the live response in place of its empty body until the durable turn settles", async () => {
  const running = turn(4, { status: "running", active_variant: { public_id: "v-4", run_public_id: "r-4" } });
  const p = page({ address: { conversation: "c-1" }, detail: { public_id: "c-1", active_turn_public_id: "t-4" }, latest: [turn(3), running] });
  await settle();
  const live = p.element.querySelector(".turn--live");
  expect(live.hidden).toBe(false);
  expect(live.textContent).toContain("Working");
  expect(p.element.querySelector('[data-turn-id="t-4"] .turn__placeholder')).toBeNull();
  p.streams[0].onFrame("snapshot", { turn: "t-4", run_public_id: "r-4", text: "Partial **answer**", reasoning: "step one\nstep two" });
  await settle();
  expect(live.querySelector(".markdown strong").textContent).toBe("answer");
  expect(live.querySelector(".disclosure__summary").textContent).toBe("step two");
  p.documents.detail = { public_id: "c-1", active_turn_public_id: null };
  p.documents.latest = [turn(3), { ...running, status: "completed", active_variant: { public_id: "v-4", run_public_id: "r-4", content: "Final answer" } }];
  p.streams[0].onFrame("turn", {});
  await settle();
  expect(live.hidden).toBe(true);
  expect(p.element.querySelector('[data-turn-id="t-4"] .markdown').textContent).toBe("Final answer");
});

test("the header renames in place: Enter saves, Escape cancels and keyboard paths return focus to the menu", async () => {
  const p = page({ address: { conversation: "c-1" } });
  await settle();
  const header = p.element.querySelector(".conversation__header");
  named(header, "Conversation actions").click();
  document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent === "Rename").click();
  const field = header.querySelector(".conversation__rename");
  expect(field.value).toBe("First");
  expect(header.querySelector("h1").hidden).toBe(true);
  key(field, "Escape");
  expect(header.querySelector(".conversation__rename")).toBeNull();
  expect(p.requests.filter((request) => request.method === "PATCH")).toHaveLength(0);
  named(header, "Conversation actions").click();
  document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent === "Rename").click();
  const second = header.querySelector(".conversation__rename");
  second.value = "Better title";
  key(second, "Enter");
  await settle();
  expect(p.requests.find((request) => request.method === "PATCH").body).toMatchObject({ public_id: "c-1", title: "Better title" });
  expect(header.querySelector(".conversation__rename")).toBeNull();
  expect(document.activeElement.getAttribute("aria-label")).toBe("Conversation actions");
});

test("header utilities are bound to one conversation: a new id remounts them, the same id updates them", async () => {
  const p = page({ address: { conversation: "c-1" } });
  const seen = [];
  p.slots.register("conversation.header.utilities", { id: "probe", order: 5 }, (props) => {
    seen.push(["mount", props.conversation.id]);
    return { element: el("span", { class: "probe", text: props.conversation.id || "new" }),
      update: (next) => seen.push(["update", next.conversation.id]), dispose: () => seen.push(["dispose", props.conversation.id]) };
  });
  await settle();
  expect(p.element.querySelector(".conversation__utilities .probe").textContent).toBe("c-1");
  await p.conversations.select("c-2");
  await settle();
  expect(seen.filter(([what]) => what !== "update")).toEqual([["mount", "c-1"], ["dispose", "c-1"], ["mount", "c-2"]]);
  expect(seen.filter(([what, id]) => what === "update" && id === "c-2").length).toBeGreaterThan(0);
  p.element.querySelector(".conversation__corner").click();
  expect(p.toggles).toEqual([1]);
});
