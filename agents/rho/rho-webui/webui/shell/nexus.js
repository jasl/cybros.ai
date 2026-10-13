// THE HUMAN-CREDENTIAL PROXY: the page reaches Nexus's user and admin planes
// — `/api/v1/...` with the signed-in Human's own session — through the
// daemon's `POST /nexus/request`, never with the Agent's credential. The
// daemon answers 200 with Nexus's status, body and a few headers inside;
// a Nexus refusal is thrown here as an error carrying Nexus's code and
// sentence, so a caller reads one shape. The daemon's own refusals (an
// unlock-only session: `human_login_required`; a lost grant: 401) ride
// through `call` as they do everywhere.
export function createNexus({ call }) {
  async function request(path, { method = "GET", body, signal, timeout, headers } = {}) {
    const payload = { path, method };
    if (body !== undefined) payload.body = body;
    if (timeout !== undefined) payload.timeout = timeout;
    if (headers !== undefined) payload.headers = headers;
    const answer = await call("/nexus/request", { method: "POST", body: payload, signal });
    if (answer.status >= 400) {
      const error = answer.body?.error || {};
      throw Object.assign(new Error(error.message || `Nexus answered ${answer.status}`),
        { status: answer.status, code: error.code || "nexus_refused", details: error, nexus: true });
    }
    return answer.body;
  }
  return { request };
}
