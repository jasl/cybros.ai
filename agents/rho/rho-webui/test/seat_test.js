import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, key, type, flush } from "./support/dom.js";
import { el } from "../webui/kernel/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { createSeat, executionRow } from "../webui/features/conversation/seat.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const approval = (fields = {}) => ({ kind: "approval", run_public_id: "run-1", task_key: "task-1", tool_name: "bash", tool_input: { command: "ls" }, ...fields });
const question = (fields = {}) => ({ kind: "question", run_public_id: "run-1", task_key: "ask-1", prompt: "Which **branch**?", ...fields });

function seat(overrides = {}) {
  const state = observable({ id: "c-1", access: "ready", detail: { public_id: "c-1", active_turn_public_id: null }, asks: [], inputs: [],
    snapshot: null, error: "", notice: "", busy: false, draft: "", models: [], model: "", reconnecting: false, detached: false, ...overrides });
  const calls = [];
  const conversations = {
    state,
    respond: async (...args) => { calls.push(["respond", ...args]); return true; },
    execute: async (...args) => { calls.push(["execute", ...args]); },
    promote: () => calls.push(["promote"]),
    refresh: () => calls.push(["refresh"]),
  };
  const view = createSeat({ conversations });
  const composer = el("form", { class: "composer" }, el("textarea"));
  view.composerSlot.append(composer);
  document.body.append(view.element);
  const patch = (changes) => state.update((value) => ({ ...value, ...changes }));
  return { view, calls, patch, composer, element: view.element };
}
const buttons = (root) => root.querySelectorAll("button").map((node) => node.textContent);
const press = (root, label) => root.querySelectorAll("button").find((node) => node.textContent === label).click();

test("an approval replaces the composer card and keeps the composer mounted with its draft", () => {
  const { element, composer, patch } = seat();
  composer.querySelector("textarea").value = "half-typed";
  composer.querySelector("textarea").focus();
  patch({ asks: [approval(), approval({ task_key: "task-2" })] });
  const card = element.querySelector(".ask--approval");
  expect(card.textContent).toContain("Approval required");
  expect(card.textContent).toContain("1 of 2");
  expect(card.querySelector(".ask__input").textContent).toBe(JSON.stringify({ command: "ls" }, null, 2));
  expect(buttons(card)).toEqual(["Deny", "Approve"]);
  expect(element.querySelector(".seat__composer").hidden).toBe(true);
  expect(composer.isConnected).toBe(true);
  expect(composer.querySelector("textarea").value).toBe("half-typed");
  expect(document.activeElement.textContent).toBe("Approve");
  patch({ asks: [] });
  expect(element.querySelector(".seat__composer").hidden).toBe(false);
});

test("Enter approves and Escape denies only when the card itself has focus", async () => {
  const { element, calls, patch } = seat({ asks: [approval()] });
  const card = element.querySelector(".ask--approval");
  key(card.querySelector("button"), "Enter");
  key(card.querySelector("button"), "Escape");
  expect(calls).toEqual([]);
  key(card, "Enter");
  await flush();
  expect(calls).toEqual([["respond", approval(), "/runs/approve", undefined]]);
  patch({ asks: [approval({ task_key: "task-3" })] });
  key(element.querySelector(".ask--approval"), "Escape");
  await flush();
  expect(calls.at(-1)).toEqual(["respond", approval({ task_key: "task-3" }), "/runs/deny", undefined]);
});

test("web_fetch offers a site grant that approves with always and states the literal site policy", async () => {
  const { element, calls } = seat({ asks: [approval({ tool_name: "web_fetch", tool_input: { url: "https://example.test/a" } })] });
  const card = element.querySelector(".ask--approval");
  expect(buttons(card)).toEqual(["Deny", "Allow this site until restart", "Approve"]);
  expect(card.textContent).toContain("No subdomains, www variants");
  press(card, "Allow this site until restart");
  await flush();
  expect(calls[0].slice(2)).toEqual(["/runs/approve", { always: true }]);
});

