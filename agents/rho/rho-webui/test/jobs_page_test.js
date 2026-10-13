import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { clockText, jobsPage, shelve } from "../webui/features/schedules/page.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const settle = async () => { for (let index = 0; index < 20; index += 1) await Promise.resolve(); await flush(); };
const job = (fields = {}) => ({ public_id: "job-1", conversation_public_id: "c-1", conversation_title: "Mail", name: "Morning summary",
  prompt: "Summarize unread email\nand flag anything urgent", status: "active", lock_version: 2, next_run_at: "2026-10-03T09:00:00Z",
  rule: { kind: "daily", local_time: "09:00", time_zone: "UTC" }, model: { model: "dev/model" }, last_error_code: null,
  last_execution: { child_conversation_public_id: "child-1", status: "completed" }, ...fields });

function mount({ answers = {}, workspace = "w-1", conversations = [] } = {}) {
  const requests = [];
  const selected = [];
  const docked = [];
  const toasts = [];
  const workspaces = observable({ rows: [], current: workspace });
  const shell = {
    call: async (path, options = {}) => {
      const method = options.method || "GET";
      const route = path.split("?")[0];
      requests.push({ method, route, query: new URLSearchParams(path.split("?")[1] || ""), body: options.body });
      const handler = answers[`${method} ${route}`];
      if (!handler) throw new Error(`unexpected ${method} ${path}`);
      return handler(options.body, requests.filter((request) => request.route === route).length);
    },
    toast: (text, options) => toasts.push([text, options?.tone]),
    workspaces: { state: workspaces, current: () => workspaces.get().current },
    conversations: { select: (id, options) => selected.push([id, options]), list: { state: observable({ rows: conversations }) } },
    dock: { open: (key, options) => docked.push([key, options]) },
  };
  const view = jobsPage(shell);
  document.body.append(view.element);
  return { view, requests, selected, docked, toasts, workspaces, element: view.element };
}
const buttons = (root) => root.querySelectorAll("button").filter((node) => !node.hidden);
const press = (root, label) => buttons(root).find((node) => node.textContent === label || node.getAttribute("aria-label") === label).dispatchEvent(new Event("click"));

test("jobs are shelved by what they will do next, with active jobs ordered by their next run", () => {
  const shelves = shelve([job({ public_id: "later", next_run_at: "2026-10-04T09:00:00Z" }), job({ public_id: "done", status: "completed" }),
    job({ public_id: "soon", next_run_at: "2026-10-03T09:00:00Z" }), job({ public_id: "held", status: "paused", next_run_at: null }),
    job({ public_id: "gone", status: "canceled" })]);
  expect(shelves.active.map((row) => row.public_id)).toEqual(["soon", "later"]);
  expect(shelves.paused.map((row) => row.public_id)).toEqual(["held"]);
  expect(shelves.finished.map((row) => row.public_id)).toEqual(["done", "gone"]);
  expect(clockText(job())).toContain("Daily · 09:00 UTC · next ");
  expect(clockText(job({ status: "paused", next_run_at: null }))).toBe("Daily · 09:00 UTC");
});

