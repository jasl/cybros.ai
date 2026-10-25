import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { createSlots } from "../webui/kernel/slots.js";
import { createArtifactOpener } from "../webui/kernel/artifacts.js";
import { register, taskCaptures, taskDetail } from "../webui/features/task/index.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const opener = () => createArtifactOpener({ artifactBytes: async () => new Blob(), host: () => "c-1", signal: new AbortController().signal });
const failed = { task_key: "r1", kind: "model_task", status: "failed", on_failure: "halt", error_key: "provider_context_overflow" };

test("an unresolved context overflow adds the repair guidance beside the literal provider diagnostic", () => {
  const detail = taskDetail({ ...failed, error: { key: "provider_context_overflow", detail: "Requested 9000 tokens; maximum 8192. <div>" } }, opener());
  expect(detail.textContent).toContain("Nexus Settings > Model providers > Edit model > Context and capabilities");
  const diagnostic = detail.querySelector(".task__error");
  expect(diagnostic.textContent).toContain("Requested 9000 tokens; maximum 8192. <div>");
  expect(diagnostic.children).toEqual([]);
});

test("recovered, absorbed or other failures keep their diagnostic without model-limit instructions", () => {
  for (const fields of [{ status: "running" }, { status: "completed" }, { failure_resolution: "abandoned" }, { on_failure: "absorb" }]) {
    const detail = taskDetail({ ...failed, ...fields, error: { key: "provider_context_overflow", detail: "Requested 9000 tokens" } }, opener());
    expect(detail.textContent).not.toContain("Context and capabilities");
    expect(detail.textContent).toContain("Requested 9000 tokens");
  }
});

test("a task shows its tool and status, prompt as Markdown, input JSON, explicit file paths, and captured uploads", () => {
  const detail = taskDetail({ tool_name: "bash", status: "completed", prompt: "Run **tests**", tool_input: { command: "bun test" },
    output: "wrote /tmp/report.txt. report.txt is ready.", content: [{ type: "resource_link", uri: "nexus://uploads/up-1", name: "screen.png" }, { type: "text", text: "x" }] }, opener());
  expect(detail.querySelector(".task__summary").textContent).toBe("bash · completed");
  expect(detail.querySelector(".markdown strong").textContent).toBe("tests");
  expect(detail.querySelectorAll("pre").map((node) => node.textContent)).toEqual([JSON.stringify({ command: "bun test" }, null, 2), "wrote /tmp/report.txt. report.txt is ready."]);
  expect(detail.querySelectorAll("figure").map((figure) => figure.querySelector(".artifact__name").textContent)).toEqual(["report.txt", "screen.png"]);
  expect(taskCaptures({ content: [{ type: "resource_link", uri: "https://elsewhere/x" }] })).toEqual([]);
});

test("MCP task detail names its callable and remote account, retaining an identifiable connection when display metadata is absent", () => {
  const target = { kind: "mcp", connection_public_id: "notes-work", display_name: "Notes", account_label: "Work", tool_name: "search" };
  const detail = taskDetail({ tool_name: "search", tool_alias: "find_work_notes", status: "completed", target }, opener());
  expect(detail.querySelector(".task__summary").textContent).toBe("find_work_notes · completed");
  expect(detail.querySelectorAll(".mcp-target dd").map((node) => node.textContent)).toEqual(["Notes", "Work", "search"]);
  const missing = taskDetail({ tool_name: "search", status: "failed", target: { kind: "mcp", connection_public_id: "notes-work" } }, opener());
  expect(missing.querySelectorAll(".mcp-target dd").map((node) => node.textContent)).toEqual(["notes-work", "search"]);
  const local = taskDetail({ tool_name: "search", status: "completed", target: { kind: "runner", display_name: "Runner" } }, opener());
  expect(local.querySelector(".mcp-target")).toBeNull();
});

function tab(answer) {
  const slots = createSlots();
  const requests = [];
  const shell = { slots, artifactBytes: async () => new Blob(), call: async (path, options = {}) => { requests.push([path, options.signal]); return answer(path); } };
  register({ slots: { register: (name, options, component) => slots.register(name, options, component) } }, shell);
  const registration = slots.winner("dock.tab", "task");
  const panel = registration.component({ conversation: { id: "c-1", workspace: "w-1" }, params: { runId: "run-1", taskKey: "t-9", title: "bash" }, close: () => {} });
  document.body.append(panel.element);
  return { registration, panel, requests, slots };
}