test("MCP approval identifies the callable and external account without treating a remote web_fetch as the local site tool", async () => {
  const ask = approval({ tool_name: "web_fetch", tool_alias: "read_notes", tool_input: { url: "https://notes.test/" },
    target: { kind: "mcp", connection_public_id: "notes-personal", display_name: "Notes", account_label: "Personal <b>account</b>", tool_name: "web_fetch" } });
  const { element, calls } = seat({ asks: [ask] });
  const card = element.querySelector(".ask--approval");
  expect(card.querySelector(".ask__headline").textContent).toBe("read_notes");
  expect(card.querySelectorAll(".mcp-target dt").map((node) => node.textContent)).toEqual(["MCP connection", "Account", "Remote tool"]);
  expect(card.querySelectorAll(".mcp-target dd").map((node) => node.textContent)).toEqual(["Notes", "Personal <b>account</b>", "web_fetch"]);
  expect(card.querySelector(".mcp-target b")).toBeNull();
  expect(buttons(card)).toEqual(["Deny", "Approve"]);
  expect(card.querySelector(".ask__policy")).toBeNull();
  press(card, "Approve"); await flush();
  expect(calls).toEqual([["respond", ask, "/runs/approve", undefined]]);
});

test("a question takes an answer with Enter or Send answer, keeps a newline with Shift+Enter and keeps its draft across repaints", async () => {
  const { element, calls, patch } = seat({ asks: [question()] });
  const card = element.querySelector(".ask--question");
  expect(card.textContent).toContain("rho needs your answer");
  expect(card.querySelector("strong").textContent).toBe("branch");
  const field = card.querySelector("textarea");
  key(field, "Enter");
  await flush();
  expect(calls).toEqual([]);
  type(field, "main");
  key(field, "Enter", { shiftKey: true });
  expect(calls).toEqual([]);
  patch({ asks: [question(), approval({ task_key: "later" })] });
  expect(element.querySelector(".ask--question textarea").value).toBe("main");
  key(element.querySelector(".ask--question textarea"), "Enter");
  await flush();
  expect(calls).toEqual([["respond", question(), "/answer", { content: "main" }]]);
});

test("waiting questions keep the current answer's focus when the queue changes and move it to the next question", () => {
  const { element, composer, patch } = seat();
  composer.querySelector("textarea").focus();
  patch({ asks: [question()] });
  const answer = element.querySelector(".ask textarea");
  type(answer, "main");
  patch({ asks: [question(), question({ task_key: "ask-2", prompt: "Which test?" })] });
  expect(element.querySelector(".ask textarea")).toBe(answer);
  expect(document.activeElement).toBe(answer);
  expect(element.querySelector(".ask__count").textContent).toBe("1 of 2");
  patch({ asks: [question({ task_key: "ask-2", prompt: "Which test?" })] });
  const next = element.querySelector(".ask textarea");
  expect(document.activeElement).toBe(next);
  expect(next.value).toBe("");
  expect(element.querySelector(".ask__count").hidden).toBe(true);
  patch({ asks: [] });
  expect(document.activeElement).toBe(composer.querySelector("textarea"));
});

test("finishing an approval keeps keyboard focus on the next approval without stealing focus from elsewhere", () => {
  const { element, composer, patch } = seat();
  composer.querySelector("textarea").focus();
  patch({ asks: [approval(), approval({ task_key: "task-2" })] });
  patch({ asks: [approval({ task_key: "task-2" })] });
  expect(document.activeElement).toBe(element.querySelectorAll(".ask button").find((node) => node.textContent === "Approve"));
  const elsewhere = el("button");
  document.body.append(elsewhere);
  elsewhere.focus();
  patch({ asks: [approval({ task_key: "task-3" })] });
  expect(document.activeElement).toBe(elsewhere);
});

