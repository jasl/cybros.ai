import { el } from "./views.js";
import { webLink } from "./settings_state.js";

// The transaction belongs to the tab that started login. The daemon keeps the
// PKCE verifier; this tab holds the separate secret needed to finish its login.
export function loginSession({ call, storage, credentials, currentUrl, navigate, replace }) {
  const key = `rho.login.${new URL(currentUrl()).origin}`;
  let polling = null;
  function pending() {
    const value = storage.getItem(key);
    if (!value) return null;
    try { return JSON.parse(value); }
    catch { storage.removeItem(key); return null; }
  }
  function clear() { storage.removeItem(key); }
  function accept(answer) {
    credentials.set(answer.bearer);
    clear();
    return answer;
  }
  async function start(flow, signal) {
    clear();
    polling = null;
    const answer = await call(flow === "device_code" ? "/auth/device/start" : "/auth/start", { method: "POST", body: {}, signal });
    const url = new URL(currentUrl());
    const transaction = { ...answer, flow, return_to: url.pathname + url.search };
    try { storage.setItem(key, JSON.stringify(transaction)); }
    catch { throw new Error("Allow session storage in this browser to sign in to rho."); }
    if (flow === "authorization_code") {
      const address = webLink(answer.authorization_url);
      if (!address) { clear(); throw new Error("Nexus returned an invalid login address."); }
      navigate(address);
    }
    return transaction;
  }
  async function complete(signal) {
    const url = new URL(currentUrl());
    const transaction = pending();
    // Strip callback material before any request, including a rejected callback.
    replace(transaction?.return_to || "/");
    clear();
    if (!transaction || transaction.flow !== "authorization_code" || url.searchParams.get("state") !== transaction.state) {
      throw new Error("This login does not match this browser tab. Start a new Nexus login.");
    }
    if (url.searchParams.has("error")) {
      throw new Error(url.searchParams.get("error") === "access_denied"
        ? "Nexus login was not approved. You can start again."
        : "Nexus could not complete login. Start a new Nexus login.");
    }
    const code = url.searchParams.get("code");
    if (!code) throw new Error("The Nexus login code is missing. Start a new Nexus login.");
    // A code exchange is single use. Even an uncertain network failure requires
    // a new login, never an automatic exchange retry after reload.
    return accept(await call("/auth/complete", { method: "POST", signal,
      body: { code, state: transaction.state, login_secret: transaction.login_secret } }));
  }
  function poll(signal) {
    if (polling) return polling;
    const transaction = pending();
    if (!transaction || transaction.flow !== "device_code") throw new Error("Start a new device login.");
    const current = () => pending()?.state === transaction.state;
    const request = call("/auth/device/poll", { method: "POST", signal,
      body: { state: transaction.state, login_secret: transaction.login_secret } })
      .then((answer) => !current() ? { phase: "superseded" } : answer.phase === "active" ? accept(answer) : answer)
      .catch((error) => {
        if (!current()) return { phase: "superseded" };
        clear(); throw error;
      })
      .finally(() => { if (polling === request) polling = null; });
    polling = request;
    return polling;
  }
  return { start, complete, pending, poll, clear };
}

