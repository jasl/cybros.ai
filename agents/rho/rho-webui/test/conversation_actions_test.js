import { test, expect, describe } from "bun:test";
import { observable } from "../webui/kernel/observable.js";
import { Submissions } from "../webui/kernel/submissions.js";
import { createConversations } from "../webui/features/conversation/controller.js";
import { approvalNotice } from "../webui/features/conversation/actions.js";
import { reviewDetail } from "../webui/features/conversation/header.js";
import { createWorkspaces } from "../webui/shell/workspaces.js";

const settle = async () => { for (let index = 0; index < 30; index += 1) await Promise.resolve(); };
const refused = (status, code, message = code) => Object.assign(new Error(message), { status, code });

function harness({ address = { conversation: "c-1", workspace: "w-1" }, detail = { public_id: "c-1", workspace_public_id: "w-1" }, rows = [], inputs = [],
  readWorkspaces = () => ({ workspace: { public_id: "w-default" } }) } = {}) {
  const requests = [];
  const toasts = [];
  const handlers = {
    "POST /followers/attach": () => ({}),
    "GET /conversations/detail": ({ query }) => ({ conversation: { ...detail, public_id: query.get("public_id") } }),
    // A response route alone never declares an explicit model choice.
    "GET /conversations/turns": () => ({ turns: [{ public_id: "t-1", position: 1, role: "assistant", status: "completed",
      active_variant: { public_id: "v-1", model: { provider_id: "local", model_ref: "model" }, content: "Done." } }], pagination: {} }),
    "GET /conversations/modes": () => ({ modes: { available: true, code_mode_available: true, code_mode: true, subagent: true } }),
    "GET /asks": () => ({ asks: [] }),
    "GET /inputs": () => ({ inputs }),
    "GET /followers": () => ({ followers: [] }),
    "GET /models": () => ({ models: [{ ref: "local/model", display_name: "Local" }] }),
    "GET /runners": () => ({ runners: [{ public_id: "runner-own", own: true, root: "/work" }] }),
    "GET /conversations": () => ({ conversations: rows, pagination: {} }),
    "GET /workspaces": readWorkspaces,
  };
  const call = async (path, options = {}) => {
    const method = options.method || "GET";
    const route = path.split("?")[0];
    requests.push({ method, route, body: options.body, conversation: options.conversation });
    const handler = handlers[`${method} ${route}`];
    if (!handler) throw new Error(`unexpected ${method} ${path}`);
    return handler({ query: new URLSearchParams(path.split("?")[1] || ""), body: options.body });
  };
  const follow = (_id, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })), { once: true });
  });
  let location = { panel: null, conversation: null, workspace: null, plugin: null, ...address };
  const router = { read: () => ({ ...location }), push(changes) { location = { ...location, ...changes }; }, replace(changes) { location = { ...location, ...changes }; }, subscribe: () => () => {} };
  const setup = { state: observable({ document: { settings: { default_model: "local/model" } },
    status: { connected: true, model: { ready: true }, defaults: { runner_executor_public_id: "runner-own", conversation_modes: { available: true, code_mode_available: true, code_mode: true, subagent: true } } } }) };
  const session = new AbortController();
  const workspaces = createWorkspaces({ call, signal: session.signal, router, storage: null });
  // The page lists its workspaces at boot; the conversation list waits for that read.
  workspaces.refresh();
  const conversations = createConversations({ call, follow, artifactBytes: async () => new Blob(), signal: session.signal,
    toast: (text, options) => toasts.push([text, options?.tone]), router, setup, workspaces, openDock: () => {}, openSettings: () => {} });
  const posts = (route) => requests.filter((request) => request.method !== "GET" && request.route === route);
  return { conversations, requests, handlers, toasts, posts, state: () => conversations.state.get() };
}

async function opened(options) {
  const h = harness(options);
  h.conversations.start();
  await settle();
  return h;
}

