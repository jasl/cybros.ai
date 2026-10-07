import { bearer, call, follow, health, artifactBytes, Refused } from "./api.js";
import { el, state, prose, conversationButton, titleOf, modelRef, turnCard, roundCard, taskDetail, isTerminal, preserveTurnArtifacts } from "./views.js";
import { approvalControls, approvalNotice, executionControls } from "./controls.js";
import { executionIdentity, refusalState, conversationTarget, conversationControls, Submissions } from "./lifecycle.js";
import { openSchedules } from "./schedules.js";
import { createSettings } from "./settings.js";
import { runnerChoice } from "./settings_state.js";
import { createLogin } from "./login.js";
import { createConversationMetrics } from "./conversation_usage.js";
import { createComposer } from "./composer.js";

const CONTROL_VERSION = 4;
const PAGE_SIZE = 40;
const DETACHED_MESSAGE = "This conversation is not attached. Use Refresh to reconnect.";
const root = document.getElementById("root");
const app = {
  screen: "connect", status: null, selected: null, conversation: null,
  conversations: [], listAfter: null, archived: false, models: [], runners: [],
  turns: [], beforeTurn: null, moreTurns: false, asks: [], inputs: [],
  drafts: new Map(), snapshot: null, live: "", reasoning: "", stream: null,
  view: null, busy: false, refreshing: false, poll: null, reconnect: null,
  objects: new Set(), messageNodes: new Map(), error: "", connection: "",
  workspace: null, access: "ready", detached: false, submissions: new Submissions(),
  settings: null,
};
let ui = null;
let login = null;
const query = (path, values) => `${path}?${new URLSearchParams(values)}`;
const current = (view) => !!view && app.screen === "console" && app.view === view && !view.signal.aborted;
const draftKey = () => app.selected || "new";
const scopedTarget = (id = app.selected) => conversationTarget(id, app.workspace);
const button = (text, action, attrs = {}) => el("button", { type: "button", text, onclick: action, ...attrs });

function errorMessage(error) {
  if (error.name === "AbortError") return;
  if (error instanceof Refused && error.status === 401) {
    disconnect("Your Nexus authorization is no longer available. Sign in again.");
    return;
  }
  app.error = error.code === "member_plane_unavailable"
    ? "rho lost its Nexus connection. Sign out and reconnect with Nexus."
    : error.message || "The request failed. Try again.";
  paintStatus();
}

function conversationError(error, view) {
  if (!current(view) || error.name === "AbortError") return;
  if (error.code === "ingress_bound") {
    app.access = "loading"; paintControls(); paintAsks(); paintExecution();
    refreshConversation(view).catch((failure) => conversationError(failure, view));
  }
  const access = refusalState(error);
  if (access) {
    app.access = access;
    app.stream?.abort(); app.stream = null;
    clearTimeout(app.reconnect); app.reconnect = null;
    app.snapshot = null; app.asks = []; app.inputs = []; app.live = ""; app.reasoning = "";
    ui.renameArea.replaceChildren();
    app.connection = access === "read-only"
      ? "This conversation is read-only. Use Refresh to check access again."
      : "This conversation is unavailable. Your draft is kept. Use Refresh to check again.";
    paintAsks(); paintInputs(); paintExecution(); paintLive(); paintControls();
  }
  errorMessage(error);
}

function connectScreen() {
  login?.destroy();
  login = createLogin({ root, call, credentials: bearer, onReady: enter, message: app.error });
  login.initialize();
}

async function logout() {
  try {
    await call("/auth/logout", { method: "POST", body: {} });
    bearer.clear(); disconnect();
  } catch (error) { errorMessage(error); }
}