test("the page reads every page of the workspace overview and shows each job's conversation and controls", async () => {
  const t = mount({ answers: { "GET /workspaces/schedules": (_body, count) => (count === 1
    ? { schedules: [job(), job({ public_id: "job-2", name: null, status: "paused", next_run_at: null, conversation_public_id: "c-2", conversation_title: null })], pagination: { next_after: "more" } }
    : { schedules: [job({ public_id: "job-3", status: "canceled", last_error_code: "not_authorized" })], pagination: { next_after: null } }) } });
  await settle();
  expect(t.requests.map((request) => [request.query.get("workspace_public_id"), request.query.get("after")])).toEqual([["w-1", null], ["w-1", "more"]]);
  const [first, second, third] = t.element.querySelectorAll(".jobs-page__job");
  expect(first.querySelector(".jobs-page__name").textContent).toBe("Morning summary");
  expect(first.querySelector(".jobs-page__where").textContent).toBe("Mail");
  expect(first.querySelector(".jobs-page__clock").textContent).toContain("Daily · 09:00 UTC · next ");
  const labels = (node) => buttons(node).map((control) => control.getAttribute("aria-label"));
  expect(labels(first.querySelector(".jobs-page__actions"))).toEqual(["Run now", "Pause", "Cancel"]);
  expect(second.querySelector(".jobs-page__name").textContent).toBe("Summarize unread email");
  expect(second.querySelector(".jobs-page__where").textContent).toBe("Open conversation");
  expect(labels(second.querySelector(".jobs-page__actions"))).toEqual(["Run now", "Resume", "Cancel"]);
  expect(third.textContent).toContain("Last error: not_authorized");
  expect(buttons(third.querySelector(".jobs-page__actions"))).toHaveLength(0);
  expect(t.element.querySelectorAll(".group__title").map((node) => node.textContent)).toEqual(["Active1", "Paused1", "Finished1"]);
  expect(t.element.querySelector("details")).toBeNull();
  // The page's header keeps Refresh; a new job's action sits on the Active group.
  expect(t.element.querySelectorAll(".page__actions button").map((node) => node.getAttribute("aria-label"))).toEqual(["Refresh"]);
  expect(t.element.querySelector(".group__actions .btn__label").textContent).toBe("New scheduled job");

  first.querySelector(".jobs-page__where").dispatchEvent(new Event("click"));
  first.querySelector(".jobs-page__execution").dispatchEvent(new Event("click"));
  expect(t.selected).toEqual([["c-1", { workspace: "w-1" }], ["child-1", { workspace: "w-1" }]]);
});

test("Run now addresses the job's own conversation, tells the person, and reloads; a busy execution is explained", async () => {
  let attempt = 0;
  const t = mount({ answers: {
    "GET /workspaces/schedules": () => ({ schedules: [job()], pagination: { next_after: null } }),
    "POST /conversations/schedules/run": () => {
      attempt += 1;
      if (attempt === 2) throw Object.assign(new Error("Refused: execution_in_progress"), { status: 409, code: "execution_in_progress" });
      return { schedule: job() };
    },
  } });
  await settle();
  press(t.element, "Run now");
  await settle();
  const run = t.requests.find((request) => request.method === "POST");
  expect(run.body).toEqual({ public_id: "c-1", workspace_public_id: "w-1", job_public_id: "job-1" });
  expect(t.toasts).toEqual([["Started Morning summary; its result returns to the conversation.", "success"]]);
  expect(t.requests.filter((request) => request.route === "/workspaces/schedules")).toHaveLength(2);
  press(t.element, "Run now");
  await settle();
  expect(t.element.querySelector(".alert--error").textContent).toContain("previous execution is still working");
});

test("a new job is authored in one of the workspace's conversations through the dock editor", async () => {
  const t = mount({ answers: { "GET /workspaces/schedules": () => ({ schedules: [], pagination: { next_after: null } }) },
    conversations: [{ public_id: "c-1", title: "Mail", workspace_public_id: "w-1" }, { public_id: "c-9", title: "Elsewhere", workspace_public_id: "w-2" }] });
  await settle();
  expect(t.element.querySelector(".empty-state__title").textContent).toBe("No scheduled jobs yet");
  press(t.element, "New scheduled job");
  const items = document.body.querySelectorAll(".menu__item").map((node) => node.textContent);
  expect(items).toEqual(["Mail"]);
  document.body.querySelectorAll(".menu__item")[0].dispatchEvent(new Event("click"));
  expect(t.selected).toEqual([["c-1", { workspace: "w-1" }]]);
  expect(t.docked).toEqual([["schedules", { params: { create: true } }]]);
});

test("changing the workspace rereads the overview for the new one", async () => {
  const t = mount({ answers: { "GET /workspaces/schedules": () => ({ schedules: [job()], pagination: { next_after: null } }) } });
  await settle();
  t.workspaces.set({ rows: [], current: "w-2" });
  await settle();
  expect(t.requests.map((request) => request.query.get("workspace_public_id"))).toEqual(["w-1", "w-2"]);
  t.view.dispose();
});