describe("page-owned input retries", () => {
  test("an accepted input whose response was lost reuses its key; another conversation's draft is untouched", async () => {
    let next = 0;
    const submissions = new Submissions(() => `key-${++next}`);
    const drafts = new Map([["conversation-a", "hello"], ["conversation-b", "keep this draft"]]);
    const body = { public_id: "conversation-a", workspace_public_id: "workspace-a", text: "hello", delivery_mode: "queue" };
    const first = submissions.prepare("/say", body);
    submissions.prepare("/say", { public_id: "conversation-b", text: "another input" });
    const retry = submissions.prepare("/say", body);
    expect(retry).toBe(first);
    submissions.accepted(retry, drafts);
    expect(drafts.has("conversation-a")).toBe(false);
    expect(drafts.get("conversation-b")).toBe("keep this draft");
    expect(submissions.prepare("/say", body).body.idempotency_key).not.toBe(first.body.idempotency_key);
  });

  test("a new conversation retry keeps its original workspace after the default changes", () => {
    const submissions = new Submissions(() => "create-key");
    const body = { prompt: "hello", model: "provider/model" };
    const first = submissions.prepare("/conversations", body, "workspace-a");
    expect(submissions.prepare("/conversations", body, "workspace-b").body.workspace_public_id).toBe("workspace-a");
    expect(first.body.idempotency_key).toBe("create-key");
  });

  test("a refused site grant distinguishes the approved request from future permission", () => {
    expect(approvalNotice({ grant: { refused: "envelope_bound" } })).toContain("permission for this site could not be saved");
    for (const result of [{}, { grant: { already: true } }, { grant: { rule: { tool: "web_fetch" } } }]) expect(approvalNotice(result)).toBeNull();
  });
});