// The composer and shell live until disconnect. Streams update only their
// message, so an arriving token cannot replace a textarea or steal focus.
function mount() {
  const { message, model, approval, codeMode, send, stop, composer } = createComposer({
    onMessage: (value) => { app.drafts.set(draftKey(), value); resizeComposer(); paintControls(); },
    onChange: paintControls, onSubmit: sendMessage, onStop: stopConversation,
  });
  const runner = el("select", { id: "runner", required: true, onchange: () => {
    const selected = app.runners.find((row) => row.public_id === runner.value);
    runner.dataset.edited = "true"; ui.directory.value = "";
    ui.directory.placeholder = selected?.root || "Runner's default directory"; paintControls();
  } }, el("option", { value: "", text: "Loading runners…" }));
  const directory = el("input", { id: "directory", placeholder: "Runner's default directory" });
  const list = el("nav", { "aria-label": "Conversation list" });
  const moreList = button("More conversations", () => refreshList(true).catch(errorMessage), { hidden: true });
  const archived = el("input", { type: "checkbox", id: "archived", onchange: () => {
    app.archived = archived.checked; refreshList().catch(errorMessage);
  } });
  const menu = button("Conversations", () => openRail(true), { class: "mobile-only", "aria-expanded": "false", "aria-controls": "conversation-rail" });
  const rail = el("aside", { class: "rail", id: "conversation-rail", "aria-label": "Conversations" },
    button("Close conversations", () => openRail(false), { class: "mobile-only" }),
    button("New conversation", () => selectConversation(null), { class: "wide" }),
    el("label", { class: "check", for: "archived" }, archived, "Archived conversations"), list, moreList);
  const title = el("h2", { text: "New conversation" });
  const bound = el("p", { class: "muted bound-runner" });
  const metrics = createConversationMetrics();
  const rename = button("Rename", showRename);
  const archive = button("Archive", archiveConversation);
  const jobs = button("Scheduled jobs", () => {
    const view = app.view; const target = scopedTarget();
    openSchedules({ shell: ui.shell, call, target, signal: view.signal, active: () => current(view),
      writable: () => current(view) && conversationControls(app.conversation, app.access).writable,
      model: () => ui.model.value, approvalMode: () => ui.approval.value,
      onError: (error) => conversationError(error, view),
      openConversation: (id) => selectConversation(id, { workspace: target.workspace_public_id }) });
  });
  const headingActions = el("div", { class: "heading-actions" }, jobs, rename, archive);
  const renameArea = el("div", { class: "rename-area" });
  const newOptions = el("details", { class: "working-options" }, el("summary", { text: "Working location" }), el("div", { class: "new-options" },
    el("label", { for: "runner", text: "Runner" }, runner),
    el("label", { for: "directory", text: "Working directory" }, directory)));
  const messages = el("div", { class: "messages" });
  const moreTurns = button("Load more messages", loadMoreTurns, { hidden: true });
  const liveText = el("div", { class: "markdown" });
  const reasoning = el("div", { class: "reasoning-text" });
  const thinking = el("details", { class: "activity", hidden: true }, el("summary", { text: "Reasoning" }), reasoning);
  const live = el("article", { class: "message assistant live", "aria-label": "Current response", hidden: true },
    el("header", {}, el("strong", { text: "rho" }), el("span", { class: "muted", text: "Working…" })), liveText, thinking);
  const pending = el("div", { class: "pending-inputs" });
  const transcript = el("div", { class: "transcript", role: "region", "aria-label": "Conversation history", tabindex: "0" },
    moreTurns, messages, live, pending);
  const asks = el("div", { class: "asks", "aria-label": "Waiting for you" });
  const error = el("p", { class: "error-banner bad", role: "alert", hidden: true });
  const connection = el("p", { class: "connection muted", role: "status", hidden: true });
  const ingress = el("p", { class: "connection muted", role: "status", hidden: true });
  const execution = el("div");
  const setupNotice = el("div", { class: "setup-notice", role: "status", hidden: true });
  const jump = button("Jump to latest", () => { transcript.scrollTop = transcript.scrollHeight; jump.hidden = true; }, { class: "jump", hidden: true });
  transcript.addEventListener("scroll", () => { jump.hidden = app.asks.length > 0 || nearBottom(); });
  const stage = el("section", { class: "stage", "aria-label": "Conversation" },
    el("header", { class: "conversation-heading" }, el("div", { class: "conversation-title-block" }, title, bound), headingActions, metrics.element), renameArea,
    setupNotice, error, connection, ingress, execution, transcript, jump, asks, newOptions, composer);
  const healthStatus = el("span", { class: "muted", text: "Connecting…" });
  const shell = el("div", { class: "shell" }, el("header", { class: "bar" }, menu, el("h1", { text: "rho" }),
    healthStatus, el("span", { class: "spacer" }), button("Settings", () => ui.settings.open()), button("Refresh", refresh),
    button("Sign out", logout)), el("main", { class: "split" }, rail, stage));
  const backdrop = button("Close conversations", () => openRail(false), { class: "backdrop", tabindex: "-1", hidden: true });
  shell.append(backdrop);
  ui = { shell, message, model, runner, directory, approval, codeMode, send, stop, composer, list, moreList, archived,
    menu, rail, backdrop, title, bound, metrics, headingActions, jobs, rename, archive, renameArea, newOptions, messages,
    moreTurns, live, liveText, thinking, reasoning, pending, transcript, asks, error, connection, ingress, execution, healthStatus, jump };
  shell.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && shell.classList.contains("rail-open")) { event.preventDefault(); openRail(false); }
    if (event.key === "Tab" && shell.classList.contains("rail-open") && matchMedia("(max-width: 760px)").matches) {
      const controls = [...rail.querySelectorAll("button:not(:disabled), input, a")].filter((node) => !node.hidden);
      const first = controls[0]; const last = controls.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }
  });
  root.hidden = false; root.replaceChildren(shell);
  ui.settings = createSettings({ shell, notice: setupNotice, call, onError: errorMessage, onUse: () => ui.message.focus(),
    onChanged: async (document, status) => {
      const previous = app.settings?.settings.default_model; app.settings = document;
      if (!app.selected && (!ui.model.value || ui.model.value === previous)) setModel(document.settings.default_model);
      if (status.connected && app.view) await Promise.all([loadChoices(), refreshList()].map((request) => request.catch(errorMessage)));
    } });
}

