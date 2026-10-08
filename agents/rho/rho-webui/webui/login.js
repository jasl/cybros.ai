import { t } from "./i18n.js";
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
    catch { throw new Error(t("login.allow_session_storage_in_this_browser_to_sign")); }
    if (flow === "authorization_code") {
      const address = webLink(answer.authorization_url);
      if (!address) { clear(); throw new Error(t("login.nexus_returned_an_invalid_login_address")); }
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
      throw new Error(t("login.this_login_does_not_match_this_browser_tab"));
    }
    if (url.searchParams.has("error")) {
      throw new Error(url.searchParams.get("error") === "access_denied"
        ? t("login.nexus_login_was_not_approved_you_can_start")
        : t("login.nexus_could_not_complete_login_start_a_new"));
    }
    const code = url.searchParams.get("code");
    if (!code) throw new Error(t("login.the_nexus_login_code_is_missing_start_a"));
    // A code exchange is single use. Even an uncertain network failure requires
    // a new login, never an automatic exchange retry after reload.
    return accept(await call("/auth/complete", { method: "POST", signal,
      body: { code, state: transaction.state, login_secret: transaction.login_secret } }));
  }
  function poll(signal) {
    if (polling) return polling;
    const transaction = pending();
    if (!transaction || transaction.flow !== "device_code") throw new Error(t("login.start_a_new_device_login"));
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
  const title = el("h1", { id: "login-title", text: t("common.connect_to_nexus") });
  const description = el("p", { class: "muted", text: t("login.sign_in_with_your_nexus_account_to_use") });
  const nexus = el("p", { class: "faint" });
  const alert = el("p", { class: "bad", role: "alert", hidden: !message, text: message });
  const progress = el("p", { role: "status", hidden: true });
  const device = el("div", { class: "login-device", hidden: true });
  const connect = el("button", { type: "button", class: "primary", text: t("common.connect_to_nexus"), onclick: () => begin("authorization_code") });
  const alternate = el("button", { type: "button", text: t("login.use_a_device_code"), onclick: () => begin("device_code") });
  const actions = el("div", { class: "login-actions" }, connect, alternate);
  root.hidden = false;
  root.replaceChildren(el("main", { class: "login", "aria-labelledby": "login-title" },
    el("p", { class: "login-brand", text: t("brand.rho") }), title, description, nexus, alert, progress, actions, device));

  function destroy() { controller.abort(); clearTimeout(timer); }
  function working(value) { busy = value; connect.disabled = value; alternate.disabled = value; }
  function showError(error) {
    if (controller.signal.aborted || error.name === "AbortError") return;
    alert.textContent = error.message || t("login.could_not_connect_to_nexus_try_again");
    alert.hidden = false; progress.hidden = true;
  }
  async function finish() { destroy(); await onReady(); }
  function showSetup(error) {
    const url = webLink(error.details?.initialization_uri);
    if (!url) { showError(error); return; }
    alert.hidden = true; progress.hidden = true; device.hidden = false;
    const resume = el("button", { type: "button", text: t("login.continue_after_setup"), onclick: async () => {
      resume.disabled = true;
      try { await begin("device_code"); } finally { resume.disabled = false; }
    } });
    device.replaceChildren(el("h2", { text: t("login.create_your_nexus_account_first") }),
      el("p", { text: t("login.open_nexus_setup_in_another_tab_use_the") }),
      el("p", {}, el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: t("login.open_nexus_setup") })), resume);
  }
  function showDevice(transaction) {
    const url = webLink(transaction.verification_uri_complete || transaction.verification_uri);
    if (!url) throw new Error(t("login.nexus_returned_an_invalid_device_login_address"));
    device.hidden = false;
    device.replaceChildren(el("h2", { text: t("login.approve_this_device_login") }),
      el("p", { text: t("login.check_device_code") }),
      el("p", {}, el("strong", { class: "login-code", text: transaction.user_code })),
      el("p", {}, el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: t("login.open_nexus_to_approve") })),
      el("p", { class: "muted", text: t("login.keep_this_tab_open_rho_will_continue_after") }));
    progress.textContent = t("login.waiting_for_nexus_approval"); progress.hidden = false;
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
    progress.textContent = t("login.connecting_to_nexus"); progress.hidden = false;
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
      working(true); progress.textContent = t("login.finishing_nexus_login"); progress.hidden = false;
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
