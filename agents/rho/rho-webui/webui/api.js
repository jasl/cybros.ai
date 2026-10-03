// THE ONE PLACE THE BEARER LIVES, and the only place it is put anywhere.
//
// sessionStorage, never localStorage: web storage is keyed by origin, so a
// rebound origin gets different storage — but localStorage would make a
// credential that grants this host's shell outlive the tab that earned it,
// which is strictly worse than the document injection this replaced.
const KEY = `rho.bearer.${location.origin}`;

export const bearer = {
  get: () => { try { return sessionStorage.getItem(KEY); } catch { return null; } },
  set: (value) => { try { sessionStorage.setItem(KEY, value); } catch { /* private mode */ } },
  clear: () => { try { sessionStorage.removeItem(KEY); } catch { /* private mode */ } },
};

export class Refused extends Error {
  constructor(status, code, message) {
    super(message || code || `HTTP ${status}`);
    this.status = status;
    this.code = code;
  }
}

async function refusal(response) {
  let body = {};
  try { body = await response.json(); } catch { /* not JSON */ }
  const error = body.error || {};
  return new Refused(response.status, error.code, error.message);
}

// EVERY 401 IS THE RESTART PATH. The daemon mints a new bearer per boot, so a
// tab that outlived a restart is holding a token for a process that is gone;
// clearing and showing the connect screen is the whole recovery.
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

// REDEEM ONCE, AND NEVER RETRY. A retry loop is a self-inflicted lockout, and
// a double-invoked effect would turn one code into two attempts — so the
// in-flight promise is module state, not component state.
let exchanging = null;
export function redeem(code) {
  exchanging ||= fetch("/console/session", {
    method: "POST",
    headers: { "content-type": "application/json", "x-rho-console": "1" },
    body: JSON.stringify({ code }),
  }).then(async (response) => {
    if (!response.ok) throw await refusal(response);
    const { bearer: token } = await response.json();
    bearer.set(token);
    return token;
  }).finally(() => { exchanging = null; });
  return exchanging;
}

export async function unlock(passphrase) {
  const response = await fetch("/unlock", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ passphrase }),
  });
  if (!response.ok) throw await refusal(response);
  const { bearer: token } = await response.json();
  bearer.set(token);
  return token;
}

// SSE OVER fetch, NEVER EventSource: `/loops/follow` is guarded and an
// EventSource cannot set an Authorization header. The alternative — a ticket
// in a query string — would be a second credential mechanism, which is the
// thing the console code exists to avoid.
export async function follow(publicId, { signal, onFrame }) {
  const response = await fetch(`/loops/follow?public_id=${encodeURIComponent(publicId)}`, {
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
// through the relay and this machine's own answers from disk.
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