function openRail(open) {
  ui.shell.classList.toggle("rail-open", open);
  ui.menu.setAttribute("aria-expanded", String(open)); ui.backdrop.hidden = !open;
  if (open) ui.rail.querySelector("button").focus(); else ui.menu.focus();
}
function nearBottom() { return ui.transcript.scrollHeight - ui.transcript.scrollTop - ui.transcript.clientHeight < 100; }
function resizeComposer() { ui.message.style.height = "auto"; ui.message.style.height = `${Math.min(ui.message.scrollHeight, 200)}px`; }
function paintStatus() {
  if (!ui || app.screen !== "console") return;
  ui.error.textContent = app.error; ui.error.hidden = !app.error;
  ui.connection.textContent = app.connection; ui.connection.hidden = !app.connection;
  ui.healthStatus.textContent = app.status?.workspace?.state === "adopted" ? "Connected" : app.status?.workspace?.state || "Connecting…";
}
function running() { return !!app.conversation?.active_turn_public_id; }
function paintControls() {
  if (!ui || app.screen !== "console") return;
  const archived = !!app.conversation?.archived_at;
  const controls = conversationControls(app.conversation, app.access);
  const ingresses = app.conversation?.ingresses || [];
  ui.ingress.hidden = !ingresses.length;
  ui.ingress.textContent = ingresses.length
    ? `${ingresses.map((entry) => entry.label).join(" · ")} — Continue in the original channel. This page is read-only.${controls.stop ? " Stop remains available." : ""}` : "";
  ui.send.disabled = app.busy || (app.selected && !controls.send) || !ui.message.value.trim() || !ui.model.value || ui.model.selectedOptions[0]?.disabled || (!app.selected && !ui.runner.value);
  ui.send.textContent = app.busy ? "Sending…" : "Send";
  ui.send.title = running() ? "Queue this message after the current response" : "Send message";
  // A final reply does not mean its conversation-lifetime background work ended.
  ui.stop.hidden = !app.selected || !controls.stop; ui.stop.disabled = app.stopping === true;
  ui.stop.title = "Stop all work in this conversation, including background work";
  ui.stop.textContent = app.stopping ? "Stopping…" : "Stop";
  ui.message.disabled = archived || ingresses.length > 0;
  ui.model.disabled = ingresses.length > 0; ui.approval.disabled = ingresses.length > 0;
  ui.codeMode.input.disabled = !!app.selected && !controls.send;
  ui.newOptions.hidden = !!app.selected;
  ui.runner.disabled = !!app.selected; ui.directory.disabled = !!app.selected;
  ui.headingActions.hidden = !app.selected;
  ui.rename.disabled = !controls.writable; ui.archive.disabled = !controls.writable;
  ui.jobs.disabled = !app.conversation || app.access === "unavailable";
  if (!controls.writable) ui.renameArea.replaceChildren();
  ui.archive.textContent = archived ? "Restore" : "Archive";
  ui.title.textContent = app.conversation ? titleOf(app.conversation) : "New conversation";
  const runner = app.conversation?.default_runner;
  const runnerName = app.runners.find((row) => row.public_id === runner?.executor_public_id)?.display_name;
  ui.bound.textContent = app.selected ? `${runnerName || runner?.executor_public_id || "No default Runner"}${archived ? " · Archived" : ""}` : "rho uses your default runner and working location.";
  ui.metrics.update(app.conversation, app.access);
}
function paintList() {
  const focusId = document.activeElement?.dataset.conversationId;
  ui.list.replaceChildren(...app.conversations.map((row) => conversationButton(row, row.public_id === app.selected, selectConversation)));
  if (!app.conversations.length) ui.list.append(el("p", { class: "muted", text: app.archived ? "No archived conversations." : "Your conversations will appear here." }));
  if (focusId) [...ui.list.querySelectorAll("button")].find((node) => node.dataset.conversationId === focusId)?.focus();
  ui.moreList.hidden = !app.listAfter;
}

async function loadChoices() {
  let models, runners;
  try {
    [models, runners] = await Promise.all([call("/models?workload=text_generation"), call("/runners")]);
  } catch (error) {
    if (!app.models.length) ui.model.replaceChildren(el("option", { value: "", text: "Models unavailable" }));
    if (!app.runners.length) ui.runner.replaceChildren(el("option", { value: "", text: "Runners unavailable" }));
    paintControls();
    throw error;
  }
  app.models = models.models; app.runners = runners.runners;
  const selectedModel = ui.model.value || (!app.selected && app.settings?.settings.default_model);
  ui.model.replaceChildren(el("option", { value: "", text: app.models.length ? "Choose a model" : "No available models" }),
    ...app.models.map((row) => el("option", { value: row.ref, text: row.display_name ? `${row.display_name} · ${row.ref}` : row.ref })));
  setModel(selectedModel);
  const selectedRunner = ui.runner.value;
  ui.runner.replaceChildren(el("option", { value: "", text: "Choose a runner" }),
    ...app.runners.map((row) => el("option", { value: row.public_id,
      text: `${row.display_name || row.public_id}${row.own ? " · This machine" : ""}${row.presence ? ` · ${row.presence}` : ""}` })));
  const chosen = runnerChoice(app.runners, { current: selectedRunner,
    defaultRunner: ui.settings.status()?.defaults?.runner_executor_public_id, edited: !!ui.runner.dataset.edited });
  if (chosen) { ui.runner.value = chosen.public_id; ui.directory.placeholder = chosen.root || "Runner's default directory"; }
  paintControls(); paintStatus();
}
function setModel(ref) {
  if (ref && ![...ui.model.options].some((option) => option.value === ref)) {
    ui.model.append(el("option", { value: ref, text: `${ref} · unavailable`, disabled: true }));
  }
  ui.model.value = ref || "";
}
async function refreshList(more = false) {
  const archived = app.archived;
  const values = { limit: PAGE_SIZE, archived: archived ? "1" : "0" };
  if (more && app.listAfter) values.after = app.listAfter;
  const result = await call(query("/conversations", values));
  if (app.screen !== "console" || archived !== app.archived) return;
  app.conversations = more ? [...app.conversations, ...result.conversations] : result.conversations;
  app.listAfter = result.pagination?.next_after; paintList();
}

