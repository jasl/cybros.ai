import { test, expect, describe, jest, afterEach } from "bun:test";
import { observable } from "../webui/kernel/observable.js";
import { createConversations } from "../webui/features/conversation/controller.js";
import { createWorkspaces } from "../webui/shell/workspaces.js";
import { executionIdentity, refusalState, conversationControls, composerState } from "../webui/features/conversation/lifecycle.js";
import { emptyTurnText } from "../webui/features/conversation/turn.js";

// Microtasks only, so the same helper works under fake timers.
const settle = async () => { for (let index = 0; index < 30; index += 1) await Promise.resolve(); };
const refused = (status, code, message = code) => Object.assign(new Error(message), { status, code });

function harness({ detail = { public_id: "c-1", title: "First", workspace_public_id: "w-1", active_turn_public_id: null }, turns = [], followers = [], address = {}, routes = {} } = {}) {
  const requests = [];
  const documents = { detail, turns, followers };
  const handlers = {
    "POST /followers/attach": () => ({}),
    "GET /conversations/detail": () => ({ conversation: documents.detail }),
    "GET /conversations/turns": () => ({ turns: documents.turns, pagination: { before_position: null, has_older: false } }),
    "GET /conversations/artifacts": () => ({ published_artifacts: [] }),
    "GET /conversations/modes": () => ({ modes: { available: true, code_mode_available: true, code_mode: true, subagent: true } }),
    "GET /asks": () => ({ asks: [] }),
    "GET /inputs": () => ({ inputs: [] }),
    "GET /followers": () => ({ followers: documents.followers }),
    "GET /models": () => ({ models: [{ ref: "local/model" }] }),
    "GET /runners": () => ({ runners: [{ public_id: "runner-own", own: true }] }),
    "GET /conversations": () => ({ conversations: [], pagination: {} }),
    ...routes,
  };
  const call = async (path, options = {}) => {
    const method = options.method || "GET";
    const route = path.split("?")[0];
    requests.push({ method, route, path, body: options.body, conversation: options.conversation });
    const handler = handlers[`${method} ${route}`];
    if (!handler) throw new Error(`unexpected ${method} ${path}`);
    return handler({ query: new URLSearchParams(path.split("?")[1] || ""), body: options.body, signal: options.signal });
  };
  const streams = [];
  const follow = (id, { signal, onFrame }) => new Promise((resolve, reject) => {
    streams.push({ id, onFrame, end: resolve, fail: reject, signal });
    signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })), { once: true });
  });
  let location = { panel: null, conversation: null, workspace: null, plugin: null, ...address };
  const listeners = new Set();
  const pushes = [];
  const router = {
    read: () => ({ ...location }),
    push(changes) { location = { ...location, ...changes }; pushes.push(changes); },
    replace(changes) { location = { ...location, ...changes }; },
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    pop(next) { location = { ...location, ...next }; for (const listener of [...listeners]) listener({ ...location }); },
  };
  const setup = { state: observable({ document: { settings: { default_model: "local/model" } },
    status: { connected: true, model: { ready: true }, defaults: { runner_executor_public_id: "runner-own", conversation_modes: { available: true, code_mode_available: true, code_mode: true, subagent: true } } } }) };
  const session = new AbortController();
  const opened = [];
  const settings = [];
  const workspaces = createWorkspaces({ call, signal: session.signal, router, storage: null });
  const conversations = createConversations({ call, follow, artifactBytes: async () => new Blob(), signal: session.signal, toast: () => {},
    router, setup, workspaces, openDock: () => {}, openSettings: (section) => settings.push(section) });
  conversations.onOpen((id) => opened.push(id));
  const state = () => conversations.state.get();
  const count = (route) => requests.filter((request) => request.route === route).length;
  return { conversations, workspaces, requests, documents, handlers, streams, router, pushes, setup, session, opened, settings, state, count };
}

afterEach(() => jest.useRealTimers());