export function createLogin({ root, call, credentials, onReady, message = "" }) {
  const controller = new AbortController();
  const session = loginSession({ call, credentials, storage: sessionStorage,
    currentUrl: () => location.href, navigate: (url) => location.assign(url),
    replace: (url) => history.replaceState(null, "", url) });
  let timer = null;
  let busy = false;
  const title = el("h1", { id: "login-title", text: "Connect to Nexus" });
  const description = el("p", { class: "muted", text: "Sign in with your Nexus account to use rho. On a new installation, Nexus will guide you through creating the first account." });
  const nexus = el("p", { class: "faint" });
  const alert = el("p", { class: "bad", role: "alert", hidden: !message, text: message });
  const progress = el("p", { role: "status", hidden: true });
  const device = el("div", { class: "login-device", hidden: true });
  const connect = el("button", { type: "button", class: "primary", text: "Connect to Nexus", onclick: () => begin("authorization_code") });
  const alternate = el("button", { type: "button", text: "Use a device code", onclick: () => begin("device_code") });
  const actions = el("div", { class: "login-actions" }, connect, alternate);
  root.hidden = false;
  root.replaceChildren(el("main", { class: "login", "aria-labelledby": "login-title" },
    el("p", { class: "login-brand", text: "rho" }), title, description, nexus, alert, progress, actions, device));

  function destroy() { controller.abort(); clearTimeout(timer); }
  function working(value) { busy = value; connect.disabled = value; alternate.disabled = value; }
  function showError(error) {
    if (controller.signal.aborted || error.name === "AbortError") return;
    alert.textContent = error.message || "Could not connect to Nexus. Try again.";
    alert.hidden = false; progress.hidden = true;
  }
  async function finish() { destroy(); await onReady(); }
  function showSetup(error) {
    const url = webLink(error.details?.initialization_uri);
    if (!url) { showError(error); return; }
    alert.hidden = true; progress.hidden = true; device.hidden = false;
    const resume = el("button", { type: "button", text: "Continue after setup", onclick: async () => {
      resume.disabled = true;
      try { await begin("device_code"); } finally { resume.disabled = false; }
    } });
    device.replaceChildren(el("h2", { text: "Create your Nexus account first" }),
      el("p", { text: "Open Nexus setup in another tab. Use the private setup link or setup secret supplied by your installer, create the first account, then continue here." }),
      el("p", {}, el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: "Open Nexus setup" })), resume);
  }
  function showDevice(transaction) {
    const url = webLink(transaction.verification_uri_complete || transaction.verification_uri);
    if (!url) throw new Error("Nexus returned an invalid device login address.");
    device.hidden = false;
    device.replaceChildren(el("h2", { text: "Approve this device login" }),
      el("p", {}, "Check this code in Nexus: ", el("strong", { class: "login-code", text: transaction.user_code })),
      el("p", {}, el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: "Open Nexus to approve" })),
      el("p", { class: "muted", text: "Keep this tab open. rho will continue after you approve the login." }));
    progress.textContent = "Waiting for Nexus approval…"; progress.hidden = false;
    schedulePoll(transaction.interval);
  }
  function schedulePoll(interval) {
    clearTimeout(timer);
    timer = setTimeout(async () => {
      try {
        const answer = await session.poll(controller.signal);
        if (controller.signal.aborted) return;
        if (answer.phase === "active") await finish();
        else if (answer.phase === "pending") schedulePoll(answer.interval);
      } catch (error) { showError(error); }
    }, Math.max(1, interval || 5) * 1000);
  }
  async function begin(flow) {
    if (busy || controller.signal.aborted) return;
    working(true); clearTimeout(timer); alert.hidden = true; device.hidden = true;
    progress.textContent = "Connecting to Nexus…"; progress.hidden = false;
    try {
      const transaction = await session.start(flow, controller.signal);
      if (controller.signal.aborted) return;
      if (flow === "device_code") showDevice(transaction);
    } catch (error) {
      if (error.code === "initialization_required") showSetup(error);
      else showError(error);
    } finally { working(false); }
  }
  async function initialize() {
    if (location.pathname.endsWith("/auth/callback")) {
      working(true); progress.textContent = "Finishing Nexus login…"; progress.hidden = false;
      try { await session.complete(controller.signal); await finish(); }
      catch (error) { showError(error); }
      finally { working(false); }
      return;
    }
    try {
      const status = await call("/auth/status", { signal: controller.signal });
      if (controller.signal.aborted) return;
      nexus.textContent = status.nexus_url || "";
      connect.hidden = !status.flows.includes("authorization_code");
      alternate.hidden = !status.flows.includes("device_code");
      const transaction = session.pending();
      if (transaction?.flow === "device_code") showDevice(transaction);
    } catch (error) { showError(error); }
  }
  return { initialize, destroy };
}