function cleanView() {
  app.view?.abort(); app.stream?.abort(); app.stream = null;
  clearTimeout(app.reconnect); app.reconnect = null;
  for (const dialog of ui?.shell.querySelectorAll("dialog:not(.settings-dialog)") || []) { dialog.close(); dialog.remove(); }
  for (const url of app.objects) URL.revokeObjectURL(url);
  app.objects.clear(); app.messageNodes.clear();
}
async function selectConversation(id, { navigate = true, workspace = null } = {}) {
  if (app.screen !== "console") return;
  workspace ||= id && id === app.selected ? app.workspace : app.conversations.find((row) => row.public_id === id)?.workspace_public_id;
  app.drafts.set(draftKey(), ui.message.value);
  cleanView();
  const view = new AbortController(); app.view = view;
  app.selected = id; app.workspace = workspace; app.access = id ? "loading" : "ready";
  app.detached = false;
  app.conversation = null; app.turns = []; app.beforeTurn = null; app.moreTurns = false;
  app.asks = []; app.inputs = []; app.snapshot = null; app.live = ""; app.reasoning = ""; app.settledExecution = null;
  app.error = ""; app.connection = id ? "Loading conversation…" : ""; app.refreshing = false; app.stopping = false;
  app.askSignature = null; app.inputSignature = null; app.executionSignature = null;
  ui.renameArea.replaceChildren(); ui.messages.replaceChildren(); ui.asks.replaceChildren(); ui.pending.replaceChildren();
  ui.execution.replaceChildren();
  ui.message.value = app.drafts.get(draftKey()) || ""; resizeComposer();
  ui.codeMode.reset();
  ui.live.hidden = true; ui.moreTurns.hidden = true;
  if (navigate) {
    const url = new URL(location.href);
    if (id) url.searchParams.set("conversation", id); else url.searchParams.delete("conversation");
    if (id && workspace) url.searchParams.set("workspace", workspace); else url.searchParams.delete("workspace");
    history.pushState(null, "", url.pathname + url.search);
  }
  if (ui.shell.classList.contains("rail-open")) openRail(false);
  paintControls(); paintList(); paintStatus();
  if (!id) { ui.messages.append(state("Start a conversation", el("p", { text: "Choose a model and runner, then tell rho what you need." }))); ui.message.focus(); return; }
  try {
    await call("/followers/attach", { method: "POST", body: { ...scopedTarget(id), host_type: "conversation" }, signal: view.signal });
    if (!current(view)) return;
    await refreshConversation(view);
    if (!current(view)) return;
    const lastModel = [...app.turns].reverse().find((turn) => turn.active_variant?.model)?.active_variant.model;
    if (lastModel) setModel(modelRef(lastModel));
    paintControls();
    if (current(view)) beginFollow(view);
  } catch (error) { if (current(view)) { app.connection = ""; conversationError(error, view); } }
}

