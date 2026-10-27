import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { createSlots } from "../webui/kernel/slots.js";
import { backgroundWork, kindText, register, workCount } from "../webui/features/background/index.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const settle = async () => { for (let index = 0; index < 20; index += 1) await Promise.resolve(); await flush(); };
const snapshot = (fields = {}) => ({ public_id: "c-1", run_public_id: "run-1", run_status: "running",
  tasks: [{ task_key: "r2", kind: "model_task", status: "running" }, { task_key: "r1t1", kind: "tool_task", status: "running" },
    { task_key: "r1t2", kind: "tool_task", status: "needs_approval" }, { task_key: "r1t0", kind: "tool_task", status: "completed" }],
  children: [{ public_id: "child-1", label: "research", busy: true }, { public_id: "child-2", label: "review", busy: false },
    { public_id: "child-3", title: "Morning check", busy: false }], ...fields });

test("the work in flight is the live tasks and the busy subagents; finished and waiting work is told apart", () => {
  const work = backgroundWork({ snapshot: snapshot() });
  expect(work.running.map((task) => task.task_key)).toEqual(["r2", "r1t1"]);
  expect(work.waiting.map((task) => task.task_key)).toEqual(["r1t2"]);
  expect(work.busy.map((child) => child.public_id)).toEqual(["child-1"]);
  expect(work.idle.map((child) => child.public_id)).toEqual(["child-2", "child-3"]);
  expect(workCount(work)).toBe(3);
  expect(workCount(backgroundWork({ snapshot: null }))).toBe(0);
  expect(kindText({ kind: "tool_task" }, { tool_name: "bash" })).toBe("bash");
  expect(kindText({ kind: "tool_task" }, null)).toBe("Tool call");
  expect(kindText({ kind: "delegation_task" }, null)).toBe("Subagent report");
});

function mount({ writable = true, answers = {} } = {}) {
  const requests = [];
  const stopsAll = [];
  const refreshes = [];
  const opened = [];
  const state = observable({ id: "c-1", workspace: "w-1", snapshot: snapshot(), detail: { active_turn_public_id: "turn-1" }, stopping: false });
  const slots = createSlots();
  const shell = {
    call: async (path, options = {}) => {
      const method = options.method || "GET";
      const route = path.split("?")[0];
      requests.push({ method, route, query: new URLSearchParams(path.split("?")[1] || ""), body: options.body, conversation: options.conversation });
      if (route === "/conversations/links" && !answers["GET /conversations/links"]) return { links: [], pagination: { next_after: null } };
      const handler = answers[`${method} ${route}`];
      if (!handler) throw new Error(`unexpected ${method} ${path}`);
      return handler(options.body, requests.at(-1));
    },
    conversations: { state, stop: () => stopsAll.push(1), refresh: () => refreshes.push(1) },
    dock: { open() {} },
  };
  const registrations = [];
  const ui = { slots: { register: (name, options, component) => { registrations.push([name, options, component]); return () => {}; } } };
  register(ui, shell);
  const [, , panel] = registrations.find(([name]) => name === "dock.tab");
  const [, , chip] = registrations.find(([name]) => name === "conversation.header.utilities");
  const conversation = { id: "c-1", workspace: "w-1", writable, access: "ready", open: (id, options) => opened.push([id, options]) };
  const view = panel({ conversation, params: {}, close() {} });
  const button = chip({ conversation });
  document.body.append(view.element, button.element);
  return { view, button, state, requests, stopsAll, refreshes, opened, element: view.element, slots };
}
const rows = (root) => root.querySelectorAll(".background__row");
const labelled = (root, label) => root.querySelectorAll("button").find((node) => node.getAttribute("aria-label") === label);

test("the tab lists busy subagents and live tasks under Running, held tasks under Waiting, idle subagents apart", async () => {
  const t = mount({ answers: { "GET /runs/task": (_body, request) => ({ task: { key: request.query.get("task_key"), tool_name: request.query.get("task_key") === "r1t1" ? "bash" : null } }) } });
  await settle();
  const titles = t.element.querySelectorAll(".background__group-title").map((node) => node.textContent);
  expect(titles).toEqual(["Running", "Waiting", "Subagents", "Communication links"]);
  const names = rows(t.element).map((row) => row.querySelector(".background__name").textContent);
  expect(names).toEqual(["research", "Model round", "bash", "Tool call", "review", "Morning check"]);
  expect(rows(t.element)[2].querySelector(".background__meta").textContent).toBe("r1t1 · running");
  const reads = t.requests.filter((request) => request.route === "/runs/task");
  expect(reads.map((request) => request.query.get("task_key")).sort()).toEqual(["r1t1", "r1t2", "r2"]);
  expect(reads[0].query.get("public_id")).toBe("run-1");
  expect(reads[0].query.get("workspace_public_id")).toBe("w-1");
  // The idle subagent has no Stop; it opens instead.
  expect(rows(t.element)[4].querySelector('button[aria-label^="Stop"]')).toBeNull();
  rows(t.element)[4].querySelector(".background__name--link").dispatchEvent(new Event("click"));
  expect(t.opened).toEqual([["child-2", { workspace: "w-1" }]]);
  expect(t.button.element.querySelector(".background-chip__count").textContent).toBe("3");
});