describe("conversation writes", () => {
  test("initial workspace discovery preserves a newer resolved draft, including a cleared draft", async () => {
    for (const draft of ["newer draft in the known workspace", ""]) {
      let resolveWorkspace;
      const workspace = new Promise((resolve) => { resolveWorkspace = resolve; });
      const h = await opened({ address: {}, detail: { public_id: "c-1", workspace_public_id: "w-default" }, readWorkspaces: () => workspace });
      h.conversations.startNew({ agent: "bot-a" });
      h.conversations.setDraft("earlier draft before workspace discovery");
      await h.conversations.select("c-1", { workspace: "w-default" });
      h.conversations.startNew({ agent: "bot-a" });
      h.conversations.setDraft(draft);
      resolveWorkspace({ workspace: { public_id: "w-default" }, workspaces: [{ public_id: "w-default" }] });
      await settle();
      expect(h.state().draft).toBe(draft);
      h.conversations.startNew({ agent: "bot-b" });
      h.conversations.startNew({ agent: "bot-a" });
      expect(h.state().draft).toBe(draft);
      h.conversations.dispose();
    }
  });

  test("an early draft stays in the default workspace when a conversation opens before discovery", async () => {
    let resolveWorkspace;
    const workspace = new Promise((resolve) => { resolveWorkspace = resolve; });
    const h = await opened({ address: {}, readWorkspaces: () => workspace });
    h.conversations.startNew({ agent: "bot-a" });
    h.conversations.setDraft("draft for the default workspace");
    await h.conversations.select("c-1", { workspace: "w-1" });
    resolveWorkspace({ workspace: { public_id: "w-default" }, workspaces: [{ public_id: "w-1" }, { public_id: "w-default" }] });
    await settle();
    h.conversations.startNew({ agent: "bot-a" });
    expect(h.state()).toMatchObject({ workspace: "w-1", draft: "" });
    await h.conversations.select(null, { workspace: "w-default", agent: "bot-a" });
    expect(h.state().draft).toBe("draft for the default workspace");
    h.conversations.dispose();
  });

  test("resolving the initial workspace preserves every bot's early draft", async () => {
    let resolveWorkspace;
    const workspace = new Promise((resolve) => { resolveWorkspace = resolve; });
    const h = await opened({ address: {}, readWorkspaces: () => workspace });
    h.conversations.startNew({ agent: "bot-a" });
    h.conversations.setDraft("draft for A");
    h.conversations.startNew({ agent: "bot-b" });
    h.conversations.setDraft("draft for B");
    resolveWorkspace({ workspace: { public_id: "w-default" } });
    await settle();
    expect(h.state().draft).toBe("draft for B");
    h.conversations.startNew({ agent: "bot-a" });
    expect(h.state().draft).toBe("draft for A");
    h.conversations.dispose();
  });

  test("a send begun before the initial workspace resolves retries with the same key", async () => {
    let resolveWorkspace;
    const workspace = new Promise((resolve) => { resolveWorkspace = resolve; });
    const h = await opened({ address: {}, readWorkspaces: () => workspace });
    h.handlers["POST /conversations"] = () => { throw new TypeError("Failed to fetch"); };
    h.conversations.setDraft("first request");
    const sending = h.conversations.send();
    await settle();
    resolveWorkspace({ workspace: { public_id: "w-default" } });
    await sending;
    expect(h.state().draft).toBe("first request");
    await h.conversations.send();
    const [first, retry] = h.posts("/conversations");
    expect(first.body.workspace_public_id).toBe("w-default");
    expect(retry.body).toEqual(first.body);
    h.conversations.dispose();
  });

  test("resolving the initial workspace during a send keeps later typing with the created conversation", async () => {
    let resolveWorkspace;
    const workspace = new Promise((resolve) => { resolveWorkspace = resolve; });
    const h = await opened({ address: {}, readWorkspaces: () => workspace });
    let accept;
    h.handlers["POST /conversations"] = () => new Promise((resolve) => { accept = () => resolve({ conversation: { public_id: "c-created" } }); });
    h.conversations.setDraft("first request");
    const sending = h.conversations.send();
    await settle();
    resolveWorkspace({ workspace: { public_id: "w-default" } });
    await settle();
    h.conversations.setDraft("next message");
    accept();
    await sending;
    expect(h.state()).toMatchObject({ id: "c-created", draft: "next message" });
    h.conversations.dispose();
  });

  test("new drafts stay with their workspace and bot when the recipient changes", async () => {
    const h = await opened({ address: {} });
    await h.conversations.select(null, { workspace: "w-a", agent: "bot-a" });
    h.conversations.setDraft("for this bot in workspace A");
    await h.conversations.select(null, { workspace: "w-a", agent: "bot-b" });
    expect(h.state().draft).toBe("");
    h.conversations.setDraft("for the other bot");
    await h.conversations.select(null, { workspace: "w-b", agent: "bot-a" });
    expect(h.state().draft).toBe("");
    h.conversations.setDraft("for workspace B");
    await h.conversations.select(null, { workspace: "w-a", agent: "bot-a" });
    expect(h.state().draft).toBe("for this bot in workspace A");
    await h.conversations.select(null, { workspace: "w-a", agent: "bot-b" });
    expect(h.state().draft).toBe("for the other bot");
    await h.conversations.select(null, { workspace: "w-b", agent: "bot-a" });
    expect(h.state().draft).toBe("for workspace B");
  });

  test("uncertain creates retry in their compose context without redirecting a different workspace's message", async () => {
    const h = await opened({ address: {} });
    h.handlers["POST /conversations"] = () => { throw new TypeError("Failed to fetch"); };
    await h.conversations.select(null, { workspace: "w-a" });
    h.conversations.setDraft("hello");
    await h.conversations.send();
    await h.conversations.select(null, { workspace: "w-b" });
    h.conversations.setDraft("hello");
    await h.conversations.send();
    await h.conversations.select(null, { workspace: "w-a" });
    await h.conversations.send();
    const [first, other, retry] = h.posts("/conversations");
    expect(first.body.workspace_public_id).toBe("w-a");
    expect(other.body.workspace_public_id).toBe("w-b");
    expect(other.body.idempotency_key).not.toBe(first.body.idempotency_key);
    expect(retry.body).toEqual(first.body);
  });

  test("a create that finishes after switching bots leaves the new recipient and its draft alone", async () => {
    const h = await opened({ address: {} });
    let accept;
    h.handlers["POST /conversations"] = () => new Promise((resolve) => { accept = () => resolve({ conversation: { public_id: "c-created" } }); });
    h.conversations.startNew({ agent: "bot-a" });
    h.conversations.setDraft("first request");
    const creating = h.conversations.send();
    await settle();
    h.conversations.startNew({ agent: "bot-b" });
    h.conversations.setDraft("second recipient's draft");
    accept();
    await creating;
    expect(h.state()).toMatchObject({ id: null, agent: "bot-b", draft: "second recipient's draft", busy: false });
    h.conversations.startNew({ agent: "bot-a" });
    expect(h.state().draft).toBe("");
  });

  test("drafts belong to their conversation and come back when it is shown again", async () => {
    const h = await opened();
    h.conversations.setDraft("for the first");
    await h.conversations.select("c-2");
    expect(h.state().draft).toBe("");
    h.conversations.setDraft("for the second");
    await h.conversations.select("c-1");
    expect(h.state().draft).toBe("for the first");
    h.conversations.startNew();
    expect(h.state()).toMatchObject({ id: null, draft: "" });
  });

  test("a failed send keeps the draft and its key, and text typed while the retry is in flight survives it", async () => {
    const h = await opened();
    h.conversations.setModel("local/model");
    h.conversations.setDraft("hello");
    h.handlers["POST /say"] = () => { throw new TypeError("Failed to fetch"); };
    await h.conversations.send();
    expect(h.state()).toMatchObject({ draft: "hello", busy: false, error: "Failed to fetch" });
    let accept;
    h.handlers["POST /say"] = () => new Promise((resolve) => { accept = () => resolve({ input: { public_id: "input-1" } }); });
    const sending = h.conversations.send();
    await settle();
    expect(h.state().busy).toBe(true);
    h.conversations.setDraft("hello again");
    accept();
    await sending;
    const [failed, retried] = h.posts("/say");
    expect(retried.body).toEqual(failed.body);
    expect(retried.body).toMatchObject({ public_id: "c-1", workspace_public_id: "w-1", text: "hello", model: "local/model",
      approval_mode: "ask", delivery_mode: "steer" });
    expect(retried.conversation).toBe("c-1");
    expect(h.state()).toMatchObject({ draft: "hello again", busy: false });
  });

  test("an accepted send clears exactly the submitted draft and preserves the saved conversation modes", async () => {
    const h = await opened();
    h.handlers["POST /say"] = () => ({ input: {} });
    h.conversations.setDelivery("queue");
    h.conversations.setDraft("queue this");
    await h.conversations.send();
    expect(h.posts("/say")[0].body).toMatchObject({ text: "queue this", delivery_mode: "queue" });
    expect(h.posts("/say")[0].body).not.toHaveProperty("code_mode");
    expect(h.posts("/say")[0].body).not.toHaveProperty("subagent");
    expect(h.state().draft).toBe("");
  });

  test("a create freezes the default workspace and runner, opens the conversation and moves newer text to it", async () => {
    const h = await opened({ address: {} });
    expect(h.state()).toMatchObject({ id: null, runner: "runner-own", model: "", modelEdited: false });
    h.conversations.setDraft("build it");
    let accept;
    h.handlers["POST /conversations"] = () => new Promise((resolve) => { accept = () => resolve({ conversation: { public_id: "c-new" } }); });
    const focus = h.state().focus;
    const creating = h.conversations.send();
    await settle();
    h.conversations.setDraft("build it, then test");
    accept();
    await creating;
    await settle();
    const [create] = h.posts("/conversations");
    expect(create.body).toMatchObject({ prompt: "build it", approval_mode: "ask",
      default_runner_executor_public_id: "runner-own", workspace_public_id: "w-default",
      code_mode: true, subagent: true });
    expect(create.body).not.toHaveProperty("environment");
    expect(create.body).not.toHaveProperty("working_directory");
    expect(create.body).not.toHaveProperty("model");
    expect(typeof create.body.idempotency_key).toBe("string");
    expect(h.state()).toMatchObject({ id: "c-new", draft: "build it, then test" });
    expect(h.state().focus).toBe(focus + 1);
  });

  test("switching the new conversation's Runner leaves its default directory to that Runner", async () => {
    const h = harness({ address: {} });
    h.handlers["GET /runners"] = () => ({ runners: [
      { public_id: "runner-own", own: true, root: "/work/local" },
      { public_id: "runner-remote", own: false, root: "/srv/remote" },
    ] });
    h.handlers["POST /conversations"] = ({ body }) => ({ conversation: { public_id: `c-${body.default_runner_executor_public_id}` } });
    h.conversations.start();
    await settle();
    expect(h.state().runner).toBe("runner-own");
    for (const runner of ["runner-remote", "runner-own"]) {
      h.conversations.startNew();
      h.conversations.setRunner(runner);
      h.conversations.setDraft("use this Runner's default directory");
      await h.conversations.send();
      const create = h.posts("/conversations").at(-1);
      expect(create.body.default_runner_executor_public_id).toBe(runner);
      expect(create.body).not.toHaveProperty("environment");
      expect(create.body).not.toHaveProperty("working_directory");
    }
    h.conversations.dispose();
  });

  test("choosing the default route explicitly pins it on a new conversation", async () => {
    const h = await opened({ address: {} });
    h.handlers["POST /conversations"] = () => ({ conversation: { public_id: "c-new" } });
    h.conversations.setModel("local/model");
    h.conversations.setDraft("use this route");
    await h.conversations.send();
    expect(h.posts("/conversations")[0].body.model).toBe("local/model");
    h.conversations.dispose();
  });

  test("an untouched captured intent is omitted and choosing Automatic sends null to clear it", async () => {
    const h = harness();
    h.handlers["GET /conversations/turns"] = () => ({ turns: [{ public_id: "t-1", position: 1, role: "assistant", active_variant: {
      model: { provider_id: "backup", model_ref: "model" },
      model_selection: { source: "explicit", model: "local/model", constraint: "model", alternatives: ["backup/model"] },
    } }], pagination: {} });
    h.handlers["POST /say"] = () => ({ input: {} });
    h.conversations.start();
    await settle();
    expect(h.state()).toMatchObject({ model: "local/model", modelEdited: false, actualModel: "backup/model" });
    h.conversations.setDraft("keep the existing intent");
    await h.conversations.send();
    expect(h.posts("/say")[0].body).not.toHaveProperty("model");
    expect(h.posts("/say")[0].body).not.toHaveProperty("model_selection");
    h.conversations.setModel("");
    h.conversations.setDraft("use the Preset again");
    await h.conversations.send();
    expect(h.posts("/say")[1].body).toHaveProperty("model", null);
    expect(h.state()).toMatchObject({ model: "", modelEdited: true });
    h.conversations.dispose();
  });

  test("a new conversation started from a bot's group names the bot on its create; rho's own names nobody", async () => {
    const h = await opened({ address: {} });
    h.handlers["POST /conversations"] = () => ({ conversation: { public_id: "c-bot" } });
    h.conversations.startNew({ agent: "u-reviewer" });
    expect(h.state()).toMatchObject({ id: null, agent: "u-reviewer" });
    h.conversations.setDraft("review the branch");
    await h.conversations.send();
    await settle();
    expect(h.posts("/conversations")[0].body).toMatchObject({ prompt: "review the branch", agent: "u-reviewer" });
    // The opened conversation's answerer is its own fact, not the draft's.
    expect(h.state()).toMatchObject({ id: "c-bot", agent: null });
    h.conversations.startNew();
    expect(h.state().agent).toBeNull();
    h.conversations.setDraft("plain");
    await h.conversations.send();
    await settle();
    expect(h.posts("/conversations")[1].body).not.toHaveProperty("agent");
  });

  test("Send now sends the draft as an immediate steer, or promotes the latest waiting steer when the draft is empty", async () => {
    const inputs = [{ public_id: "older", state: "steering", delivery_mode: "steer", queue_position: 1 },
      { public_id: "latest", state: "steering", delivery_mode: "steer", queue_position: 2 }];
    const h = await opened({ inputs });
    h.handlers["POST /inputs/update"] = () => ({});
    h.handlers["POST /say"] = () => ({ input: {} });
    await h.conversations.sendNow();
    expect(h.posts("/inputs/update")[0].body).toEqual({ public_id: "c-1", workspace_public_id: "w-1", host_type: "conversation",
      input_public_id: "latest", delivery_mode: "steer_now" });
    h.conversations.setDraft("read this now");
    await h.conversations.sendNow();
    expect(h.posts("/say")[0].body).toMatchObject({ text: "read this now", delivery_mode: "steer_now" });
  });

  test("Mod+Enter also sends when a conversation is new or idle", async () => {
    const h = await opened({ address: {} });
    h.handlers["POST /conversations"] = () => ({ conversation: { public_id: "c-new" } });
    h.handlers["POST /say"] = () => ({ input: {} });
    h.conversations.setDraft("start working");
    await h.conversations.sendNow();
    await settle();
    expect(h.posts("/conversations")).toHaveLength(1);
    expect(h.state().draft).toBe("");
    h.conversations.setDraft("the next task");
    await h.conversations.sendNow();
    expect(h.posts("/say")[0].body.text).toBe("the next task");
  });

  test("Stop forces every execution owner to stop and reads the conversation again", async () => {
    const h = await opened();
    h.handlers["POST /stop"] = () => ({});
    const reads = h.requests.filter((request) => request.route === "/conversations/detail").length;
    await h.conversations.stop();
    expect(h.posts("/stop")[0]).toMatchObject({ body: { public_id: "c-1", workspace_public_id: "w-1", host_type: "conversation", force: true }, conversation: "c-1" });
    expect(h.requests.filter((request) => request.route === "/conversations/detail").length).toBe(reads + 1);
  });

  test("a write refused because an ingress owns the conversation reads it again and says why", async () => {
    const h = await opened();
    h.conversations.setDraft("from the page");
    h.handlers["POST /say"] = () => { throw refused(409, "ingress_bound", "Continue in Telegram"); };
    h.handlers["GET /conversations/detail"] = () => ({ conversation: { public_id: "c-1", ingresses: [{ label: "Telegram · Chat 7" }] } });
    await h.conversations.send();
    await settle();
    expect(h.state().error).toBe("Continue in Telegram");
    expect(h.state().detail.ingresses).toHaveLength(1);
    expect(h.conversations.selection.get().writable).toBe(false);
    expect(h.state().draft).toBe("from the page");
  });

  test("row actions name the row's own workspace; the open conversation uses its current one", async () => {
    const rows = [{ public_id: "c-9", workspace_public_id: "w-9", title: "Other" }];
    const h = await opened({ rows });
    h.handlers["PATCH /conversations"] = () => ({});
    h.handlers["POST /conversations/archive"] = () => ({});
    h.handlers["POST /conversations/unarchive"] = () => ({});
    expect(await h.conversations.rename("c-9", "  New title ")).toBe(true);
    expect(h.posts("/conversations")[0]).toMatchObject({ body: { public_id: "c-9", workspace_public_id: "w-9", title: "New title" }, conversation: "c-9" });
    await h.conversations.archive("c-1");
    expect(h.posts("/conversations/archive")[0]).toMatchObject({ body: { public_id: "c-1", workspace_public_id: "w-1" }, conversation: "c-1" });
    await h.conversations.restore("c-9");
    expect(h.posts("/conversations/unarchive")[0].body).toEqual({ public_id: "c-9", workspace_public_id: "w-9" });
    h.handlers["POST /conversations/archive"] = () => { throw refused(409, "ingress_bound", "Continue in Telegram"); };
    expect(await h.conversations.archive("c-9")).toBe(false);
    expect(h.toasts).toEqual([["Continue in Telegram", "error"]]);
  });

  test("memory review is read on open and switched on or off against the person's own document", async () => {
    const h = harness();
    let status = { enabled: false, path: null, model: null, pending: false, outcome: null };
    h.handlers["GET /conversations/memory_review"] = () => ({ memory_review: status });
    h.handlers["POST /conversations/memory_review/enable"] = ({ body }) => {
      status = { ...status, enabled: true, path: body.path };
      return { memory_review: status };
    };
    h.handlers["POST /conversations/memory_review/disable"] = () => { status = { ...status, enabled: false }; return { memory_review: status }; };
    h.conversations.start();
    await settle();
    expect(h.state().review).toEqual({ enabled: false, path: null, model: null, pending: false, outcome: null });
    expect(reviewDetail(h.state().review)).toContain("user/review.md up to date");

    expect(await h.conversations.setMemoryReview(true)).toBe(true);
    expect(h.posts("/conversations/memory_review/enable")[0]).toMatchObject({ body: { public_id: "c-1", workspace_public_id: "w-1", path: "user/review.md" }, conversation: "c-1" });
    expect(h.state().review).toMatchObject({ enabled: true, path: "user/review.md" });
    expect(reviewDetail(h.state().review)).toBe("On · user/review.md");
    expect(reviewDetail({ ...h.state().review, outcome: "failed" })).toBe("On · user/review.md · the last review failed");

    expect(await h.conversations.setMemoryReview(false)).toBe(true);
    expect(h.posts("/conversations/memory_review/disable")[0].body).toEqual({ public_id: "c-1", workspace_public_id: "w-1" });
    expect(h.state().review.enabled).toBe(false);

    h.handlers["POST /conversations/memory_review/enable"] = () => { throw refused(422, "memory_root_missing", "memory review needs a writable root in this conversation"); };
    expect(await h.conversations.setMemoryReview(true)).toBe(false);
    expect(h.state().error).toContain("writable root");
    expect(h.state().reviewBusy).toBe(false);

    // Without the extension there is no status, and the menu offers no switch.
    const bare = harness();
    bare.conversations.start();
    await settle();
    expect(bare.state().review).toBeNull();
  });

  test("answers and approvals act on their run while naming the viewed conversation", async () => {
    const h = await opened();
    h.handlers["POST /runs/approve"] = () => ({ grant: { refused: "envelope_bound" } });
    const ask = { run_public_id: "run-a", task_key: "task-1", kind: "approval", tool_name: "web_fetch" };
    expect(await h.conversations.respond(ask, "/runs/approve", { always: true })).toBe(true);
    expect(h.posts("/runs/approve")[0]).toMatchObject({ body: { public_id: "run-a", workspace_public_id: "w-1", task_key: "task-1", always: true }, conversation: "c-1" });
    expect(h.state().notice).toContain("permission for this site could not be saved");
    h.handlers["POST /runs/approve"] = () => { throw refused(403, "not_authorized", "Read only"); };
    expect(await h.conversations.respond(ask, "/runs/approve")).toBe(false);
    expect(h.state().access).toBe("read-only");
  });
});