async function readTurns(view, before) {
  const id = app.selected;
  const values = { ...scopedTarget(id), limit: PAGE_SIZE };
  if (before !== undefined && before !== null) values.before_position = before;
  else values.latest = "1";
  const page = await call(query("/conversations/turns", values), { signal: view.signal });
  return { rows: page.turns, before: page.pagination?.before_position, older: !!page.pagination?.has_older };
}
async function refreshConversation(view = app.view) {
  if (!view || !current(view) || !app.selected || app.refreshing || ["read-only", "unavailable"].includes(app.access)) return;
  app.refreshing = true;
  try {
    const id = app.selected;
    const [detail, historyPage, codeMode] = await Promise.all([
      call(query("/conversations/detail", scopedTarget(id)), { signal: view.signal }), readTurns(view),
      call(query("/conversations/code_mode", scopedTarget(id)), { signal: view.signal }),
    ]);
    if (!current(view) || ["read-only", "unavailable"].includes(app.access)) return;
    app.conversation = detail.conversation;
    ui.codeMode.update(codeMode.code_mode);
    app.workspace = detail.conversation.workspace_public_id || app.workspace;
    app.access = "ready";
    if (app.workspace) {
      const url = new URL(location.href); url.searchParams.set("workspace", app.workspace);
      history.replaceState(null, "", url);
    }
    mergeTurns(historyPage);
    paintMessages(); paintControls();
    const [asks, inputs, followers] = await Promise.all([
      call("/asks", { signal: view.signal }), call(query("/inputs", { ...scopedTarget(id), host_type: "conversation" }), { signal: view.signal }),
      call("/followers", { signal: view.signal }),
    ]);
    if (!current(view) || ["read-only", "unavailable"].includes(app.access)) return;
    const snapshot = followers.followers.find((follower) => follower.public_id === id);
    if (snapshot) {
      if (app.snapshot && (snapshot.turn !== app.snapshot.turn || snapshot.run_public_id !== app.snapshot.run_public_id)) {
        app.live = ""; app.reasoning = "";
      }
    }
    app.snapshot = snapshot || null;
    const identity = executionIdentity(app.conversation, app.turns, app.snapshot);
    if (app.stream?.identity && identity !== app.stream.identity) {
      app.stream.abort(); app.stream = null; app.live = ""; app.reasoning = "";
    }
    const runs = new Set(app.turns.map((turn) => turn.active_variant?.run_public_id).filter(Boolean));
    if (app.snapshot?.run_public_id) runs.add(app.snapshot.run_public_id);
    app.asks = asks.asks.filter((ask) => runs.has(ask.run_public_id));
    app.inputs = inputs.inputs.filter((input) => ["pending", "blocked", "held"].includes(input.state));
    if (!app.conversation.active_turn_public_id) app.stopping = false;
    app.connection = app.detached ? DETACHED_MESSAGE : "";
    paintMessages(); paintAsks(); paintInputs(); paintControls(); paintStatus(); paintLive(); paintExecution();
    const listed = app.conversations.findIndex((row) => row.public_id === id);
    if (listed !== -1) { app.conversations[listed] = { ...app.conversations[listed], ...detail.conversation }; paintList(); }
    const active = app.conversation.active_turn_public_id;
    if (active && !app.stream && executionIdentity(app.conversation, app.turns, app.snapshot) !== app.settledExecution) beginFollow(view);
  } catch (error) { conversationError(error, view); throw error; }
  finally { if (current(view)) app.refreshing = false; }
}
async function loadMoreTurns() {
  const view = app.view;
  const height = ui.transcript.scrollHeight; const scrollTop = ui.transcript.scrollTop;
  ui.moreTurns.disabled = true;
  try {
    const page = await readTurns(view, app.beforeTurn);
    if (current(view)) {
      mergeTurns(page, true); paintMessages();
      ui.transcript.scrollTop = scrollTop + ui.transcript.scrollHeight - height;
    }
  } catch (error) { errorMessage(error); }
  finally { ui.moreTurns.disabled = false; }
}
function mergeTurns(page, older = false) {
  const previousFirst = app.turns[0]?.position;
  const rows = new Map(app.turns.map((turn) => [turn.public_id, turn]));
  for (const turn of page.rows) rows.set(turn.public_id, turn);
  app.turns = [...rows.values()].sort((left, right) => left.position - right.position);
  if (older || previousFirst === undefined || page.rows[0]?.position <= previousFirst) {
    app.beforeTurn = page.before; app.moreTurns = page.older;
  }
}
function paintMessages() {
  const pinned = nearBottom();
  const surviving = new Set();
  for (const turn of app.turns) {
    const id = turn.public_id; surviving.add(id);
    const signature = JSON.stringify(turn);
    let entry = app.messageNodes.get(id);
    if (!entry || entry.signature !== signature) {
      const open = entry ? [...entry.node.querySelectorAll("details[open]")].map((d) => d.dataset.disclosure) : [];
      const node = turnCard(turn, { onActivity: loadActivity, onArtifact: openArtifact });
      if (entry) preserveTurnArtifacts(entry.node, node);
      for (const detail of node.querySelectorAll("details")) if (open.includes(detail.dataset.disclosure)) detail.open = true;
      if (entry) entry.node.replaceWith(node); else ui.messages.append(node);
      entry = { node, signature }; app.messageNodes.set(id, entry);
    }
  }
  // Reordering existing nodes keeps disclosure/input state; older pages prepend
  // without rebuilding the already visible tail.
  let previous = null;
  for (const turn of app.turns) {
    const node = app.messageNodes.get(turn.public_id).node;
    if (previous ? previous.nextSibling !== node : ui.messages.firstChild !== node) {
      ui.messages.insertBefore(node, previous ? previous.nextSibling : ui.messages.firstChild);
    }
    previous = node;
  }
  for (const [id, entry] of app.messageNodes) {
    if (!surviving.has(id)) { entry.node.remove(); app.messageNodes.delete(id); }
  }
  if (!app.turns.length && !ui.messages.childElementCount) ui.messages.append(el("p", { class: "empty", text: "No messages yet." }));
  if (app.turns.length) for (const node of ui.messages.querySelectorAll(":scope > .empty")) node.remove();
  ui.moreTurns.hidden = !app.moreTurns;
  if (pinned) ui.transcript.scrollTop = ui.transcript.scrollHeight;
}
function paintLive() {
  if (!ui || app.screen !== "console") return;
  const pinned = nearBottom();
  const settled = app.turns.find((turn) => turn.public_id === app.snapshot?.turn && isTerminal(turn.status));
  ui.live.hidden = !!settled || (!app.live && !app.reasoning) || !running();
  if (ui.live.dataset.text !== app.live) {
    ui.liveText.replaceChildren(prose(app.live)); ui.live.dataset.text = app.live;
  }
  if (ui.reasoning.textContent !== app.reasoning) ui.reasoning.textContent = app.reasoning;
  ui.thinking.hidden = !app.reasoning;
  if (pinned) ui.transcript.scrollTop = ui.transcript.scrollHeight;
}
let renderPending = false;
function scheduleLive() {
  if (renderPending) return;
  renderPending = true;
  requestAnimationFrame(() => { renderPending = false; paintLive(); paintControls(); });
}