test("Stop on a subagent stops that child conversation; Stop on a task cancels its branch by key, and a mainline step is explained", async () => {
  const t = mount({ answers: {
    "GET /runs/task": (_body, request) => ({ task: { key: request.query.get("task_key"), tool_name: null } }),
    "POST /stop": (body) => {
      if (body.task_key === "r2") throw Object.assign(new Error("Refused: not_a_branch"), { status: 409, code: "not_a_branch" });
      return { stopped: {} };
    },
  } });
  await settle();
  labelled(rows(t.element)[0], "Stop subagent research").dispatchEvent(new Event("click"));
  await settle();
  const [child] = t.requests.filter((request) => request.route === "/stop");
  expect(child.body).toEqual({ public_id: "child-1", host_type: "conversation", workspace_public_id: "w-1", force: true });
  expect(child.conversation).toBe("c-1");
  expect(t.refreshes).toEqual([1]);

  labelled(rows(t.element)[2], "Stop Tool call").dispatchEvent(new Event("click"));
  await settle();
  expect(t.requests.filter((request) => request.route === "/stop")[1].body).toEqual({ public_id: "run-1", host_type: "run", workspace_public_id: "w-1", task_key: "r1t1" });

  labelled(rows(t.element)[1], "Stop Model round").dispatchEvent(new Event("click"));
  await settle();
  expect(t.element.querySelector(".alert--error").textContent).toContain("part of the main reply");
  t.element.querySelectorAll("button").find((node) => node.textContent === "Stop all work").dispatchEvent(new Event("click"));
  expect(t.stopsAll).toEqual([1]);
});

test("a read-only conversation reads the work but cannot stop it, and an idle conversation says nothing runs", async () => {
  const t = mount({ writable: false, answers: { "GET /runs/task": (_body, request) => ({ task: { key: request.query.get("task_key") } }) } });
  await settle();
  expect(rows(t.element)[0].querySelector('button[aria-label^="Stop"]').disabled).toBe(true);
  t.state.set({ ...t.state.get(), snapshot: snapshot({ tasks: [], children: [] }), detail: { active_turn_public_id: null } });
  expect(t.element.querySelector(".empty-state__title").textContent).toBe("Nothing is running in the background");
  expect(t.element.querySelectorAll("button").find((node) => node.textContent === "Stop all work").hidden).toBe(true);
  expect(t.button.element.querySelector(".background-chip__count").hidden).toBe(true);
  t.view.dispose();
  t.button.dispose();
});

test("reused task keys resolve and stop on their own Run after a new reply starts", async () => {
  const t = mount({ answers: {
    "GET /runs/task": (_body, request) => ({ task: { tool_name: request.query.get("public_id") } }),
    "POST /stop": () => ({ stopped: {} }),
  } });
  await settle();
  const oldStop = labelled(rows(t.element)[2], "Stop run-1");
  t.state.set({ ...t.state.get(), snapshot: snapshot({ run_public_id: "run-2" }) });
  await settle();
  expect(rows(t.element)[2].querySelector(".background__name").textContent).toBe("run-2");
  oldStop.click();
  await settle();
  expect(t.requests.find((request) => request.route === "/stop").body.public_id).toBe("run-1");
  expect(t.requests.filter((request) => request.route === "/runs/task" && request.query.get("public_id") === "run-2")).toHaveLength(3);
  t.view.dispose();
  t.button.dispose();
});

test("closing communication closes only the link and leaves accepted work visible", async () => {
  const t = mount({ answers: {
    "GET /runs/task": () => ({ task: {} }),
    "GET /conversations/links": () => ({ links: [{ public_id: "link-1", peer: { conversation_public_id: "peer-1" } }], pagination: { next_after: null } }),
    "POST /conversations/links/close": () => ({ link: { state: "closed" } }),
  } });
  await settle();
  expect(t.element.textContent).toContain("does not stop either conversation or cancel accepted requests");
  t.element.querySelectorAll("button").find((node) => node.textContent === "Close communication").click();
  await settle();
  const writes = t.requests.filter((request) => request.method === "POST");
  expect(writes.map((request) => request.route)).toEqual(["/conversations/links/close"]);
  expect(writes[0].body).toEqual({ public_id: "c-1", link_public_id: "link-1", workspace_public_id: "w-1" });
  expect(t.element.querySelectorAll("[data-link-id]")).toHaveLength(0);
  expect(rows(t.element).length).toBe(6);
  expect(t.stopsAll).toEqual([]);
  t.view.dispose();
  t.button.dispose();
});
