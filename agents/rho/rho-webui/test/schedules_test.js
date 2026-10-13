import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, type, flush } from "./support/dom.js";
import { Submissions } from "../webui/kernel/submissions.js";
import { changedFields } from "../webui/kernel/forms.js";
import { scheduledRule, scheduledRuleText, schedulesPanel } from "../webui/features/schedules/schedules.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

test("the one-time and interval clocks carry explicit instants", () => {
  expect(scheduledRule("once", { at: "2026-10-02T09:00:00+08:00" })).toEqual({ kind: "once", run_at: "2026-10-02T01:00:00.000Z" });
  expect(scheduledRule("interval", { seconds: "90", at: "2026-10-02T09:00:00Z" })).toEqual({ kind: "interval", every_seconds: 90, starts_at: "2026-10-02T09:00:00.000Z" });
  expect(() => scheduledRule("once", { at: "2026-10-02T09:00" })).toThrow("time zone");
  expect(() => scheduledRule("interval", { seconds: "0", at: "2026-10-02T09:00:00Z" })).toThrow("positive");
});

test("daily schedules keep local civil time and the named time zone", () => {
  const rule = scheduledRule("daily", { localTime: "09:15", timeZone: "Asia/Shanghai" });
  expect(rule).toEqual({ kind: "daily", local_time: "09:15", time_zone: "Asia/Shanghai" });
  expect(scheduledRuleText(rule)).toBe("Daily · 09:15 Asia/Shanghai");
  expect(() => scheduledRule("daily", { localTime: "24:00", timeZone: "UTC" })).toThrow("HH:MM");
  expect(() => scheduledRule("daily", { localTime: "09:00", timeZone: "Bad/Zone" })).toThrow();
});

test("retrying the same scheduled intent keeps its creation key and frozen time", () => {
  let serial = 0;
  const pending = new Submissions(() => `key-${++serial}`);
  const body = { public_id: "conversation", prompt: "Report progress", rule: scheduledRule("once", { at: "2026-10-02T09:00:00Z" }) };
  const first = pending.prepare("/conversations/schedules/create", body);
  expect(pending.prepare("/conversations/schedules/create", { ...body })).toBe(first);
  pending.accepted(first);
  expect(pending.prepare("/conversations/schedules/create", body).body.idempotency_key).toBe("key-2");
});

test("editing the prompt preserves the schedule and inherited policy", () => {
  const displayed = { prompt: "Report progress", name: "Daily", model: "dev/model", approval_mode: "ask",
    rule: scheduledRule("interval", { seconds: "3600", at: "2026-10-02T09:00:00Z" }) };
  expect(changedFields(displayed, { ...displayed, prompt: "Report blockers", name: null })).toEqual({ prompt: "Report blockers", name: null });
});

const job = (fields = {}) => ({ public_id: "job-1", name: "Standup", prompt: "Report progress\nand blockers", status: "active", lock_version: 3,
  next_run_at: "2026-10-02T09:00:00Z", rule: { kind: "daily", local_time: "09:00", time_zone: "UTC" }, model: { model: "dev/model" }, approval_mode: "ask", ...fields });

function tab({ writable = true, answers = {} } = {}) {
  const requests = [];
  const opened = [];
  const refreshes = [];
  const creates = new Submissions((() => { let serial = 0; return () => `key-${++serial}`; })());
  const shell = { call: async (path, options = {}) => {
    const method = options.method || "GET";
    const route = path.split("?")[0];
    requests.push({ method, route, query: new URLSearchParams(path.split("?")[1] || ""), body: options.body, conversation: options.conversation });
    const handler = answers[`${method} ${route}`];
    if (!handler) throw new Error(`unexpected ${method} ${path}`);
    return handler(options.body);
  } };
  const conversation = { id: "c-1", workspace: "w-1", writable, defaults: { model: "dev/model", approval_mode: "rules" },
    open: (id, options) => opened.push([id, options]), refresh: () => refreshes.push(1) };
  const view = schedulesPanel(shell, { conversation, params: {}, close: () => {} }, { creates });
  document.body.append(view.element);
  return { view, requests, opened, refreshes, element: view.element, posts: () => requests.filter((request) => request.method === "POST") };
}
const press = (root, label) => root.querySelectorAll("button").find((node) => node.textContent === label || node.getAttribute("aria-label") === label).dispatchEvent(new Event("click"));
const labels = (root) => root.querySelectorAll("button").map((node) => node.getAttribute("aria-label") || node.textContent);
const field = (root, label) => document.getElementById(root.querySelectorAll("label").find((node) => node.textContent === label).getAttribute("for"));

test("the tab lists the conversation's jobs in its workspace with their rule, next run and controls", async () => {
  const t = tab({ answers: { "GET /conversations/schedules": () => ({ schedules: [job(), job({ public_id: "job-2", name: null, status: "paused" })], pagination: { next_after: "after-2" } }) } });
  await flush();
  expect(t.requests[0].query.get("public_id")).toBe("c-1");
  expect(t.requests[0].query.get("workspace_public_id")).toBe("w-1");
  const [first, second] = t.element.querySelectorAll(".schedule");
  expect(first.querySelector(".schedule__name").textContent).toBe("Standup");
  expect(first.textContent).toContain("Daily · 09:00 UTC");
  expect(labels(first)).toEqual(["Edit", "Executions", "Run now", "Pause", "Cancel"]);
  expect(first.querySelectorAll("button").every((node) => node.classList.contains("btn--icon"))).toBe(true);
  expect(second.querySelector(".schedule__name").textContent).toBe("Report progress");
  expect(labels(second)).toEqual(["Edit", "Executions", "Run now", "Resume", "Cancel"]);
  expect(t.element.querySelectorAll("button").find((node) => node.textContent === "More jobs").hidden).toBe(false);
});

