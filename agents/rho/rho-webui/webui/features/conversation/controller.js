import { observable } from "../../kernel/observable.js";
import { t } from "../../kernel/i18n.js";
import { isTerminal, modelRef } from "../../kernel/format.js";
import { Submissions } from "../../kernel/submissions.js";
import { createArtifactOpener } from "../../kernel/artifacts.js";
import { createList } from "./list.js";
import { createActions } from "./actions.js";
import { createChoices } from "./choices.js";
import { executionIdentity, refusalState, conversationTarget, conversationControls, waitingInput } from "./lifecycle.js";

const POLL_INTERVAL = 3000;
const RECONNECT_DELAY = 2000;
const TURN_PAGE = 40;
const ROUND_PAGE = 20;
const DURABLE_FRAMES = ["turn", "round_result", "task_status", "turn_status"];
const query = (path, values) => `${path}?${new URLSearchParams(values)}`;
// A reread that returns the same document keeps the previous object, so views
// comparing by identity skip work and the selection does not churn per poll.
const keep = (previous, next) => (JSON.stringify(previous) === JSON.stringify(next) ? previous : next);
const publicationKey = (turn) => JSON.stringify([turn.public_id, turn.active_variant?.public_id]);
const hasPublication = (turn) => !turn.reference && turn.kind !== "compaction_summary" && isTerminal(turn.status)
  && turn.active_variant?.public_id && (turn.callback_sources?.length || turn.active_variant.run_public_id && !turn.active_variant.details_pruned_at);

// The part of the state that belongs to the shown conversation; it starts
// over whenever another conversation (or a new one) is shown. `agent` is
// the bot a NEW conversation will be answered by — null for rho itself;
// an open conversation's answerer is its detail's.
function shown(id, workspace, agent = null) {
  return { id, workspace, agent: id ? null : agent, access: id ? "loading" : "ready", detail: null, turns: [], before: null, older: false,
    model: "", modelEdited: false, actualModel: "", modes: null, modesBusy: false,
    asks: [], inputs: [], snapshot: null, live: "", reasoning: "", reconnecting: false, detached: false,
    error: "", readError: "", notice: "", busy: false, stopping: false, review: null, reviewBusy: false };
}