function beginFollow(view) {
  if (!current(view) || app.stream || !app.selected || app.access !== "ready" || app.detached) return;
  clearTimeout(app.reconnect); app.reconnect = null;
  const stream = new AbortController(); app.stream = stream;
  const id = app.selected; let closed = false; let streamIdentity = null;
  const abortStream = () => stream.abort();
  view.signal.addEventListener("abort", abortStream, { once: true });
  follow(id, { signal: stream.signal, onFrame: (type, payload) => {
    if (!current(view) || app.stream !== stream) return;
    if (type === "snapshot") {
      streamIdentity = payload.run_public_id ? `${payload.turn}:${payload.run_public_id}` : executionIdentity(app.conversation, app.turns, payload);
      stream.identity = streamIdentity;
      const activeIdentity = executionIdentity(app.conversation, app.turns, null);
      if (activeIdentity && streamIdentity && activeIdentity !== streamIdentity) {
        stream.abort(); app.stream = null; return;
      }
      app.snapshot = payload; app.live = payload.text || ""; app.reasoning = payload.reasoning || "";
      app.connection = ""; paintStatus(); scheduleLive();
      refreshConversation(view).catch((error) => { if (current(view)) errorMessage(error); });
    } else if (type === "text_delta") { app.live += payload.text || ""; scheduleLive(); }
    else if (type === "text_reset") { app.live = payload.text || ""; scheduleLive(); }
    else if (type === "reasoning_delta") { app.reasoning += payload.text || ""; scheduleLive(); }
    else if (type === "stream_reset" || type === "retry") { app.live = ""; app.reasoning = ""; scheduleLive(); }
    else if (type === "turn" || type === "round_result" || type === "task_status" || type === "turn_status") {
      // Durable turns remain authoritative, including variants selected elsewhere.
      refreshConversation(view).catch((error) => { if (current(view)) errorMessage(error); });
    } else if (type === "closed") {
      closed = true; app.settledExecution = streamIdentity;
      if (app.snapshot) app.snapshot.complete = true;
    }
  } }).then(async () => {
    if (!current(view) || app.stream !== stream) return;
    app.stream = null;
    await refreshConversation(view);
    if (!closed && current(view)) reconnect(view);
  }).catch((error) => {
    if (!current(view) || stream.signal.aborted) return;
    app.stream = null;
    if (error.status === 401) conversationError(error, view);
    else if (error.code === "run_not_followed") {
      app.detached = true;
      app.connection = DETACHED_MESSAGE; paintStatus();
    } else if (refusalState(error)) conversationError(error, view);
    else reconnect(view);
  }).finally(() => view.signal.removeEventListener("abort", abortStream));
}
function reconnect(view) {
  if (!current(view) || app.reconnect || app.access !== "ready") return;
  app.connection = "Connection interrupted. Reconnecting…"; paintStatus();
  app.reconnect = setTimeout(async () => {
    app.reconnect = null;
    if (!current(view)) return;
    try { await refreshConversation(view); if (current(view) && running()) beginFollow(view); }
    catch (error) { if (current(view)) { if (error.status === 401 || refusalState(error)) conversationError(error, view); else reconnect(view); } }
  }, 2000);
}

async function sendMessage(event) {
  event.preventDefault();
  if (ui.send.disabled) return;
  const text = ui.message.value; const id = app.selected; const view = app.view;
  const model = ui.model.value; const approval_mode = ui.approval.value;
  const codeMode = ui.codeMode.value();
  app.busy = true; app.error = ""; paintControls(); paintStatus();
  try {
    const body = id ? { ...scopedTarget(id), text, model, approval_mode, delivery_mode: "queue" }
      : { prompt: text, model, approval_mode, default_runner_executor_public_id: ui.runner.value };
    if (codeMode !== undefined) body.code_mode = codeMode;
    if (!id && ui.directory.value.trim()) body.environment = { root: ui.directory.value.trim() };
    const path = id ? "/say" : "/conversations";
    let request = app.submissions.find(path, body);
    if (!request) {
      // Freeze the current default only for this create, so a later retry
      // cannot create again in a different workspace after a default change.
      const workspace = id ? app.workspace : (await call("/workspaces")).workspace?.public_id;
      if (!workspace) throw new Error("Choose an available workspace with rho workspaces use, then try again.");
      request = app.submissions.prepare(path, body, workspace);
    }
    const result = await call(request.path, { method: "POST", body: request.body, conversation: id });
    app.submissions.accepted(request, app.drafts);
    // Clear only the submitted draft. Text typed while the request was in flight
    // belongs to the next message, and navigation belongs to the new view.
    if (current(view) && ui.message.value === text) { ui.message.value = ""; resizeComposer(); }
    if (current(view)) {
      ui.codeMode.accepted(codeMode);
      if (!id) {
        app.drafts.set(result.conversation.public_id, ui.message.value);
        app.drafts.delete("new");
        await selectConversation(result.conversation.public_id);
        ui.message.focus();
      }
      else { app.settledExecution = null; await refreshConversation(view); beginFollow(view); }
    }
    await refreshList();
  } catch (error) { if (id) conversationError(error, view); else if (current(view)) errorMessage(error); }
  finally { app.busy = false; paintControls(); }
}
async function stopConversation() {
  const id = app.selected; const view = app.view;
  app.stopping = true; app.error = ""; paintControls(); paintStatus();
  try {
    await call("/stop", { method: "POST", body: { ...scopedTarget(id), host_type: "conversation", force: true }, conversation: id });
    if (current(view)) await refreshConversation(view);
  } catch (error) { if (current(view)) { app.stopping = false; conversationError(error, view); paintControls(); } }
}
function showRename() {
  const id = app.selected; const view = app.view; const fields = scopedTarget(id);
  const field = el("input", { id: "conversation-title", value: app.conversation?.title || "", required: true });
  ui.renameArea.replaceChildren(el("form", { class: "rename-form", onsubmit: async (event) => {
    event.preventDefault();
    const submit = event.target.querySelector("button[type=submit]"); submit.disabled = true;
    try {
      await call("/conversations", { method: "PATCH", body: { ...fields, title: field.value.trim() }, conversation: id });
      if (current(view)) { ui.renameArea.replaceChildren(); await refreshConversation(view); }
      await refreshList();
    } catch (error) { conversationError(error, view); submit.disabled = false; }
  } }, el("label", { for: "conversation-title", text: "Conversation title" }), field,
  el("button", { type: "submit", text: "Save title" }), button("Cancel rename", () => ui.renameArea.replaceChildren())));
  field.focus(); field.select();
}
async function archiveConversation() {
  const id = app.selected; const view = app.view; const restore = !!app.conversation.archived_at;
  ui.archive.disabled = true;
  try {
    await call(`/conversations/${restore ? "unarchive" : "archive"}`, { method: "POST", body: scopedTarget(id), conversation: id });
    if (current(view)) await refreshConversation(view);
    await refreshList();
  } catch (error) { conversationError(error, view); }
  finally { paintControls(); }
}

