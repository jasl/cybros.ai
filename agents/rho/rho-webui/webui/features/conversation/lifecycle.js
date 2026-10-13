// Page-owned conversation lifecycle: which execution the page follows, how a
// refusal changes the view and what the composer may do. Pure: no DOM and no
// requests.

const WAITING = ["pending", "steering", "blocked", "held"];

// Inputs the conversation still owes the model.
export const waitingInput = (input) => WAITING.includes(input.state);

// A turn can acquire another variant/run without changing its public id.
export function executionIdentity(conversation, turns, snapshot) {
  const turn = conversation?.active_turn_public_id || snapshot?.turn;
  if (!turn) return null;
  const row = turns.find((candidate) => candidate.public_id === turn);
  if (row?.reference) return null;
  const variant = row?.active_variant;
  const execution = variant?.run_public_id || variant?.public_id || (snapshot?.turn === turn ? snapshot.run_public_id : null);
  return execution ? `${turn}:${execution}` : null;
}

export function refusalState(error) {
  if (error.status === 403) return "read-only";
  if (error.status === 404) return "unavailable";
  return null;
}

export function conversationTarget(public_id, workspace) {
  return { public_id, ...(workspace ? { workspace_public_id: workspace } : {}) };
}

export function conversationControls(conversation, access) {
  const readable = !!conversation && access !== "unavailable";
  const writable = readable && access === "ready" && !conversation.bot_public_id && !conversation.ingresses?.length;
  return { writable, send: writable && !conversation.archived_at, stop: readable && access === "ready" };
}

// Send now promotes the latest ordinary steer; earlier steers keep their
// order and queued work is never replaced.
export function latestPendingSteer(inputs) {
  return inputs.filter((input) => input.state === "steering" && input.delivery_mode === "steer")
    .sort((left, right) => left.queue_position - right.queue_position).at(-1);
}

// What the composer may do for one view of the controller's state. A
// selected conversation sends only while writable; a new one also needs a
// runner. An explicit model must be listed; Automatic needs an available
// catalog and lets the server resolve the Preset's model.
export function composerState(value) {
  const controls = conversationControls(value.detail, value.access);
  const running = !!value.detail?.active_turn_public_id;
  const steer = latestPendingSteer(value.inputs);
  const text = !!value.draft.trim();
  const model = value.model ? (value.models || []).some((row) => row.ref === value.model) : !!value.models?.length;
  const send = !value.busy && !value.modesBusy && !!value.modes && (!value.id || controls.send) && text && model && (!!value.id || !!value.runner);
  return {
    controls, running, steer, send,
    sendNow: !!value.id && (running || !!steer) && !value.busy && controls.send && (text ? send : !!steer),
    stop: !!value.id && controls.stop,
  };
}
