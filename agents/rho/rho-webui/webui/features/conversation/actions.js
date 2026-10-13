import { t } from "../../kernel/i18n.js";
import { composerState, conversationTarget, conversationControls, latestPendingSteer } from "./lifecycle.js";

// The person's own memory document a review keeps: the `user/` root reaches
// every conversation the same Human has, so one document serves them all.
export const MEMORY_REVIEW_PATH = "user/review.md";

// The request ran, but the remembered site rule could not be saved.
export function approvalNotice(result) {
  return result?.grant?.refused ? t("seat.grant_refused") : null;
}

// The page's writes. Each one names the viewed conversation, so the daemon
// can refuse it while an ingress channel owns that conversation, and none is
// ever retried automatically: an uncertain send keeps its key for a manual
// retry of the same payload.
export function createActions(context) {
  const { call, get, patch, setDraft, draftScope, current, target, drafts, submissions, list, toast,
    select, refreshConversation, beginFollow, unsettle, conversationError, errorMessage } = context;
  const reread = (v) => refreshConversation(v).catch(() => {});

  async function send(mode = get().delivery) {
    const value = get();
    const v = context.view();
    if (!composerState(value).send) return;
    const { id, draft: text, model, approval, runner, agent } = value;
    patch({ busy: true, error: "", notice: "" });
    try {
      let workspace = value.workspace;
      if (!id && !workspace) {
        // The workspace owner moves an early draft from its unknown default
        // to the resolved workspace. Freeze the request only after that move.
        await context.workspaces.ready();
        if (!current(v)) return;
        if (!get().workspace) await context.workspaces.refresh();
        if (!current(v)) return;
        workspace = get().workspace;
      }
      if (!workspace) throw new Error(t("composer.no_workspace"));
      const scope = draftScope({ ...value, workspace });
      const body = id ? { ...target(id), text, approval_mode: approval, delivery_mode: mode }
        : { prompt: text, approval_mode: approval, default_runner_executor_public_id: runner };
      // Omission preserves the server's intent; null deliberately clears a
      // pin. Displaying a default or an actual response route never pins it.
      if (value.modelEdited) body.model = model || null;
      if (!id) Object.assign(body, { code_mode: value.modes.code_mode, subagent: value.modes.subagent });
      // A bot's conversation names its answerer at the create; rho's own needs no name.
      if (!id && agent) body.agent = agent;
      const path = id ? "/say" : "/conversations";
      const request = submissions.prepare(path, body, workspace, scope);
      const result = await call(request.path, { method: "POST", body: request.body, conversation: id });
      submissions.accepted(request, drafts);
      // Text typed while the request was in flight belongs to the next message.
      if (draftScope() === scope && get().draft === text) setDraft("");
      if (current(v)) {
        if (!id) {
          drafts.set(result.conversation.public_id, drafts.get(scope) || "");
          drafts.delete(scope);
          select(result.conversation.public_id, { workspace: request.body.workspace_public_id });
          patch({ focus: get().focus + 1 });
        } else {
          unsettle();
          await reread(v);
          beginFollow(v);
        }
      }
      list.refresh();
    } catch (error) {
      if (id) conversationError(error, v); else if (current(v)) errorMessage(error);
    } finally {
      if (current(v)) patch({ busy: false });
    }
  }

  // Existing conversations save immediately. A new draft carries its choices
  // into creation; it never changes the application defaults.
  async function setMode(name, enabled) {
    const value = get();
    const { id, modes } = value;
    if (!modes?.available || value.modesBusy || value.busy || name === "code_mode" && !modes.code_mode_available
      || id && !conversationControls(value.detail, value.access).send) return;
    if (!id) { patch({ modes: { ...modes, [name]: enabled } }); return; }
    const v = context.view();
    patch({ modesBusy: true, error: "" });
    try {
      const result = await call("/conversations/modes", { method: "PATCH", body: { ...target(id), [name]: enabled }, conversation: id });
      if (current(v)) patch({ modes: result.modes });
    } catch (error) { conversationError(error, v); }
    finally { if (current(v)) patch({ modesBusy: false }); }
  }

  // Mod+Enter sends normally when idle. During work it sends an immediate
  // steer, or promotes the latest waiting steer without resubmitting it.
  function sendNow() {
    const value = get();
    const gate = composerState(value);
    if (!gate.running && !gate.steer) return send();
    if (!gate.sendNow) return undefined;
    return value.draft.trim() ? send("steer_now") : promote();
  }

  async function promote() {
    const value = get();
    const v = context.view();
    const input = latestPendingSteer(value.inputs);
    if (!input || value.busy || !composerState(value).controls.send) return;
    patch({ busy: true, error: "" });
    try {
      await call("/inputs/update", { method: "POST", body: { ...target(value.id), host_type: "conversation",
        input_public_id: input.public_id, delivery_mode: "steer_now" }, conversation: value.id });
      if (current(v)) { await reread(v); beginFollow(v); }
    } catch (error) { conversationError(error, v); }
    finally { if (current(v)) patch({ busy: false }); }
  }

  // Stop covers every execution owner of the conversation, including
  // background work that outlives a finished reply.
  async function stop() {
    const { id, stopping } = get();
    const v = context.view();
    if (!id || stopping || !composerState(get()).stop) return;
    patch({ stopping: true, error: "" });
    try {
      await call("/stop", { method: "POST", body: { ...target(id), host_type: "conversation", force: true }, conversation: id });
      if (current(v)) await reread(v);
    } catch (error) {
      if (current(v)) { patch({ stopping: false }); conversationError(error, v); }
    }
  }

  // An ask belongs to its run; the conversation header still names the view.
  async function respond(ask, path, body = {}) {
    const v = context.view();
    try {
      const result = await call(path, { method: "POST", body: { ...target(ask.run_public_id), task_key: ask.task_key, ...body }, conversation: get().id });
      if (current(v)) {
        await reread(v);
        const notice = approvalNotice(result);
        if (notice && current(v)) patch({ notice });
      }
      return true;
    } catch (error) { conversationError(error, v); return false; }
  }

  async function execute(path, body) {
    const { id, workspace } = get();
    const v = context.view();
    try {
      await call(path, { method: "POST", body: { ...conversationTarget(body.public_id, workspace), ...body }, conversation: id });
      if (current(v)) { unsettle(); await reread(v); beginFollow(v); }
    } catch (error) {
      conversationError(error, v);
      throw error;
    }
  }

  // Memory review is one switch: on writes the person's own review document
  // after each reply, off stops future reviews. The status the daemon
  // answers is what the menu shows next.
  async function setMemoryReview(enabled) {
    const { id, reviewBusy } = get();
    const v = context.view();
    if (!id || reviewBusy) return false;
    patch({ reviewBusy: true, error: "" });
    try {
      const body = { ...target(id), ...(enabled ? { path: MEMORY_REVIEW_PATH } : {}) };
      const answer = await call(`/conversations/memory_review/${enabled ? "enable" : "disable"}`, { method: "POST", body, conversation: id });
      if (current(v)) patch({ review: answer.memory_review });
      return true;
    } catch (error) {
      if (current(v)) conversationError(error, v);
      return false;
    } finally {
      if (current(v)) patch({ reviewBusy: false });
    }
  }

  // Rows of the sidebar act on conversations that may not be shown; their
  // workspace comes from the list row and their errors become toasts.
  async function manage(id, write) {
    const selected = id === get().id;
    const v = context.view();
    const row = list.state.get().rows.find((entry) => entry.public_id === id);
    try {
      await write(conversationTarget(id, selected ? get().workspace : row?.workspace_public_id));
    } catch (error) {
      if (selected) conversationError(error, v);
      else if (error.name !== "AbortError" && error.status !== 401) toast(error.message || t("conversation.request_failed"), { tone: "error" });
      return false;
    }
    if (selected && current(v)) reread(v);
    list.refresh();
    return true;
  }

  return {
    send, sendNow, promote, stop, respond, execute, setMemoryReview, setMode,
    rename: (id, title) => manage(id, (fields) => call("/conversations", { method: "PATCH", body: { ...fields, title: title.trim() }, conversation: id })),
    archive: (id) => manage(id, (fields) => call("/conversations/archive", { method: "POST", body: fields, conversation: id })),
    restore: (id) => manage(id, (fields) => call("/conversations/unarchive", { method: "POST", body: fields, conversation: id })),
  };
}