function paintAsks() {
  const writable = conversationControls(app.conversation, app.access).writable;
  const signature = JSON.stringify([app.asks, writable]);
  if (app.askSignature === signature) return;
  app.askSignature = signature;
  ui.jump.hidden = app.asks.length > 0 || nearBottom();
  const drafts = new Map([...ui.asks.querySelectorAll("textarea")].map((field) => [field.name, field.value]));
  const focus = document.activeElement?.name;
  ui.asks.replaceChildren(...app.asks.map((ask) => {
    const key = `${ask.run_public_id}:${ask.task_key}`;
    const card = el("section", { class: "ask-card", "data-task-key": ask.task_key },
      el("h3", { text: ask.kind === "approval" ? "Approval required" : "rho needs your answer" }));
    if (ask.kind === "approval") {
      card.append(approvalControls(ask, (path, body) => respond(ask, path, body, card)));
    } else {
      const field = el("textarea", { id: `answer-${ask.task_key}`, name: key, rows: "2", required: true });
      field.value = drafts.get(key) || "";
      const question = typeof ask.prompt === "string" ? ask.prompt : JSON.stringify(ask.prompt || "");
      card.append(prose(question), el("form", { onsubmit: (event) => {
        event.preventDefault(); if (field.value.trim()) respond(ask, "/answer", { content: field.value }, card);
      } }, el("label", { for: field.id, text: "Answer" }), field, el("button", { type: "submit", text: "Send answer" })));
    }
    for (const control of card.querySelectorAll("button,textarea")) control.disabled = !writable;
    return card;
  }));
  if (focus) [...ui.asks.querySelectorAll("textarea")].find((field) => field.name === focus)?.focus();
}
async function respond(ask, path, body, card) {
  const view = app.view; const conversation = app.selected;
  for (const control of card.querySelectorAll("button,textarea")) control.disabled = true;
  try {
    const result = await call(path, { method: "POST", body: { ...scopedTarget(ask.run_public_id), task_key: ask.task_key, ...body }, conversation });
    if (current(view)) {
      await refreshConversation(view);
      const notice = approvalNotice(result);
      if (notice && current(view)) errorMessage(new Error(notice));
    }
  } catch (error) { conversationError(error, view); }
  finally {
    for (const control of card.querySelectorAll("button,textarea")) control.disabled = !current(view) || !conversationControls(app.conversation, app.access).writable;
  }
}
function paintInputs() {
  const signature = JSON.stringify(app.inputs);
  if (app.inputSignature === signature) return;
  app.inputSignature = signature;
  ui.pending.replaceChildren(...app.inputs.map((input) => el("article", { class: "message user pending" },
    el("header", {}, el("strong", { text: input.blocked_reason ? "Message waiting" : "Message queued" })),
    prose(input.text), input.blocked_reason ? el("p", { class: "warn", text: input.blocked_reason }) : null)));
}
function paintExecution() {
  const snapshot = conversationControls(app.conversation, app.access).writable ? app.snapshot : null;
  const signature = JSON.stringify([snapshot?.run_public_id, snapshot?.run_status, snapshot?.tasks, snapshot?.attention]);
  if (signature === app.executionSignature) return;
  app.executionSignature = signature;
  const view = app.view;
  const workspace = app.workspace;
  const conversation = app.selected;
  const controls = executionControls(snapshot, async (path, body) => {
    try {
      await call(path, { method: "POST", body: { ...conversationTarget(body.public_id, workspace), ...body }, conversation });
      if (current(view)) {
        app.settledExecution = null;
        await refreshConversation(view);
        beginFollow(view);
      }
    } catch (error) { conversationError(error, view); throw error; }
  });
  ui.execution.replaceChildren(...(controls ? [controls] : []));
}

