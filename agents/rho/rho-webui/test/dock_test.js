import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";
import { createSlots } from "../webui/kernel/slots.js";
import { observable } from "../webui/kernel/observable.js";
import { el } from "../webui/kernel/dom.js";
import { createDock } from "../webui/shell/dock.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const context = (id) => ({ id, workspace: id ? `w-${id}` : null, detail: null, access: id ? "ready" : "ready", writable: !!id });

function harness() {
  const slots = createSlots();
  const selection = observable(context("c-1"));
  const layout = observable({ dockOpen: false, dock: 0 });
  const errors = [];
  const shell = { conversations: { selection }, renderError: (error) => errors.push(error.message) };
  const seen = [];
  slots.register("dock.tab", { key: "task", title: (params) => `Task ${params.taskKey || ""}`.trim() }, (props) => {
    seen.push(["mount", props.params.taskKey, props.conversation.id]);
    return { element: el("div", { class: "task-pane", text: `task:${props.params.taskKey}` }), update: (next) => seen.push(["update", next.params.taskKey, next.conversation.id]), dispose: () => seen.push(["dispose", props.params.taskKey]) };
  });
  slots.register("dock.tab", { key: "usage", title: () => "Usage", description: () => "Tokens and cost" }, () => ({ element: el("div", { text: "usage" }) }));
  const dock = createDock({ slots, shell, layout });
  document.body.append(dock.element);
  return { slots, selection, layout, dock, seen, errors };
}

test("opening a tab opens the dock, focuses the tab and mounts the type's component with its params", () => {
  const { dock, layout, seen } = harness();
  dock.update({ mode: "closed" });
  expect(dock.element.hidden).toBe(true);
  dock.open("task", { id: "task:t-1", params: { taskKey: "t-1" } });
  expect(layout.get().dockOpen).toBe(true);
  expect(dock.element.hidden).toBe(false);
  expect(dock.state.get()).toMatchObject({ active: "task:t-1", tabs: [{ id: "task:t-1", key: "task", title: "Task t-1" }] });
  expect(seen).toEqual([["mount", "t-1", "c-1"]]);
  dock.open("task", { id: "task:t-2", params: { taskKey: "t-2" } });
  const panes = dock.element.querySelectorAll(".dock__pane");
  expect(panes).toHaveLength(2);
  expect(panes[0].hidden).toBe(true);
  expect(panes[1].hidden).toBe(false);
  dock.open("task", { id: "task:t-1", params: { taskKey: "t-1" } });
  expect(dock.element.querySelectorAll(".dock__pane")[0].hidden).toBe(false);
  expect(seen.filter(([what]) => what === "mount")).toHaveLength(2);
});

test("closing a tab disposes it and moves to a neighbour; closing the dock keeps the tabs", () => {
  const { dock, layout, seen } = harness();
  dock.open("task", { id: "a", params: { taskKey: "a" } });
  dock.open("task", { id: "b", params: { taskKey: "b" } });
  dock.closeTab("b");
  expect(seen.at(-1)).toEqual(["dispose", "b"]);
  expect(dock.state.get().active).toBe("a");
  dock.close();
  expect(layout.get().dockOpen).toBe(false);
  expect(dock.state.get().tabs.map((tab) => tab.id)).toEqual(["a"]);
  dock.toggle();
  expect(layout.get().dockOpen).toBe(true);
  expect(dock.element.querySelector(".task-pane").textContent).toBe("task:a");
});

test("tab sets belong to the conversation that opened them and come back when it is shown again", () => {
  const { dock, selection, seen } = harness();
  dock.open("task", { id: "a", params: { taskKey: "a" } });
  selection.set(context("c-2"));
  expect(seen.at(-1)).toEqual(["dispose", "a"]);
  expect(dock.state.get().tabs).toEqual([]);
  expect(dock.element.querySelector(".dock__guide")).not.toBeNull();
  expect(dock.element.querySelectorAll(".dock__guide-entry")).toHaveLength(1);
  dock.open("usage");
  expect(dock.element.querySelector(".dock__guide")).toBeNull();
  selection.set(context("c-1"));
  expect(dock.state.get().tabs.map((tab) => tab.id)).toEqual(["a"]);
  expect(seen.at(-1)).toEqual(["mount", "a", "c-1"]);
  selection.set({ ...context("c-1"), detail: { title: "renamed" } });
  expect(seen.at(-1)).toEqual(["update", "a", "c-1"]);
});

test("the guide lists described tab types and needs a conversation before it can open one", () => {
  const { dock, selection } = harness();
  selection.set(context(null));
  dock.open(null);
  const entry = dock.element.querySelector(".dock__guide-entry");
  expect(entry.disabled).toBe(true);
  expect(dock.element.querySelector(".dock__guide-description").textContent).toBe("Open a conversation first.");
  selection.set(context("c-3"));
  dock.element.querySelector(".dock__guide-entry").click();
  expect(dock.state.get().active).toBe("usage");
});