describe("conversation lifecycle rules", () => {
  test("regeneration and swipe select a new execution on the same turn; a reference never has one", () => {
    const conversation = { active_turn_public_id: "turn-1" };
    const turns = [{ public_id: "turn-1", active_variant: { public_id: "variant-1", run_public_id: "run-1" } }];
    const snapshot = { turn: "turn-1", run_public_id: "run-1" };
    expect(executionIdentity(conversation, turns, snapshot)).toBe("turn-1:run-1");
    turns[0].active_variant = { public_id: "variant-2", run_public_id: "run-2" };
    expect(executionIdentity(conversation, turns, snapshot)).toBe("turn-1:run-2");
    turns[0].active_variant = { public_id: "direct-variant" };
    expect(executionIdentity(conversation, turns, snapshot)).toBe("turn-1:direct-variant");
    expect(executionIdentity({}, [{ public_id: "turn-r", reference: true }], { turn: "turn-r" })).toBeNull();
  });

  test("a finished reply still offers Stop; loading, read-only and unavailable views cannot write", () => {
    expect(conversationControls({ active_turn_public_id: null }, "ready")).toEqual({ writable: true, send: true, stop: true });
    expect(conversationControls({ archived_at: "now" }, "ready")).toEqual({ writable: true, send: false, stop: true });
    for (const access of ["loading", refusalState({ status: 403 }), refusalState({ status: 404 })]) {
      expect(conversationControls({ active_turn_public_id: "turn-1" }, access)).toEqual({ writable: false, send: false, stop: false });
    }
    expect(refusalState({ status: 503 })).toBeNull();
    const bound = { ingresses: [{ extension: "rho.ingress_telegram", label: "Telegram · Chat 101" }] };
    expect(conversationControls(bound, "ready")).toEqual({ writable: false, send: false, stop: true });
  });

  test("the composer needs text, available models and, for a new conversation, a runner", () => {
    const base = { id: null, detail: null, access: "ready", inputs: [], draft: "hello", busy: false, modes: {}, models: [{ ref: "a/b" }], model: "a/b", runner: "r" };
    expect(composerState(base).send).toBe(true);
    expect(composerState({ ...base, model: "" }).send).toBe(true);
    expect(composerState({ ...base, model: "", models: [] }).send).toBe(false);
    expect(composerState({ ...base, runner: "" }).send).toBe(false);
    expect(composerState({ ...base, model: "gone/model" }).send).toBe(false);
    expect(composerState({ ...base, draft: "  " }).send).toBe(false);
    const open = { ...base, id: "c", detail: { active_turn_public_id: "t" }, runner: "" };
    expect(composerState(open)).toMatchObject({ send: true, running: true, stop: true, sendNow: true });
    expect(composerState({ ...open, draft: "" }).sendNow).toBe(false);
  });

  test("empty assistant history reflects the durable terminal state; other roles keep the placeholder", () => {
    for (const [status, text] of Object.entries({ pending: "Working…", running: "Working…", canceled: "Stopped",
      failed: "Response failed", timed_out: "Response timed out", completed: "No response" })) {
      expect(emptyTurnText({ role: "assistant", status })).toBe(text);
    }
    expect(emptyTurnText({ role: "user", status: "completed" })).toBe("Message");
  });
});

