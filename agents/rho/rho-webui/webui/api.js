import { t } from "./i18n.js";
// Nexus login creates a browser credential distinct from the daemon's private
// CLI bearer. Keep it in this tab's sessionStorage, including across refreshes.
const KEY = `rho.bearer.${location.origin}`;

export const bearer = {
  get: () => { try { return sessionStorage.getItem(KEY); } catch { return null; } },
  set: (value) => { try { sessionStorage.setItem(KEY, value); } catch { /* private mode */ } },
  clear: () => { try { sessionStorage.removeItem(KEY); } catch { /* private mode */ } },
};

export class Refused extends Error {
  constructor(status, code, message, details = {}) {
    super(message || code || t("api.http", { status: status }));
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

async function refusal(response) {
  let body = {};
  try { body = await response.json(); } catch { /* not JSON */ }
  const error = body.error || {};
  return new Refused(response.status, error.code, error.message, error);
}

// A browser session survives daemon restart while its Human grant is valid.
// Authority loss requires a fresh Nexus login; the private CLI bearer stays local.
export async function call(path, { method = "GET", body, signal, conversation } = {}) {
  const headers = {};
  const token = bearer.get();
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined) headers["content-type"] = "application/json";
  if (conversation) headers["x-rho-viewing-conversation"] = conversation;

  const response = await fetch(path, {
    method, signal, headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (response.status === 401) { bearer.clear(); throw new Refused(401, "unauthorized"); }
  if (!response.ok) throw await refusal(response);
  return response.status === 204 ? null : response.json();
}

export const health = () => fetch("/healthz").then((r) => r.json());

// SSE OVER fetch, NEVER EventSource: `/followers/follow` is guarded and an
// EventSource cannot set an Authorization header. The alternative — a ticket
// in a query string — would expose a credential in resource URLs.
export async function follow(publicId, { signal, onFrame }) {
  const response = await fetch(`/followers/follow?public_id=${encodeURIComponent(publicId)}`, {
    headers: { authorization: `Bearer ${bearer.get()}` }, signal,
  });
  if (response.status === 401) { bearer.clear(); throw new Refused(401, "unauthorized"); }
  if (!response.ok) throw await refusal(response);

  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return;
    buffer += value;
    // A frame ends at a blank line; a `: comment` heartbeat parses to nothing
    // and is dropped by the type check below.
    let split;
    while ((split = buffer.indexOf("\n\n")) !== -1) {
      const frame = buffer.slice(0, split);
      buffer = buffer.slice(split + 2);
      let type = null;
      let data = "";
      for (const line of frame.split("\n")) {
        if (line.startsWith("event: ")) type = line.slice(7);
        else if (line.startsWith("data: ")) data += line.slice(6);
      }
      if (!type) continue;
      let payload = {};
      try { payload = data ? JSON.parse(data) : {}; } catch { continue; }
      onFrame(type, payload);
    }
  }
}

// The bytes a transcript only named, read where the file IS: `host` names
// the followed host whose runner wrote it, so a runner elsewhere answers
// through the call_tool and this machine's own answers from disk.
export const artifactUrl = (path, download = false, host = null) =>
  `/files/bytes?path=${encodeURIComponent(path)}${download ? "&download=1" : ""}` +
  `${host ? `&host=${encodeURIComponent(host)}` : ""}`;

// Resource elements cannot send our bearer. Read bytes through the same
// authenticated boundary and give the view a Blob, never a token-bearing URL.
export async function artifactBytes(artifact, host, signal, download = false) {
  const path = artifact.public_id
    ? `/uploads/bytes?public_id=${encodeURIComponent(artifact.public_id)}&kind=bytes`
    : artifactUrl(artifact.path, download, host);
  const response = await fetch(path, {
    headers: { authorization: `Bearer ${bearer.get()}` }, signal,
  });
  if (response.status === 401) { bearer.clear(); throw new Refused(401, "unauthorized"); }
  if (!response.ok) throw await refusal(response);
  return response.blob();
}
