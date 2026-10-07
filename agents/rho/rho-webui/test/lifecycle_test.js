import { describe, test, expect, afterEach, afterAll } from "bun:test";
import { executionIdentity, refusalState, conversationTarget, conversationControls, Submissions } from "../webui/lifecycle.js";
import { emptyTurnText } from "../webui/views.js";
import { approvalNotice } from "../webui/controls.js";
const location = globalThis.location;
globalThis.location = new URL("http://localhost");
const { call } = await import("../webui/api.js");
afterAll(() => { globalThis.location = location; });

const fetch = globalThis.fetch;
const storage = globalThis.sessionStorage;
afterEach(() => { globalThis.fetch = fetch; globalThis.sessionStorage = storage; });

describe("conversation execution", () => {
  test("a refused site grant distinguishes the approved request from future permission", () => {
    expect(approvalNotice({ task: { status: "running" }, grant: { refused: "envelope_bound" } }))
      .toBe("This request was approved, but permission for this site could not be saved. Future requests may ask again.");
    for (const result of [{}, { grant: { already: true } }, { grant: { rule: { tool: "web_fetch" } } }]) {
      expect(approvalNotice(result)).toBeNull();
    }
  });

  test("empty assistant history reflects the durable terminal state", () => {
    for (const [status, text] of Object.entries({
      pending: "Working…", running: "Working…", canceled: "Stopped",
      failed: "Response failed", timed_out: "Response timed out", completed: "No response",
    })) {
      expect(emptyTurnText({ role: "assistant", status })).toBe(text);
    }
  });

  test("empty non-assistant messages retain their ordinary placeholder", () => {
    expect(emptyTurnText({ role: "user", status: "completed" })).toBe("Message");
  });

  test("regeneration and swipe select a new execution on the same turn", () => {
    const conversation = { active_turn_public_id: "turn-1" };
    const turns = [{ public_id: "turn-1", active_variant: { public_id: "variant-1", run_public_id: "run-1" } }];
    const snapshot = { turn: "turn-1", run_public_id: "run-1" };
    const settled = executionIdentity(conversation, turns, snapshot);
    expect(settled).toBe("turn-1:run-1");
    turns[0].active_variant = { public_id: "variant-2", run_public_id: "run-2" };
    expect(executionIdentity(conversation, turns, snapshot)).toBe("turn-1:run-2");
    expect(executionIdentity(conversation, turns, snapshot)).not.toBe(settled);
    turns[0].active_variant = { public_id: "direct-variant" };
    expect(executionIdentity(conversation, turns, snapshot)).toBe("turn-1:direct-variant");
  });

  test("a completed reply still offers conversation Stop for background work", () => {
    expect(conversationControls({ active_turn_public_id: null }, "ready")).toEqual({ writable: true, send: true, stop: true });
    expect(conversationControls({ archived_at: "now" }, "ready")).toEqual({ writable: true, send: false, stop: true });
  });

  test("loading, read-only and unavailable views cannot mutate cached content", () => {
    const conversation = { active_turn_public_id: "turn-1" };
    for (const access of ["loading", refusalState({ status: 403 }), refusalState({ status: 404 })]) {
      expect(conversationControls(conversation, access)).toEqual({ writable: false, send: false, stop: false });
    }
    expect(refusalState({ status: 503 })).toBeNull();
    expect(refusalState({ status: 409 })).toBeNull();
    expect(conversationControls(conversation, "ready").send).toBe(true);
  });

  test("a current ingress is read-only with Stop, and release restores ordinary controls", () => {
    const conversation = { ingresses: [{ extension: "rho.ingress_telegram", label: "Telegram · Chat 101" }] };
    expect(conversationControls(conversation, "ready")).toEqual({ writable: false, send: false, stop: true });
    conversation.ingresses = [];
    expect(conversationControls(conversation, "ready")).toEqual({ writable: true, send: true, stop: true });
  });
});