// The conversation the page shows, without DOM: selection, attach, durable
// reads, the live stream and its reconnect, the poll while a conversation is
// open, drafts and the composer's choices. Views subscribe to `state`; slot
// contributions receive the immutable `selection` context.
export function createConversations({ call, follow, artifactBytes, signal, toast, router, setup, workspaces, openDock, openSettings }) {
  const drafts = new Map();
  const submissions = new Submissions();
  const list = createList({ call, signal, workspace: workspaces.current, ready: workspaces.ready });
  const openers = new Set();
  const stops = [];
  let view = new AbortController();
  let stream = null;
  let reconnectTimer = null;
  let pollTimer = null;
  let refreshing = false;
  let settled = null;
  let started = false;
  let published = new Map();
  let artifactRead = null;

  const state = observable({ ...shown(null, null), draft: "", focus: 0,
    models: null, runners: null, choicesError: null, defaultModel: "", approval: "ask", delivery: "steer",
    runner: "", runnerEdited: false });
  const get = () => state.get();
  // Before a conversation exists, its intended workspace and answerer own
  // the draft. Switching either must not carry a message to another bot.
  const draftScope = (value = get()) => value.id || JSON.stringify(["new", value.workspace, value.agent]);
  const patch = (changes) => state.update((value) => ({ ...value, ...changes }));
  const current = (v) => v === view && !v.signal.aborted && !signal.aborted;
  const target = (id = get().id) => conversationTarget(id, get().workspace);
  const blocked = () => ["read-only", "unavailable"].includes(get().access);
  const running = () => !!get().detail?.active_turn_public_id;

  const open = (id, { workspace = null } = {}) => select(id, { workspace });
  const refreshNow = () => refresh();
  const scheduleModel = (value) => value.model || value.actualModel || value.defaultModel;
  const context = (value) => Object.freeze({
    id: value.id, workspace: value.workspace, detail: value.detail, access: value.access,
    writable: conversationControls(value.detail, value.access).writable,
    defaults: Object.freeze({ model: scheduleModel(value), approval_mode: value.approval }), open, refresh: refreshNow,
  });
  const selection = observable(context(get()));
  stops.push(state.subscribe((value) => {
    const previous = selection.get();
    if (previous.id === value.id && previous.workspace === value.workspace && previous.detail === value.detail
      && previous.access === value.access && previous.defaults.model === scheduleModel(value)
      && previous.defaults.approval_mode === value.approval) return;
    selection.set(context(value));
  }));

  function stopViewing() {
    view.abort();
    stream?.abort(); stream = null;
    clearTimeout(reconnectTimer); reconnectTimer = null;
  }

  // A new conversation starts in the page's current workspace, answered by
  // rho or the bot named; an opened one belongs to its own workspace, and
  // the page follows it there.
  async function select(id, { workspace = null, navigate = true, agent = null } = {}) {
    if (signal.aborted) return;
    id ||= null;
    const listed = list.state.get().rows.find((row) => row.public_id === id);
    workspace ||= (id && id === get().id ? get().workspace : listed?.workspace_public_id) || workspaces.current();
    if (id && workspace) workspaces.adopt(workspace);
    stopViewing();
    const v = new AbortController();
    view = v; refreshing = false; settled = null;
    published = new Map();
    const next = shown(id, workspace, agent);
    patch({ ...next, draft: drafts.get(draftScope(next)) || "",
      modes: id ? null : setup.state.get().status?.defaults?.conversation_modes ?? null,
      focus: id ? get().focus : get().focus + 1 });
    if (navigate) {
      router.push({ panel: null, plugin: null, conversation: id, workspace: id ? workspace : workspaces.addressed() });
      for (const listener of [...openers]) listener(id);
    }
    if (!id) return;
    try {
      await call("/followers/attach", { method: "POST", body: { ...target(id), host_type: "conversation" }, signal: v.signal });
    } catch (error) { conversationError(error, v, { reading: true }); return; }
    if (!current(v)) return;
    try { await refreshConversation(v); } catch { return; }
    if (!current(v)) return;
    beginFollow(v);
    readReview(v);
  }

  // The conversation's memory review status, read once on open and again
  // after each toggle. Absent (the extension is off, or the read failed),
  // the menu offers no switch.
  async function readReview(v) {
    const { id } = get();
    if (!current(v) || !id || blocked()) return;
    try {
      const { memory_review } = await call(query("/conversations/memory_review", target(id)), { signal: v.signal, conversation: id });
      if (current(v)) patch({ review: memory_review });
    } catch {
      if (current(v)) patch({ review: null });
    }
  }

  async function readTurns(v, before) {
    const values = { ...target(), limit: TURN_PAGE };
    if (before !== undefined && before !== null) values.before_position = before; else values.latest = "1";
    const page = await call(query("/conversations/turns", values), { signal: v.signal });
    return { rows: page.turns, before: page.pagination?.before_position, older: !!page.pagination?.has_older };
  }

  // Older pages prepend; a latest page refreshes the tail without losing the
  // paging cursor that earlier "load more" reads established.
  function mergeTurns(page, older = false) {
    const { turns, before, older: hasOlder } = get();
    const rows = new Map(turns.map((turn) => [turn.public_id, turn]));
    for (const turn of page.rows) {
      const files = published.get(publicationKey(turn));
      rows.set(turn.public_id, keep(rows.get(turn.public_id), files ? { ...turn, published_artifacts: files } : turn));
    }
    const merged = [...rows.values()].sort((left, right) => left.position - right.position);
    const same = merged.length === turns.length && merged.every((turn, index) => turn === turns[index]);
    const first = turns[0]?.position;
    const paging = older || first === undefined || page.rows[0]?.position <= first
      ? { before: page.before, older: page.older } : { before, older: hasOlder };
    return { turns: same ? turns : merged, ...paging };
  }

  // Published uploads belong to an exact answer, including its fixed child
  // callbacks. Read completed answers once, newest first and one at a time;
  // ordinary status polls neither scan tasks again nor delay the transcript.
  async function readArtifacts(v) {
    if (!current(v) || artifactRead === v) return;
    artifactRead = v;
    const attempted = new Set();
    try {
      while (current(v) && !blocked()) {
        const turn = [...get().turns].reverse().find((row) => hasPublication(row) && !published.has(publicationKey(row)) && !attempted.has(publicationKey(row)));
        if (!turn) return;
        const key = publicationKey(turn);
        attempted.add(key);
        try {
          const { published_artifacts: files } = await call(query("/conversations/artifacts", {
            ...target(), turn: turn.public_id, variant: turn.active_variant.public_id,
          }), { signal: v.signal });
          if (!current(v)) return;
          published.set(key, files);
          if (get().turns.some((row) => publicationKey(row) === key)) {
            patch({ turns: get().turns.map((row) => publicationKey(row) === key ? { ...row, published_artifacts: files } : row) });
          }
        } catch (error) { if (current(v) && get().turns.some((row) => publicationKey(row) === key)) errorMessage(error); }
      }
    } finally { if (artifactRead === v) artifactRead = null; }
  }

  // Durable state is authoritative; the stream only fills the gap until the
  // next read. Errors are reported here and rethrown for control flow.
  async function refreshConversation(v = view) {
    const { id } = get();
    if (!current(v) || !id || refreshing || blocked()) return;
    refreshing = true;
    const previousModes = get().modes;
    try {
      const [detail, page, policy] = await Promise.all([
        call(query("/conversations/detail", target(id)), { signal: v.signal }), readTurns(v),
        call(query("/conversations/modes", target(id)), { signal: v.signal }),
      ]);
      if (!current(v) || blocked()) return;
      // A poll that began before a successful toggle must not restore the
      // earlier value; a pending write still owns its visible saved value.
      const modes = get().modesBusy || get().modes !== previousModes ? get().modes : policy.modes;
      const workspace = detail.conversation.workspace_public_id || get().workspace;
      const address = router.read();
      if (workspace && address.conversation === id && address.workspace !== workspace) router.replace({ workspace });
      if (workspace) workspaces.adopt(workspace);
      const merged = mergeTurns(page);
      const variant = [...merged.turns].reverse().find((turn) => turn.active_variant?.model)?.active_variant;
      const actualModel = variant ? modelRef(variant.model) : "";
      // The route that answered can differ after fallback. Only the captured
      // intent restores a pin; refresh must preserve an unsent picker edit.
      const model = get().modelEdited ? get().model : variant?.model_selection?.source === "explicit" ? variant.model_selection.model : "";
      patch({ detail: keep(get().detail, detail.conversation), workspace, access: "ready", modes, ...merged, model, actualModel });
      const [asks, inputs, followers] = await Promise.all([
        call("/asks", { signal: v.signal }),
        call(query("/inputs", { ...target(id), host_type: "conversation" }), { signal: v.signal }),
        call("/followers", { signal: v.signal }),
      ]);
      if (!current(v) || blocked()) return;
      const snapshot = followers.followers.find((follower) => follower.public_id === id) || null;
      const previous = get().snapshot;
      let { live, reasoning } = get();
      if (snapshot && previous && (snapshot.turn !== previous.turn || snapshot.run_public_id !== previous.run_public_id)) { live = ""; reasoning = ""; }
      if (stream?.identity && executionIdentity(get().detail, get().turns, snapshot) !== stream.identity) {
        stream.abort(); stream = null; live = ""; reasoning = "";
      }
      const runs = new Set(get().turns.map((turn) => turn.active_variant?.run_public_id).filter(Boolean));
      if (snapshot?.run_public_id) runs.add(snapshot.run_public_id);
      patch({ snapshot: keep(previous, snapshot), live, reasoning,
        asks: keep(get().asks, asks.asks.filter((ask) => runs.has(ask.run_public_id))),
        inputs: keep(get().inputs, inputs.inputs.filter(waitingInput)),
        stopping: running() && get().stopping, reconnecting: false, readError: "" });
      list.replace(get().detail);
      readArtifacts(v);
      if (running() && !stream && executionIdentity(get().detail, get().turns, get().snapshot) !== settled) beginFollow(v);
    } catch (error) {
      conversationError(error, v, { reading: true });
      throw error;
    } finally {
      if (current(v)) refreshing = false;
    }
  }

  // SSE through fetch; a frame from another execution than the active one
  // closes this stream, and a stream that ends without `closed` reconnects.
  function beginFollow(v) {
    const { id, access } = get();
    if (!current(v) || stream || !id || access !== "ready" || get().detached) return;
    clearTimeout(reconnectTimer); reconnectTimer = null;
    const own = new AbortController();
    stream = own;
    let closed = false;
    let identity = null;
    const abort = () => own.abort();
    v.signal.addEventListener("abort", abort, { once: true });
    const reread = () => refreshConversation(v).catch(() => {});
    follow(id, { signal: own.signal, onFrame: (type, payload) => {
      if (!current(v) || stream !== own) return;
      if (type === "snapshot") {
        identity = payload.run_public_id ? `${payload.turn}:${payload.run_public_id}` : executionIdentity(get().detail, get().turns, payload);
        own.identity = identity;
        const active = executionIdentity(get().detail, get().turns, null);
        if (active && identity && active !== identity) { own.abort(); stream = null; return; }
        patch({ snapshot: payload, live: payload.text || "", reasoning: payload.reasoning || "", reconnecting: false });
        reread();
      } else if (type === "text_delta") patch({ live: get().live + (payload.text || "") });
      else if (type === "text_reset") patch({ live: payload.text || "" });
      else if (type === "reasoning_delta") patch({ reasoning: get().reasoning + (payload.text || "") });
      else if (type === "stream_reset" || type === "retry") patch({ live: "", reasoning: "" });
      else if (DURABLE_FRAMES.includes(type)) reread();
      else if (type === "closed") { closed = true; settled = identity; }
    } }).then(async () => {
      if (!current(v) || stream !== own) return;
      stream = null;
      await refreshConversation(v);
      if (!closed && current(v)) reconnect(v);
    }).catch((error) => {
      if (!current(v) || own.signal.aborted) return;
      if (stream === own) stream = null;
      if (error.code === "run_not_followed") patch({ detached: true });
      else if (refusalState(error)) conversationError(error, v);
      else if (error.status !== 401) reconnect(v);
    }).finally(() => v.signal.removeEventListener("abort", abort));
  }

  function reconnect(v) {
    if (!current(v) || reconnectTimer || get().access !== "ready") return;
    patch({ reconnecting: true });
    reconnectTimer = setTimeout(async () => {
      reconnectTimer = null;
      if (!current(v)) return;
      try {
        await refreshConversation(v);
        if (current(v) && running()) beginFollow(v);
      } catch (error) {
        if (current(v) && error.status !== 401 && !refusalState(error)) reconnect(v);
      }
    }, RECONNECT_DELAY);
  }

  // Refresh after a refusal or detach: re-attach when no stream is open and
  // read again, which is how a person checks access after it was restored.
  async function refresh() {
    const v = view;
    patch({ error: "" });
    choices.refresh();
    if (!get().id || !current(v)) return;
    patch({ access: "loading" });
    if (!stream) {
      try {
        await call("/followers/attach", { method: "POST", body: { ...target(), host_type: "conversation" }, signal: v.signal });
      } catch (error) { conversationError(error, v, { reading: true }); return; }
      if (current(v)) patch({ detached: false });
    }
    try { await refreshConversation(v); } catch { return; }
    if (current(v)) beginFollow(v);
  }

  function conversationError(error, v, { reading = false } = {}) {
    if (!current(v) || error.name === "AbortError" || error.status === 401) return;
    if (error.code === "ingress_bound") {
      patch({ access: "loading" });
      refreshConversation(v).catch(() => {});
    }
    const access = refusalState(error);
    if (access) {
      stream?.abort(); stream = null;
      clearTimeout(reconnectTimer); reconnectTimer = null;
      patch({ access, snapshot: null, asks: [], inputs: [], live: "", reasoning: "", reconnecting: false });
    }
    // Background reads recover independently of a failed send or action.
    patch(reading ? { readError: errorText(error) } : { error: errorText(error) });
  }

  const errorText = (error) => error.code === "member_plane_unavailable" ? t("conversation.member_plane_unavailable")
    : error.message || t("conversation.request_failed");

  // A 401 has already signed the page out through the shell's call.
  function errorMessage(error) {
    if (error.name === "AbortError" || error.status === 401) return;
    patch({ error: errorText(error) });
  }

  async function loadOlder() {
    const v = view;
    try {
      const page = await readTurns(v, get().before);
      if (current(v)) { patch(mergeTurns(page, true)); readArtifacts(v); }
    } catch (error) { if (current(v)) errorMessage(error); }
  }

  function start() {
    if (started || signal.aborted) return;
    started = true;
    const address = router.read();
    select(address.conversation, { navigate: false, workspace: address.workspace });
    // A panel's address says nothing about the conversation, which stays
    // open behind the panel for the way back.
    stops.push(router.subscribe((next) => {
      if (next.panel) return;
      if ((next.conversation || null) !== get().id) select(next.conversation, { navigate: false, workspace: next.workspace });
    }));
    stops.push(setup.state.subscribe(choices.observe, { immediate: true }));
    // Another workspace lists other conversations; the hero moves there too.
    let workspace = workspaces.current();
    let defaultWorkspace = workspaces.state.get().selection;
    stops.push(workspaces.state.subscribe((value) => {
      if (!defaultWorkspace && value.selection) {
        // Early drafts name the unknown default, even when another workspace
        // or conversation is open by the time the first read resolves it.
        defaultWorkspace = value.selection;
        for (const [scope, text] of drafts) {
          if (!scope.startsWith('["new",null,')) continue;
          const [, , agent] = JSON.parse(scope);
          const resolvedScope = draftScope({ id: null, workspace: defaultWorkspace, agent });
          if (!drafts.has(resolvedScope)) drafts.set(resolvedScope, text);
          drafts.delete(scope);
        }
      }
      if (value.current === workspace) return;
      workspace = value.current;
      list.refresh();
      if (!get().id) {
        if (get().workspace === null && value.current === defaultWorkspace) {
          patch({ workspace: value.current });
          setDraft(drafts.get(draftScope()) || "");
        } else select(null, { workspace: value.current, agent: get().agent, navigate: false });
      }
    }));
    pollTimer = setInterval(() => { if (get().id) refreshConversation(view).catch(() => {}); }, POLL_INTERVAL);
  }

  function dispose() {
    stopViewing();
    clearInterval(pollTimer);
    for (const stop of stops.splice(0)) stop();
    openers.clear();
  }

  function setDraft(text) {
    drafts.set(draftScope(), text);
    if (get().draft !== text) patch({ draft: text });
  }

  const choices = createChoices({ call, signal, get, patch, list, errorMessage });
  const actions = createActions({ call, get, patch, setDraft, draftScope, workspaces, current, view: () => view, target, drafts, submissions,
    list, toast, select, refreshConversation, beginFollow, unsettle: () => { settled = null; }, conversationError, errorMessage });

  return {
    selection, state, list: list.state,
    select, startNew: ({ agent = null } = {}) => select(null, { agent }), refreshList: list.refresh, setArchived: list.setArchived,
    rename: actions.rename, archive: actions.archive, restore: actions.restore, start, dispose,
    refresh, loadOlder, setDraft,
    send: actions.send, sendNow: actions.sendNow, promote: actions.promote, stop: actions.stop,
    respond: actions.respond, execute: actions.execute, setMemoryReview: actions.setMemoryReview,
    setModel: (ref) => patch({ model: ref, modelEdited: true }),
    setApproval: (mode) => patch({ approval: mode }),
    setDelivery: (mode) => patch({ delivery: mode }),
    setMode: actions.setMode,
    setRunner: (id) => patch({ runner: id, runnerEdited: true }),
    // A user-initiated open (a row, a schedule execution, a create) asks the
    // shell to show the conversation panel.
    onOpen(listener) { openers.add(listener); return () => openers.delete(listener); },
    async rounds(runId, before = null) {
      const values = { ...target(runId), limit: ROUND_PAGE, ...(before ? { before } : {}) };
      return (await call(query("/runs/transcript", values), { signal: view.signal })).transcript;
    },
    artifactOpener() {
      const host = get().id;
      return createArtifactOpener({ artifactBytes, host: () => host, signal: view.signal });
    },
    openTask(runId, taskKey, title) {
      openDock("task", { id: `${runId}:${taskKey}`, params: { runId, taskKey, title } });
    },
  };
}
