// A turn can acquire another variant/loop without changing its public id.
export function executionIdentity(conversation, turns, snapshot) {
  const turn = conversation?.active_turn_public_id || snapshot?.turn;
  if (!turn) return null;
  const variant = turns.find((row) => row.public_id === turn)?.active_variant;
  const execution = variant?.agent_loop_public_id || variant?.public_id || (snapshot?.turn === turn ? snapshot.loop : null);
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
  const writable = readable && access === "ready" && !conversation.ingresses?.length;
  return { writable, send: writable && !conversation.archived_at, stop: readable && access === "ready" };
}

// Retry an uncertain send with the same payload and key. This is page-local
// request state, not a conversation store, and never automatically sends IO.
export class Submissions {
  constructor(key = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("")) {
    this.key = key; this.pending = new Map();
  }
  find(path, body) {
    const payload = JSON.stringify([path, body]);
    return this.pending.get(payload) || null;
  }
  prepare(path, body, workspace = null) {
    const previous = this.find(path, body);
    if (previous) return previous;
    const scope = body.public_id || "new";
    const payload = JSON.stringify([path, body]);
    const request = { scope, payload, path, body: { ...body,
      ...(workspace ? { workspace_public_id: workspace } : {}), idempotency_key: this.key() } };
    this.pending.set(payload, request);
    return request;
  }
  accepted(request, drafts) {
    this.pending.delete(request.payload);
    const text = request.body.text ?? request.body.prompt;
    if (drafts.get(request.scope) === text) drafts.delete(request.scope);
  }
}