describe("conversation mode choices", () => {
  const modes = (code_mode = true, subagent = true) => ({ available: true, code_mode_available: true, code_mode, subagent });
  const defaults = (h, value) => h.setup.state.update((previous) => ({ ...previous,
    status: { ...previous.status, defaults: { ...previous.status?.defaults, conversation_modes: value } } }));

  test("global defaults seed each new draft once and never replace an open conversation's saved choices", async () => {
    const h = harness();
    defaults(h, modes(false, true));
    h.conversations.start();
    await settle();
    expect(h.state().modes).toEqual(modes(false, true));
    await h.conversations.setMode("subagent", false);
    defaults(h, modes(true, true));
    expect(h.state().modes).toEqual(modes(false, false));
    expect(h.requests.filter((request) => request.method === "PATCH")).toEqual([]);
    await h.conversations.startNew();
    expect(h.state().modes).toEqual(modes(true, true));
    h.handlers["GET /conversations/modes"] = () => ({ modes: modes(false, false) });
    await h.conversations.select("c-1");
    defaults(h, modes(true, true));
    await h.conversations.refresh();
    expect(h.state().modes).toEqual(modes(false, false));
    await h.conversations.startNew();
    expect(h.state().modes).toEqual(modes(true, true));
    h.conversations.dispose();
  });

  test("new draft modes stay unknown until defaults arrive and existing reads fail without showing made-up values", async () => {
    const h = harness();
    h.setup.state.update((previous) => ({ ...previous, status: null }));
    h.conversations.start();
    await settle();
    expect(h.state().modes).toBeNull();
    await h.conversations.setMode("code_mode", false);
    expect(h.state().modes).toBeNull();
    defaults(h, modes(false, true));
    expect(h.state().modes).toEqual(modes(false, true));
    h.handlers["GET /conversations/modes"] = () => { throw new TypeError("Modes unavailable"); };
    await h.conversations.select("c-1");
    expect(h.state()).toMatchObject({ modes: null, readError: "Modes unavailable" });
    expect(composerState({ ...h.state(), draft: "hello" }).send).toBe(false);
    h.conversations.dispose();
  });

  test("disabling the Code Mode plugin updates availability without replacing a draft's choices", async () => {
    const h = harness();
    defaults(h, modes(false, true));
    h.conversations.start();
    await settle();
    await h.conversations.setMode("subagent", false);
    defaults(h, { ...modes(true, true), code_mode_available: false });
    expect(h.state().modes).toEqual({ ...modes(false, false), code_mode_available: false });
    await h.conversations.setMode("code_mode", true);
    expect(h.state().modes.code_mode).toBe(false);
    h.conversations.dispose();
  });

  test("an existing toggle saves one boolean immediately and keeps the previous value until success", async () => {
    const h = harness();
    await h.conversations.select("c-1", { workspace: "w-1" });
    let accept;
    h.handlers["PATCH /conversations/modes"] = () => new Promise((resolve) => { accept = resolve; });
    const saving = h.conversations.setMode("code_mode", false);
    await settle();
    expect(h.state()).toMatchObject({ modes: modes(), modesBusy: true });
    await h.conversations.setMode("subagent", false);
    expect(h.requests.filter((request) => request.method === "PATCH")).toEqual([
      { method: "PATCH", route: "/conversations/modes", path: "/conversations/modes", conversation: "c-1",
        body: { public_id: "c-1", workspace_public_id: "w-1", code_mode: false } },
    ]);
    accept({ modes: modes(false, true) });
    await saving;
    expect(h.state()).toMatchObject({ modes: modes(false, true), modesBusy: false });
    h.handlers["PATCH /conversations/modes"] = () => { throw new TypeError("Save failed"); };
    await h.conversations.setMode("subagent", false);
    expect(h.state()).toMatchObject({ modes: modes(false, true), modesBusy: false, error: "Save failed" });
    h.conversations.dispose();
  });

  test("a read started before the toggle cannot replace its newly saved value", async () => {
    jest.useFakeTimers();
    const h = harness({ address: { conversation: "c-1" } });
    h.conversations.start();
    await settle();
    let finishRead;
    h.handlers["GET /conversations/modes"] = () => new Promise((resolve) => { finishRead = resolve; });
    jest.advanceTimersByTime(3000);
    await settle();
    h.handlers["PATCH /conversations/modes"] = () => ({ modes: modes(false, true) });
    await h.conversations.setMode("code_mode", false);
    finishRead({ modes: modes() });
    await settle();
    expect(h.state().modes).toEqual(modes(false, true));
    h.conversations.dispose();
  });

  test("a saved toggle arriving after navigation cannot change the next conversation", async () => {
    const h = harness();
    await h.conversations.select("c-1");
    let accept;
    h.handlers["PATCH /conversations/modes"] = () => new Promise((resolve) => { accept = resolve; });
    const saving = h.conversations.setMode("subagent", false);
    await h.conversations.select("c-2");
    accept({ modes: modes(true, false) });
    await saving;
    expect(h.state()).toMatchObject({ id: "c-2", modes: modes(), modesBusy: false });
    h.conversations.dispose();
  });

  test("read-only, ingress-owned and foreign conversations cannot change modes", async () => {
    for (const detail of [{ public_id: "c-1", archived_at: "yesterday" },
      { public_id: "c-1", bot_public_id: "bot-1" }, { public_id: "c-1", ingresses: [{}] }]) {
      const h = harness({ detail });
      await h.conversations.select("c-1");
      await h.conversations.setMode("subagent", false);
      expect(h.requests.some((request) => request.method === "PATCH")).toBe(false);
      h.conversations.dispose();
    }
    const h = harness({ routes: { "GET /conversations/modes": () => ({ modes: { ...modes(), available: false } }) } });
    await h.conversations.select("c-1");
    await h.conversations.setMode("code_mode", false);
    expect(h.requests.some((request) => request.method === "PATCH")).toBe(false);
    h.conversations.dispose();
  });
});