describe("page-owned input retries", () => {
  test("an accepted input whose response was lost reuses its key across conversation navigation", async () => {
    let next = 0;
    const submissions = new Submissions(() => `key-${++next}`);
    const drafts = new Map([["conversation-a", "hello"], ["conversation-b", "keep this draft"]]);
    const body = { ...conversationTarget("conversation-a", "workspace-a"), text: "hello", delivery_mode: "queue" };
    const requests = [];
    const accepted = new Map();
    globalThis.sessionStorage = { getItem: () => "test-only-bearer", removeItem: () => {} };
    globalThis.fetch = async (_url, options) => {
      const sent = JSON.parse(options.body); requests.push(sent);
      accepted.set(sent.idempotency_key, sent.text);
      if (requests.length === 1) throw new TypeError("Failed to fetch");
      return Response.json({ input: { public_id: "input-a" } });
    };
    const first = submissions.prepare("/say", body);
    await expect(call(first.path, { method: "POST", body: first.body })).rejects.toThrow("Failed to fetch");
    submissions.prepare("/say", { public_id: "conversation-b", text: "another input" });
    const retry = submissions.prepare("/say", body);
    expect(retry).toBe(first);
    await call(retry.path, { method: "POST", body: retry.body });
    submissions.accepted(retry, drafts);
    expect(accepted.size).toBe(1);
    expect(requests[1]).toEqual(requests[0]);
    expect(drafts.has("conversation-a")).toBe(false);
    expect(drafts.get("conversation-b")).toBe("keep this draft");
    expect(submissions.prepare("/say", body).body.idempotency_key).not.toBe(first.body.idempotency_key);
  });

  test("a late accepted request preserves newer text and the newer pending submit", () => {
    let next = 0;
    const submissions = new Submissions(() => `key-${++next}`);
    const drafts = new Map([["conversation-a", "new draft"]]);
    const old = submissions.prepare("/say", { public_id: "conversation-a", text: "old draft" });
    const newer = submissions.prepare("/say", { public_id: "conversation-a", text: "new draft" });
    expect(submissions.prepare("/say", { public_id: "conversation-a", text: "old draft" })).toBe(old);
    submissions.accepted(old, drafts);
    expect(drafts.get("conversation-a")).toBe("new draft");
    expect(submissions.find("/say", { public_id: "conversation-a", text: "new draft" })).toBe(newer);
  });

  test("a new conversation retry keeps its original workspace after the default changes", () => {
    const submissions = new Submissions(() => "create-key");
    const body = { prompt: "hello", model: "provider/model" };
    const first = submissions.prepare("/conversations", body, "workspace-a");
    const retry = submissions.prepare("/conversations", body, "workspace-b");
    expect(retry).toBe(first);
    expect(retry.body.workspace_public_id).toBe("workspace-a");
  });

  test("archived A reads and restores remain scoped to A after the default changes", async () => {
    const requests = [];
    globalThis.sessionStorage = { getItem: () => "test-only-bearer", removeItem: () => {} };
    globalThis.fetch = async (url, options) => {
      requests.push([String(url), options.body && JSON.parse(options.body)]);
      return Response.json({ conversation: { public_id: "conversation-a", workspace_public_id: "workspace-a" } });
    };
    const fields = conversationTarget("conversation-a", "workspace-a");
    await call(`/conversations/detail?${new URLSearchParams(fields)}`);
    await call("/conversations/unarchive", { method: "POST", body: fields });
    expect(requests[0][0]).toBe("/conversations/detail?public_id=conversation-a&workspace_public_id=workspace-a");
    expect(requests[1][1]).toEqual(fields);
  });

  test("mutations carry the viewed conversation separately from their exact task owner", async () => {
    const requests = [];
    globalThis.sessionStorage = { getItem: () => "test-only-bearer", removeItem: () => {} };
    globalThis.fetch = async (url, options) => {
      requests.push([url, options]);
      return Response.json({ error: { code: "ingress_bound", message: "Continue in Telegram" } }, { status: 409 });
    };
    await expect(call("/runs/approve", { method: "POST", conversation: "conversation-a",
      body: { public_id: "run-a", task_key: "task-1" } })).rejects.toMatchObject({ code: "ingress_bound", status: 409 });
    expect(requests).toHaveLength(1);
    expect(requests[0][1].headers["x-rho-viewing-conversation"]).toBe("conversation-a");
    expect(JSON.parse(requests[0][1].body).public_id).toBe("run-a");
  });
});