test("the task tab reads its task in the conversation's workspace, is titled by its call and is not offered in the guide", async () => {
  const t = tab(() => ({ task: { tool_name: "bash", status: "running" } }));
  expect(t.registration.meta.title({ title: "bash" })).toBe("bash");
  expect(t.registration.meta.title({})).toBe("Task");
  expect(t.registration.meta.description).toBeUndefined();
  expect(t.panel.element.textContent).toContain("Loading task…");
  await flush();
  expect(t.requests[0][0]).toBe("/runs/task?public_id=run-1&workspace_public_id=w-1&task_key=t-9");
  expect(t.panel.element.querySelector(".task__summary").textContent).toBe("bash · running");
  t.panel.element.querySelector(".task__head button").click();
  await flush();
  expect(t.requests).toHaveLength(2);
  t.panel.dispose();
  expect(t.requests[0][1].aborted).toBe(true);
});

test("a task that cannot be read says so instead of an empty tab", async () => {
  const t = tab(() => { throw Object.assign(new Error("No such task"), { status: 404 }); });
  await flush();
  expect(t.panel.element.querySelector(".alert--error").textContent).toBe("No such task");
});

test("a model round without text can inspect its sealed input on demand", async () => {
  const request = { entries: [{ role: "user", parts: [{ text: "Read notes <div>" }] }], request_options: { tools: [] } };
  const view = tab((path) => path.startsWith("/runs/request?") ? { request } : { task: { kind: "model_task", status: "completed" } });
  await flush();
  expect(view.panel.element.textContent).toContain("This model round returned no text.");
  expect(view.requests).toHaveLength(1);
  view.panel.element.querySelectorAll("button").find((node) => node.textContent === "Read sealed model request").click();
  await flush();
  expect(view.requests[1][0]).toBe("/runs/request?public_id=run-1&workspace_public_id=w-1&task_key=t-9");
  expect(view.panel.element.querySelector(".task__request pre").textContent).toBe(JSON.stringify(request, null, 2));
  expect(view.panel.element.querySelector(".task__request pre").children).toEqual([]);
  view.panel.dispose();
  expect(view.requests[1][1].aborted).toBe(true);
});

test("an unavailable sealed request reports its error and can be retried without losing task output", async () => {
  let attempts = 0;
  const view = tab((path) => {
    if (!path.startsWith("/runs/request?")) return { task: { kind: "model_task", status: "completed", output: "Kept answer" } };
    if (++attempts === 1) throw new Error("Request no longer retained");
    return { request: { entries: [], request_options: {} } };
  });
  await flush();
  const read = view.panel.element.querySelectorAll("button").find((node) => node.textContent === "Read sealed model request");
  read.click();
  await flush();
  expect(view.panel.element.textContent).toContain("Kept answer");
  expect(view.panel.element.textContent).toContain("Request no longer retained");
  expect(read.disabled).toBe(false);
  read.click();
  await flush();
  expect(view.panel.element.querySelector(".task__request pre")).not.toBeNull();
  expect(view.panel.element.textContent).not.toContain("Request no longer retained");
  view.panel.dispose();
});

test("tasks have no plugin controls without a contribution", async () => {
  for (const task of [
    { kind: "tool_task", status: "dispatched", expected: true },
    { kind: "tool_task", status: "completed", expected: false },
    { kind: "model_task", status: "running", expected: false },
  ]) {
    const view = tab(() => ({ task }));
    await flush();
    expect(view.panel.element.querySelectorAll("button").some((button) => button.textContent === "Open terminal")).toBe(false);
    view.panel.dispose();
    view.panel.element.remove();
  }
});


test("task contributions receive resolved identity and updates and dispose on removal", async () => {
  let status = "running";
  const view = tab(() => ({ task: { kind: "tool_task", status } }));
  const received = [];
  let disposed = 0;
  const remove = view.slots.register("task.detail", { id: "example" }, (props) => {
    received.push(props);
    return { element: document.createElement("div"), update(next) { received.push(next); }, dispose() { disposed++; } };
  });
  expect(received[0].task).toBeNull();
  await flush();
  expect(received.at(-1).target).toEqual({ public_id: "run-1", workspace_public_id: "w-1", task_key: "t-9" });
  expect(received.at(-1).task.status).toBe("running");
  status = "completed";
  view.panel.element.querySelector(".task__head button").click();
  await flush();
  expect(received.at(-1).task.status).toBe("completed");
  remove();
  expect(disposed).toBe(1);
  view.panel.dispose();
  expect(disposed).toBe(1);
});