async function loadActivity(runId, target, before = null) {
  const view = app.view;
  const loading = el("p", { class: "muted", text: "Loading activity…" }); target.append(loading);
  try {
    const values = { ...scopedTarget(runId), limit: 20 }; if (before) values.before = before;
    const { transcript } = await call(query("/runs/transcript", values), { signal: view.signal });
    if (!current(view) || !target.isConnected) return;
    loading.remove();
    const rows = transcript.rounds.map((round) => roundCard(round, runId, openTask, openArtifact));
    if (before) target.prepend(...rows); else target.append(...rows);
    if (!transcript.rounds.length) target.append(el("p", { class: "muted", text: "No recorded tool activity." }));
    if (transcript.has_older) target.prepend(button("Earlier activity", (event) => {
      event.currentTarget.remove(); loadActivity(runId, target, transcript.next_before);
    }));
  } catch (error) { if (current(view)) { loading.textContent = error.message; errorMessage(error); } }
}
async function openTask(runId, taskKey) {
  const view = app.view;
  try {
    const { task } = await call(query("/runs/task", { ...scopedTarget(runId), task_key: taskKey }), { signal: view.signal });
    if (!current(view)) return;
    const dialog = el("dialog", { class: "task-dialog", "aria-label": "Task output" },
      button("Close output", () => dialog.close()), taskDetail(task, openArtifact));
    dialog.addEventListener("close", () => dialog.remove(), { once: true });
    ui.shell.append(dialog); dialog.showModal();
  } catch (error) { if (current(view)) errorMessage(error); }
}
async function openArtifact(artifact, target, trigger, download = false) {
  const view = app.view; const host = app.selected;
  trigger.disabled = true;
  try {
    const blob = await artifactBytes(artifact, host, view.signal, download);
    if (!current(view) || !target.isConnected) return;
    if (target.dataset.objectUrl) { URL.revokeObjectURL(target.dataset.objectUrl); app.objects.delete(target.dataset.objectUrl); }
    const url = URL.createObjectURL(blob); app.objects.add(url); target.dataset.objectUrl = url;
    const name = artifact.filename || artifact.path?.split("/").pop() || "artifact";
    const image = !download && blob.type.startsWith("image/");
    const link = el("a", { href: url, download: name, text: `Save ${name}` });
    target.replaceChildren(image ? el("img", { src: url, alt: name }) : el("p", { class: "muted", text: `${name} · ${blob.size.toLocaleString()} bytes` }),
      link);
    if (download) link.click();
  } catch (error) { if (current(view)) { target.textContent = error.message; errorMessage(error); } }
  finally { trigger.disabled = false; }
}

async function refresh() {
  const view = app.view;
  app.error = ""; paintStatus();
  try {
    app.status = await call("/status");
    paintStatus();
    await ui.settings.refresh({ notify: false }); app.settings = ui.settings.document();
    // An unavailable new-conversation default must not prevent an old host's
    // explicitly scoped history from recovering.
    if (ui.settings.status()?.connected) await Promise.all([loadChoices(), refreshList()].map((request) => request.catch(errorMessage)));
    if (app.selected && current(view)) {
      app.access = "loading"; paintControls();
      if (!app.stream) {
        await call("/followers/attach", { method: "POST", body: { ...scopedTarget(), host_type: "conversation" }, signal: view.signal });
        if (current(view)) app.detached = false;
      }
      await refreshConversation(view);
      if (current(view)) beginFollow(view);
    }
    paintStatus();
  } catch (error) { conversationError(error, view); }
}
async function enter() {
  login?.destroy(); login = null;
  await start();
}
async function start({ openSettings = false } = {}) {
  app.screen = "console"; app.error = ""; mount();
  try {
    app.status = await call("/status");
    paintStatus();
    const params = new URL(location.href).searchParams;
    await selectConversation(params.get("conversation"), { navigate: false, workspace: params.get("workspace") });
    await ui.settings.refresh({ notify: false }); app.settings = ui.settings.document();
    // Navigation resets conversation errors; load page-wide choices afterward
    // so a missing Nexus connection or empty model catalog remains visible.
    if (ui.settings.status()?.connected) await Promise.all([loadChoices(), refreshList()].map((request) => request.catch(errorMessage)));
    if (openSettings || (ui.settings.status() && !ui.settings.status().model.ready)) ui.settings.open();
    clearInterval(app.poll);
    app.poll = setInterval(() => {
      const view = app.view;
      if (app.selected) refreshConversation(view).catch((error) => conversationError(error, view));
    }, 3000);
  } catch (error) { errorMessage(error); }
}
function disconnect(message = "") {
  login?.destroy(); login = null;
  ui?.settings.destroy(); cleanView(); clearInterval(app.poll); app.screen = "connect"; app.error = message; connectScreen();
}
window.addEventListener("popstate", () => {
  const params = new URL(location.href).searchParams;
  if (app.screen === "console") selectConversation(params.get("conversation"), { navigate: false, workspace: params.get("workspace") });
});
window.addEventListener("pagehide", () => { login?.destroy(); ui?.settings.destroy(); cleanView(); });
async function boot() {
  let facts = {};
  try { facts = await health(); } catch { /* The connect screen remains usable. */ }
  if (facts.control_version && facts.control_version !== CONTROL_VERSION) {
    root.hidden = false; root.replaceChildren(state("This page was built for a different daemon",
      el("p", { text: `The page speaks control version ${CONTROL_VERSION}; this daemon speaks ${facts.control_version}. Update whichever is older.` })));
    return;
  }
  if (!location.pathname.endsWith("/auth/callback") && bearer.get()) return enter();
  connectScreen();
}
boot();