test("a read-only view shows its cards disabled", () => {
  const { element } = seat({ asks: [approval()], detail: { public_id: "c-1", ingresses: [{ label: "Telegram · Chat 7" }] } });
  expect(element.querySelectorAll(".ask button").every((node) => node.disabled)).toBe(true);
  expect(element.querySelector(".seat__notice").textContent).toBe("Telegram · Chat 7 — Continue in the original channel. This page is read-only. Stop remains available.");
});

test("the execution row pauses and resumes a live run and offers retry or abandon for a failed step", async () => {
  const actions = [];
  const live = executionRow({ run_public_id: "run-1", run_status: "running", tasks: [] }, async (...args) => actions.push(args));
  expect(live.textContent).toContain("Execution in progress");
  press(live, "Pause");
  await flush();
  expect(executionRow({ run_public_id: "run-1", run_status: "paused", tasks: [] }, () => {}).textContent).toContain("Resume");
  const failed = { task_key: "r1", status: "failed", on_failure: "halt", error_key: "provider_context_overflow" };
  const held = executionRow({ run_public_id: "run-1", run_status: "needs_attention", tasks: [failed] }, async (...args) => actions.push(args));
  expect(held.textContent).toContain("Step r1 · failed");
  expect(held.textContent).toContain("Input token limit or Combined context window");
  press(held, "Retry failed step");
  await flush();
  press(held, "Abandon failed step");
  await flush();
  expect(actions).toEqual([["/runs/pause", { public_id: "run-1" }], ["/runs/retry", { public_id: "run-1", task_key: "r1" }],
    ["/runs/abandon", { public_id: "run-1", task_key: "r1" }]]);
});

test("recovered, absorbed or settled failures show no model-limit hint and finished runs no row", () => {
  const failed = { task_key: "r1", status: "failed", on_failure: "halt", error_key: "provider_context_overflow" };
  for (const fields of [{ status: "running" }, { failure_resolution: "abandoned" }, { on_failure: "absorb" }, { error_key: "other" }]) {
    const row = executionRow({ run_public_id: "run-1", run_status: "running", tasks: [{ ...failed, ...fields }] }, () => {});
    expect(row.textContent).not.toContain("Context and capabilities");
  }
  expect(executionRow({ run_public_id: "run-1", run_status: "completed", tasks: [] }, () => {})).toBeNull();
  expect(executionRow(null, () => {})).toBeNull();
});

test("a cost-refused model keeps explicit retry and abandon despite its declared failure policy", async () => {
  for (const on_failure of ["absorb", "propagate"]) {
    const actions = [];
    const task = { task_key: "summary", kind: "model_task", status: "failed", on_failure, error_key: "conversation_cost_limit_reached" };
    const row = executionRow({ run_public_id: "run-1", run_status: "needs_attention", tasks: [task] }, async (...args) => actions.push(args),
      { nexusUrl: "https://nexus.example", conversationId: "chat-1" });
    expect(row.textContent).toContain("Step summary · failed");
    expect(row.textContent).toContain("Conversation cost limit reached");
    expect(row.textContent).toContain("Completed tools and their results are preserved");
    expect(row.textContent).not.toContain("Execution in progress");
    expect(buttons(row)).not.toContain("Pause");
    expect(row.querySelector("a").getAttribute("href")).toBe("https://nexus.example/conversations/chat-1/cost_limit/edit");
    expect(row.querySelector("a").getAttribute("target")).toBe("_blank");
    press(row, "Retry failed step");
    await flush();
    press(row, "Abandon failed step");
    await flush();
    expect(actions).toEqual([["/runs/retry", { public_id: "run-1", task_key: "summary" }],
      ["/runs/abandon", { public_id: "run-1", task_key: "summary" }]]);
  }
});

