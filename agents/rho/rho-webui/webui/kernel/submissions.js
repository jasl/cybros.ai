import { t } from "./i18n.js";

// Retry an uncertain send with the same payload and key. This is page-local
// request state, not a conversation store, and never automatically sends IO.
export class Submissions {
  constructor(key = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("")) {
    this.key = key; this.pending = new Map();
  }
  find(path, body, scope = body.public_id || "new") {
    const payload = JSON.stringify([scope, path, body]);
    return this.pending.get(payload) || null;
  }
  prepare(path, body, workspace = null, scope = body.public_id || "new") {
    const previous = this.find(path, body, scope);
    if (previous) {
      if (["/say", "/conversations"].includes(path) && Date.now() - previous.createdAt >= 24 * 60 * 60 * 1000) {
        throw new Error(t("composer.acceptance_unknown"));
      }
      return previous;
    }
    const payload = JSON.stringify([scope, path, body]);
    const request = { scope, payload, path, createdAt: Date.now(), body: { ...body,
      ...(workspace ? { workspace_public_id: workspace } : {}), idempotency_key: this.key() } };
    this.pending.set(payload, request);
    return request;
  }
  accepted(request, drafts) {
    this.pending.delete(request.payload);
    const text = request.body.text ?? request.body.prompt;
    if (drafts?.get(request.scope) === text) drafts.delete(request.scope);
  }
}