describe("the conversation controller", () => {
  test("published files load for the exact completed variant once and remain beside the answer across refreshes", async () => {
    const reply = { public_id: "t-1", position: 1, role: "assistant", status: "completed",
      active_variant: { public_id: "v-1", run_public_id: "r-1", content: "Ready." } };
    const files = [{ public_id: "up-1", filename: "report.pdf" }];
    const h = harness({ turns: [reply], routes: { "GET /conversations/artifacts": ({ query }) => {
      expect(Object.fromEntries(query)).toEqual({ public_id: "c-1", workspace_public_id: "w-1", turn: "t-1", variant: "v-1" });
      return { published_artifacts: files };
    } } });
    try {
      await h.conversations.select("c-1", { workspace: "w-1" });
      await settle();
      expect(h.state().turns[0].published_artifacts).toEqual(files);
      await h.conversations.refresh();
      await settle();
      expect(h.count("/conversations/artifacts")).toBe(1);
      expect(h.state().turns[0].published_artifacts).toEqual(files);
      h.documents.turns = [{ ...reply, active_variant: { public_id: "v-2", run_public_id: "r-2", content: "Revised." } }];
      h.handlers["GET /conversations/artifacts"] = () => ({ published_artifacts: [] });
      await h.conversations.refresh();
      await settle();
      expect(h.count("/conversations/artifacts")).toBe(2);
      expect(h.state().turns[0].published_artifacts).toEqual([]);
    } finally { h.conversations.dispose(); }
  });

  test("a pending publication read cannot put an old variant or conversation's files on the current answer", async () => {
    for (const switchConversation of [false, true]) {
      let deliver, readSignal;
      const reply = { public_id: "t-1", position: 1, role: "assistant", status: "completed",
        active_variant: { public_id: "v-1", run_public_id: "r-1", content: "Ready." } };
      const h = harness({ turns: [reply], routes: { "GET /conversations/artifacts": ({ query, signal }) => {
        if (query.get("variant") === "v-1") {
          readSignal = signal;
          return new Promise((resolve) => { deliver = resolve; });
        }
        return { published_artifacts: [{ public_id: "up-new", filename: "current.pdf" }] };
      } } });
      try {
        await h.conversations.select("c-1", { workspace: "w-1" });
        await settle();
        expect(h.count("/conversations/artifacts")).toBe(1);
        h.documents.turns = [{ ...reply, active_variant: { public_id: "v-2", run_public_id: "r-2", content: "Revised." } }];
        if (switchConversation) await h.conversations.select("c-2", { workspace: "w-1" });
        else await h.conversations.refresh();
        if (switchConversation) expect(readSignal.aborted).toBe(true);
        deliver({ published_artifacts: [{ public_id: "up-old", filename: "stale.pdf" }] });
        await settle();
        expect(h.state().turns[0].published_artifacts).toEqual([{ public_id: "up-new", filename: "current.pdf" }]);
      } finally { h.conversations.dispose(); }
    }
  });

  test("publication reads skip running turns and references, then collect a completed callback without its own run", async () => {
    const reply = { public_id: "t-1", position: 1, role: "assistant", status: "running",
      active_variant: { public_id: "v-1", run_public_id: "r-1", content: "Working." } };
    const reference = { ...reply, public_id: "t-reference", position: 0, reference: true, status: "completed" };
    const h = harness({ turns: [reference, reply] });
    try {
      await h.conversations.select("c-1", { workspace: "w-1" });
      await settle();
      expect(h.count("/conversations/artifacts")).toBe(0);
      h.documents.turns = [reference, { ...reply, status: "completed", active_variant: { public_id: "v-1", content: "Worker finished." },
        callback_sources: [{ result: { variant_public_id: "worker-variant" } }] }];
      await h.conversations.refresh();
      await settle();
      expect(h.count("/conversations/artifacts")).toBe(1);
      expect(h.state().turns[1].published_artifacts).toEqual([]);
    } finally { h.conversations.dispose(); }
  });

  test("one failed publication read does not hide other answers' files and retries on refresh", async () => {
    const turns = [1, 2].map((position) => ({ public_id: `t-${position}`, position, role: "assistant", status: "completed",
      active_variant: { public_id: `v-${position}`, run_public_id: `r-${position}`, content: "Ready." } }));
    let unavailable = true;
    const h = harness({ turns, routes: { "GET /conversations/artifacts": ({ query }) => {
      if (query.get("turn") === "t-2" && unavailable) throw refused(503, "unavailable", "Published files are temporarily unavailable.");
      return { published_artifacts: [{ public_id: `up-${query.get("turn")}`, filename: "report.pdf" }] };
    } } });
    try {
      await h.conversations.select("c-1", { workspace: "w-1" });
      await settle();
      expect(h.state().error).toBe("Published files are temporarily unavailable.");
      expect(h.state().turns[0].published_artifacts).toEqual([{ public_id: "up-t-1", filename: "report.pdf" }]);
      unavailable = false;
      await h.conversations.refresh();
      await settle();
      expect(h.count("/conversations/artifacts")).toBe(3);
      expect(h.state().turns[1].published_artifacts).toEqual([{ public_id: "up-t-2", filename: "report.pdf" }]);
    } finally { h.conversations.dispose(); }
  });

  test("opening a conversation attaches, reads its documents, follows it and publishes a frozen context", async () => {
    const h = harness();
    await h.conversations.select("c-1", { workspace: "w-1" });
    expect(h.requests.map((request) => request.route)).toEqual(["/followers/attach", "/conversations/detail", "/conversations/turns",
      "/conversations/modes", "/asks", "/inputs", "/followers", "/conversations/memory_review"]);
    expect(h.requests[0].body).toEqual({ public_id: "c-1", workspace_public_id: "w-1", host_type: "conversation" });
    expect(new URLSearchParams(h.requests[1].path.split("?")[1]).get("workspace_public_id")).toBe("w-1");
    expect(h.streams.map((stream) => stream.id)).toEqual(["c-1"]);
    const context = h.conversations.selection.get();
    expect(context).toMatchObject({ id: "c-1", workspace: "w-1", access: "ready", writable: true, defaults: { approval_mode: "ask" } });
    expect(context.detail.title).toBe("First");
    expect(Object.isFrozen(context)).toBe(true);
    expect(h.pushes).toEqual([{ panel: null, plugin: null, conversation: "c-1", workspace: "w-1" }]);
    expect(h.opened).toEqual(["c-1"]);
  });

  test("a poll that reads an unchanged document keeps the published context", async () => {
    jest.useFakeTimers();
    const h = harness({ address: { conversation: "c-1", workspace: "w-1" } });
    h.conversations.start();
    await settle();
    const context = h.conversations.selection.get();
    jest.advanceTimersByTime(3000);
    await settle();
    expect(h.count("/conversations/detail")).toBe(2);
    expect(h.conversations.selection.get()).toBe(context);
    h.documents.detail = { ...h.documents.detail, title: "Renamed elsewhere" };
    jest.advanceTimersByTime(3000);
    await settle();
    expect(h.conversations.selection.get()).not.toBe(context);
    expect(h.conversations.selection.get().detail.title).toBe("Renamed elsewhere");
    h.conversations.dispose();
  });

  test("stream frames build the live response and durable frames read the conversation again", async () => {
    const running = { public_id: "c-1", workspace_public_id: "w-1", active_turn_public_id: "t-2" };
    const turns = [{ public_id: "t-2", position: 2, role: "assistant", status: "running", active_variant: { public_id: "v-2", run_public_id: "r-2" } }];
    const h = harness({ detail: running, turns, followers: [{ public_id: "c-1", turn: "t-2", run_public_id: "r-2" }] });
    await h.conversations.select("c-1");
    const [live] = h.streams;
    live.onFrame("snapshot", { turn: "t-2", run_public_id: "r-2", text: "Hel", reasoning: "think" });
    expect(h.state()).toMatchObject({ live: "Hel", reasoning: "think" });
    live.onFrame("text_delta", { text: "lo" });
    live.onFrame("reasoning_delta", { text: "ing" });
    expect(h.state()).toMatchObject({ live: "Hello", reasoning: "thinking" });
    live.onFrame("text_reset", { text: "Hi" });
    expect(h.state().live).toBe("Hi");
    live.onFrame("retry", {});
    expect(h.state()).toMatchObject({ live: "", reasoning: "" });
    await settle();
    const reads = h.count("/conversations/detail");
    live.onFrame("turn_status", {});
    await settle();
    expect(h.count("/conversations/detail")).toBe(reads + 1);
  });

  test("a stream for another execution than the active one is closed instead of shown", async () => {
    const running = { public_id: "c-1", active_turn_public_id: "t-2" };
    const turns = [{ public_id: "t-2", position: 2, role: "assistant", status: "running", active_variant: { public_id: "v-3", run_public_id: "r-3" } }];
    const h = harness({ detail: running, turns });
    await h.conversations.select("c-1");
    h.streams[0].onFrame("snapshot", { turn: "t-2", run_public_id: "r-2", text: "old run" });
    expect(h.streams[0].signal.aborted).toBe(true);
    expect(h.state().live).toBe("");
  });

  test("a running turn's stream is followed again at once; a dropped stream whose reread fails retries after two seconds", async () => {
    jest.useFakeTimers();
    const running = { public_id: "c-1", active_turn_public_id: "t-2" };
    const turns = [{ public_id: "t-2", position: 2, role: "assistant", status: "running", active_variant: { public_id: "v-2", run_public_id: "r-2" } }];
    const h = harness({ detail: running, turns });
    h.conversations.select("c-1");
    await settle();
    h.streams[0].end();
    await settle();
    expect(h.streams).toHaveLength(2);
    jest.advanceTimersByTime(2000);
    await settle();
    expect(h.state().reconnecting).toBe(false);
    const read = h.handlers["GET /conversations/detail"];
    h.handlers["GET /conversations/detail"] = () => { h.handlers["GET /conversations/detail"] = read; throw refused(503, "unavailable_upstream", "Busy"); };
    h.streams[1].end();
    await settle();
    expect(h.state().reconnecting).toBe(true);
    expect(h.streams).toHaveLength(2);
    jest.advanceTimersByTime(1999);
    await settle();
    expect(h.streams).toHaveLength(2);
    jest.advanceTimersByTime(1);
    await settle();
    expect(h.streams).toHaveLength(3);
    expect(h.state().reconnecting).toBe(false);
    // An execution that closed is settled: its end neither re-follows nor retries.
    h.streams[2].onFrame("snapshot", { turn: "t-2", run_public_id: "r-2" });
    h.streams[2].onFrame("closed", {});
    await settle();
    h.streams[2].end();
    await settle();
    jest.advanceTimersByTime(5000);
    await settle();
    expect(h.streams).toHaveLength(3);
    expect(h.state().reconnecting).toBe(false);
  });

  test("a refused read makes the view read-only or unavailable, stops automatic reads, and Refresh checks again", async () => {
    jest.useFakeTimers();
    for (const [status, access] of [[403, "read-only"], [404, "unavailable"]]) {
      const h = harness();
      h.handlers["GET /conversations/detail"] = () => { throw refused(status, "not_authorized", "No access"); };
      h.conversations.start();
      await h.conversations.select("c-1");
      await settle();
      expect(h.state()).toMatchObject({ access, asks: [], live: "", readError: "No access" });
      expect(h.conversations.selection.get().writable).toBe(false);
      const reads = h.count("/conversations/detail");
      jest.advanceTimersByTime(9000);
      await settle();
      expect(h.count("/conversations/detail")).toBe(reads);
      h.handlers["GET /conversations/detail"] = () => ({ conversation: h.documents.detail });
      await h.conversations.refresh();
      await settle();
      expect(h.state().access).toBe("ready");
      h.conversations.dispose();
    }
  });

  test("automatic reads clear their recovered error without clearing failed actions or an unsent draft", async () => {
    jest.useFakeTimers();
    const h = harness({ address: { conversation: "c-1", workspace: "w-1" } });
    h.conversations.start();
    await settle();
    h.conversations.setDraft("Keep this unsent message");
    h.handlers["PATCH /conversations/modes"] = () => { throw new Error("Mode change failed"); };
    await h.conversations.setMode("code_mode", false);
    const read = h.handlers["GET /conversations/detail"];
    h.handlers["GET /conversations/detail"] = () => { throw new TypeError("Connection refused"); };
    jest.advanceTimersByTime(3000);
    await settle();
    expect(h.state()).toMatchObject({ readError: "Connection refused", error: "Mode change failed" });
    h.handlers["GET /conversations/detail"] = read;
    h.handlers["GET /inputs"] = () => { throw new TypeError("Inputs unavailable"); };
    jest.advanceTimersByTime(3000);
    await settle();
    expect(h.state()).toMatchObject({ readError: "Inputs unavailable", error: "Mode change failed" });
    h.handlers["GET /inputs"] = () => ({ inputs: [] });
    jest.advanceTimersByTime(3000);
    await settle();
    expect(h.state()).toMatchObject({ readError: "", error: "Mode change failed", draft: "Keep this unsent message", access: "ready" });
    h.conversations.dispose();
  });

  test("a run that is not followed leaves the view detached until Refresh attaches again", async () => {
    const h = harness();
    await h.conversations.select("c-1");
    h.streams[0].fail(refused(409, "run_not_followed"));
    await settle();
    expect(h.state().detached).toBe(true);
    const attaches = h.count("/followers/attach");
    await h.conversations.refresh();
    await settle();
    expect(h.count("/followers/attach")).toBe(attaches + 1);
    expect(h.state().detached).toBe(false);
    expect(h.streams).toHaveLength(2);
  });

  test("start opens the addressed conversation, follows popstate without pushing, and polls every three seconds", async () => {
    jest.useFakeTimers();
    const h = harness({ address: { conversation: "c-1", workspace: "w-1" } });
    h.conversations.start();
    await settle();
    expect(h.state().id).toBe("c-1");
    expect(h.pushes).toEqual([]);
    expect(h.count("/models")).toBe(1);
    const reads = h.count("/conversations/detail");
    jest.advanceTimersByTime(3000);
    await settle();
    expect(h.count("/conversations/detail")).toBe(reads + 1);
    h.router.pop({ conversation: "c-2", workspace: "w-2" });
    await settle();
    expect(h.state()).toMatchObject({ id: "c-2", workspace: "w-1" });
    expect(h.pushes).toEqual([]);
    expect(h.opened).toEqual([]);
    h.router.pop({ panel: "plugins" });
    expect(h.state().id).toBe("c-2");
    h.conversations.dispose();
  });

  test("saved defaults do not turn Automatic into a model pin or replace a deliberate choice", async () => {
    const h = harness();
    h.setup.state.set({ document: { settings: { default_model: "local/model" } }, status: { connected: true, model: { ready: false } } });
    h.conversations.start();
    await settle();
    expect(h.settings).toEqual([]);
    expect(h.state()).toMatchObject({ model: "", modelEdited: false, defaultModel: "local/model" });
    expect(h.conversations.selection.get().defaults.model).toBe("local/model");
    h.setup.state.set({ document: { settings: { default_model: "local/other" } }, status: { connected: true, model: { ready: false } } });
    expect(h.state()).toMatchObject({ model: "", modelEdited: false, defaultModel: "local/other" });
    h.conversations.setModel("chosen/model");
    h.setup.state.set({ document: { settings: { default_model: "local/third" } }, status: { connected: true, model: { ready: true } } });
    expect(h.state().model).toBe("chosen/model");
    expect(h.settings).toEqual([]);
  });

  test("the picker restores captured intent while the last response route follows fallback", async () => {
    const variant = { public_id: "v-1", model: { provider_id: "backup", model_ref: "same-version" },
      model_selection: { source: "explicit", model: "original/same-version", constraint: "model", alternatives: [] } };
    const turn = { public_id: "t-1", position: 1, role: "assistant", active_variant: variant };
    const h = harness({ turns: [turn] });
    await h.conversations.select("c-1");
    expect(h.state()).toMatchObject({ model: "original/same-version", modelEdited: false, actualModel: "backup/same-version" });
    h.conversations.setModel("");
    h.documents.turns = [{ ...turn, active_variant: { ...variant, model: { provider_id: "third", model_ref: "same-version" } } }];
    await h.conversations.refresh();
    expect(h.state()).toMatchObject({ model: "", modelEdited: true, actualModel: "third/same-version" });
    await h.conversations.select("c-1");
    expect(h.state()).toMatchObject({ model: "original/same-version", modelEdited: false, actualModel: "third/same-version" });
    h.conversations.startNew();
    expect(h.state()).toMatchObject({ model: "", modelEdited: false, actualModel: "" });
    h.conversations.dispose();
  });

  test("automatic and absent intent never become explicit from the last response route", async () => {
    for (const source of ["default", "inherited", null]) {
      const h = harness({ turns: [{ public_id: "t-1", position: 1, role: "assistant", active_variant: {
        model: { provider_id: "backup", model_ref: "model" },
        ...(source ? { model_selection: { source, model: "initial/model", constraint: "any", alternatives: [] } } : {}),
      } }] });
      await h.conversations.select("c-1");
      expect(h.state()).toMatchObject({ model: "", modelEdited: false, actualModel: "backup/model" });
      h.conversations.dispose();
    }
  });

  test("leaving a conversation aborts its stream and later answers change nothing", async () => {
    const h = harness();
    await h.conversations.select("c-1");
    let release;
    h.handlers["GET /conversations/detail"] = () => new Promise((resolve) => { release = () => resolve({ conversation: { public_id: "c-1", title: "Late" } }); });
    const pending = h.conversations.refresh();
    await settle();
    h.conversations.startNew();
    expect(h.streams[0].signal.aborted).toBe(true);
    release();
    await pending;
    await settle();
    expect(h.state()).toMatchObject({ id: null, detail: null });
  });
});