test("a new job starts from the conversation's model and approval mode and keeps its key for a manual retry", async () => {
  let attempt = 0;
  const t = tab({ answers: {
    "GET /conversations/schedules": () => ({ schedules: [], pagination: {} }),
    "POST /conversations/schedules/create": () => { attempt += 1; if (attempt === 1) throw new TypeError("Failed to fetch"); return { schedule: job() }; },
  } });
  await flush();
  expect(t.element.textContent).toContain("No scheduled jobs yet.");
  press(t.element, "New scheduled job");
  expect(field(t.element, "Model").value).toBe("dev/model");
  expect(field(t.element, "Permissions").value).toBe("rules");
  type(field(t.element, "Task"), "Summarize the day");
  field(t.element, "Schedule").value = "daily";
  field(t.element, "Schedule").dispatchEvent(new Event("change"));
  type(field(t.element, "Time zone (IANA)"), "UTC");
  const form = t.element.querySelector(".schedules__form");
  form.dispatchEvent(new Event("submit"));
  await flush();
  expect(t.element.querySelector(".alert--error").textContent).toBe("Failed to fetch");
  form.dispatchEvent(new Event("submit"));
  await flush();
  const [failed, retried] = t.posts();
  expect(retried.body.idempotency_key).toBe(failed.body.idempotency_key);
  expect(retried.body).toMatchObject({ public_id: "c-1", workspace_public_id: "w-1", prompt: "Summarize the day", model: "dev/model",
    approval_mode: "rules", rule: { kind: "daily", local_time: "09:00", time_zone: "UTC" } });
  expect(t.element.querySelector(".schedules__form")).toBeNull();
});

test("an edit sends only what changed with the observed version; a conflict keeps the draft", async () => {
  const t = tab({ answers: {
    "GET /conversations/schedules": () => ({ schedules: [job()], pagination: {} }),
    "POST /conversations/schedules/update": () => { throw Object.assign(new Error("stale"), { status: 409, code: "stale_object" }); },
  } });
  await flush();
  press(t.element.querySelector(".schedule"), "Edit");
  type(field(t.element, "Task"), "Report blockers");
  t.element.querySelector(".schedules__form").dispatchEvent(new Event("submit"));
  await flush();
  expect(t.posts()[0].body).toEqual({ public_id: "c-1", workspace_public_id: "w-1", prompt: "Report blockers", job_public_id: "job-1", expected_lock_version: 3 });
  expect(t.element.querySelector(".alert--error").textContent).toContain("This job changed. Your draft is kept.");
  expect(field(t.element, "Task").value).toBe("Report blockers");
});

test("pausing reloads the list, and executions open their child conversation in this workspace", async () => {
  const t = tab({ answers: {
    "GET /conversations/schedules": () => ({ schedules: [job()], pagination: {} }),
    "POST /conversations/schedules/pause": () => ({ schedule: job({ status: "paused" }) }),
    "GET /conversations/schedules/executions": () => ({ executions: [{ scheduled_for: "2026-10-02T09:00:00Z", status: "completed", child_conversation_public_id: "child-1" }], pagination: {} }),
  } });
  await flush();
  press(t.element.querySelector(".schedule"), "Pause");
  await flush();
  expect(t.posts()[0].body).toEqual({ public_id: "c-1", workspace_public_id: "w-1", job_public_id: "job-1" });
  expect(t.requests.filter((request) => request.route === "/conversations/schedules")).toHaveLength(2);
  press(t.element.querySelector(".schedule"), "Executions");
  await flush();
  expect(t.element.querySelector(".schedules__history").textContent).toContain("Executions · Standup");
  press(t.element.querySelector(".schedules__history"), "Open execution");
  expect(t.opened).toEqual([["child-1", { workspace: "w-1" }]]);
});

test("Run now posts the job's run command and reloads; opening with create starts the draft", async () => {
  const t = tab({ answers: {
    "GET /conversations/schedules": () => ({ schedules: [job()], pagination: {} }),
    "POST /conversations/schedules/run": () => ({ schedule: job({ last_execution: { status: "queued", child_conversation_public_id: "child-9" } }) }),
  } });
  await flush();
  press(t.element.querySelector(".schedule"), "Run now");
  await flush();
  expect(t.posts()[0]).toMatchObject({ route: "/conversations/schedules/run", body: { public_id: "c-1", workspace_public_id: "w-1", job_public_id: "job-1" } });
  expect(t.requests.filter((request) => request.route === "/conversations/schedules")).toHaveLength(2);

  const shell = { call: async () => ({ schedules: [], pagination: {} }) };
  const conversation = { id: "c-1", workspace: "w-1", writable: true, defaults: { model: "dev/model", approval_mode: "ask" }, open() {}, refresh() {} };
  const opened = schedulesPanel(shell, { conversation, params: { create: true }, close: () => {} }, { creates: new Submissions() });
  expect(opened.element.querySelector(".schedules__form")).not.toBeNull();
});

test("a read-only conversation keeps reads but disables every change, and a refusal asks the conversation to refresh", async () => {
  const t = tab({ writable: false, answers: { "GET /conversations/schedules": () => { throw Object.assign(new Error("gone"), { status: 404 }); } } });
  await flush();
  expect(t.element.querySelectorAll("button").find((node) => node.textContent === "New scheduled job").disabled).toBe(true);
  expect(t.element.querySelectorAll("button").find((node) => node.getAttribute("aria-label") === "Refresh").disabled).toBe(false);
  expect(t.refreshes).toEqual([1]);
});