test("a pending or canceling execution shows its status without offering an unavailable pause", () => {
  for (const status of ["pending", "canceling"]) {
    const row = executionRow({ run_public_id: "run-1", run_status: status, tasks: [] }, () => {});
    expect(row.textContent).not.toContain("Execution in progress");
    expect(buttons(row)).not.toContain("Pause");
  }
});

test("ordinary absorbed failures, non-model errors and resolved cost refusals offer no repair action", () => {
  const task = { task_key: "summary", kind: "model_task", status: "failed", on_failure: "absorb", error_key: "conversation_cost_limit_reached" };
  for (const fields of [{ error_key: "provider_model_unavailable" }, { kind: "tool_task" }, { failure_resolution: "abandoned" }, { status: "running" }]) {
    const row = executionRow({ run_public_id: "run-1", run_status: "running", tasks: [{ ...task, ...fields }] }, () => {});
    expect(buttons(row)).not.toContain("Retry failed step");
    expect(buttons(row)).not.toContain("Abandon failed step");
  }
});

test("a failed execution action is shown on the row and its buttons come back", async () => {
  const row = executionRow({ run_public_id: "run-1", run_status: "running", tasks: [] }, async () => { throw new Error("Run is held"); });
  document.body.append(row);
  press(row, "Pause");
  await flush();
  expect(row.querySelector(".alert").textContent).toBe("Run is held");
  expect(row.querySelector("button").disabled).toBe(false);
});

test("waiting inputs list their delivery labels and offer Send now on the latest waiting steer only", () => {
  const inputs = [{ public_id: "a", state: "steering", delivery_mode: "steer", queue_position: 1, text: "first" },
    { public_id: "b", state: "steering", delivery_mode: "steer", queue_position: 2, text: "second" },
    { public_id: "c", state: "pending", delivery_mode: "queue", queue_position: 3, text: "later" }];
  const { element, calls } = seat({ inputs, detail: { public_id: "c-1", active_turn_public_id: "t" } });
  const rows = element.querySelectorAll(".queue__row");
  expect(rows.map((row) => row.querySelector(".queue__label").textContent)).toEqual(["Additional instruction waiting to be read",
    "Additional instruction waiting to be read", "Message queued"]);
  expect(rows.map((row) => !!row.querySelector("button"))).toEqual([false, true, false]);
  rows[1].querySelector("button").click();
  expect(calls).toEqual([["promote"]]);
});

test("refusals and a detached view say so with Refresh; loading and reconnecting do not offer it", () => {
  const { element, calls, patch } = seat({ access: "loading", detail: null });
  const connection = element.querySelectorAll(".seat__notice")[1];
  const message = () => connection.querySelector("span").textContent;
  expect(message()).toBe("Loading conversation…");
  expect(connection.querySelector("button").hidden).toBe(true);
  patch({ access: "read-only", detail: { public_id: "c-1" } });
  expect(message()).toBe("This conversation is read-only. Use Refresh to check access again.");
  connection.querySelector("button").click();
  expect(calls).toEqual([["refresh"]]);
  patch({ access: "ready", detached: true });
  expect(message()).toBe("This conversation is not attached. Use Refresh to reconnect.");
  expect(connection.querySelector("button").hidden).toBe(false);
  patch({ detached: false, reconnecting: true });
  expect(message()).toBe("Connection interrupted. Reconnecting…");
  expect(connection.querySelector("button").hidden).toBe(true);
  patch({ reconnecting: false });
  expect(connection.hidden).toBe(true);
  patch({ readError: "Connection refused" });
  expect(message()).toBe("Connection refused");
  expect(connection.querySelector("button").hidden).toBe(false);
  patch({ readError: "" });
  expect(connection.hidden).toBe(true);
  patch({ error: "Busy", notice: "Saved, but later requests may ask again." });
  expect(element.querySelector(".alert--error").textContent).toBe("Busy");
  expect(element.querySelector(".alert--warning").textContent).toBe("Saved, but later requests may ask again.");
});
