import { t } from "../kernel/i18n.js";
import { el, safeUrl } from "../kernel/dom.js";
import { icon } from "../primitives/button.js";
import { alert as alertBox } from "../primitives/feedback.js";
import { link } from "../primitives/section.js";

// A daemon that has just started answers 503 `connection_bootstrapping`
// while it checks its stored Agent connection, usually for well under a
// second. A person racing that window is waited through it, as the CLI's
// connect does; bounded, because a daemon stuck there is broken.
const BOOTSTRAP_WAIT = 30_000;
const BOOTSTRAP_POLL = 1000;

// The transaction belongs to the tab that started login. The daemon keeps the
// PKCE verifier; this tab holds the separate secret needed to finish its login.
export function loginSession({ call, storage, credentials, currentUrl, navigate, replace, wait = (ms, signal) => sleep(ms, signal) }) {
  const key = `rho.login.${new URL(currentUrl()).origin}`;
  let polling = null;
  const startRequest = (path, signal) => startRequestWith(path, {}, signal);
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
    const answer = await startRequest(flow === "device_code" ? "/auth/device/start" : "/auth/start", signal);
    const url = new URL(currentUrl());
    const transaction = { ...answer, flow, return_to: url.pathname + url.search };
    try { storage.setItem(key, JSON.stringify(transaction)); }
    catch { throw new Error(t("login.allow_session_storage_in_this_browser_to_sign")); }
    if (flow === "authorization_code") {
      const address = safeUrl(answer.authorization_url);
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
  // One attempt at rho's own gate: no password in `open` mode, the unlock
  // password in `password` mode. The daemon answers with the page's bearer.
  async function unlock(password, signal) {
    clear();
    const body = password === undefined ? {} : { password };
    return accept(await startRequestWith("/auth/unlock", body, signal));
  }
  async function startRequestWith(path, body, signal) {
    const deadline = Date.now() + BOOTSTRAP_WAIT;
    for (;;) {
      try { return await call(path, { method: "POST", body, signal }); }
      catch (error) {
        if (error.code !== "connection_bootstrapping" || Date.now() >= deadline) throw error;
        await wait(BOOTSTRAP_POLL, signal);
      }
    }
  }
  return { start, complete, pending, poll, clear, unlock };
}

// Start a Nexus sign-in from inside the page — a page an unlock admitted
// asks for one when it needs its Nexus account. The callback is finished by
// the login page, as every sign-in is.
export function startNexusLogin({ call, credentials }) {
  const session = loginSession({ call, credentials, storage: sessionStorage,
    currentUrl: () => location.href, navigate: (url) => location.assign(url),
    replace: (url) => history.replaceState(null, "", url) });
  return session.start("authorization_code");
}

function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(Object.assign(new Error("aborted"), { name: "AbortError" })); return; }
    const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); resolve(); }, ms);
    function abort() { clearTimeout(timer); reject(Object.assign(new Error("aborted"), { name: "AbortError" })); }
    signal?.addEventListener("abort", abort, { once: true });
  });
}

export function createLogin({ root, call, credentials, onReady, message = "" }) {
  const controller = new AbortController();
  const session = loginSession({ call, credentials, storage: sessionStorage,
    currentUrl: () => location.href, navigate: (url) => location.assign(url),
    replace: (url) => history.replaceState(null, "", url) });
  let timer = null;
  let busy = false;
  const title = el("h1", { id: "login-title", class: "login__title", text: t("common.connect_to_nexus") });
  const description = el("p", { class: "login__description", text: t("login.sign_in_with_your_nexus_account_to_use") });
  const nexus = el("p", { class: "login__nexus mono", hidden: true });
  const alert = alertBox({ tone: "error", text: message, hidden: !message });
  const progress = el("p", { class: "login__progress", role: "status", hidden: true });
  const device = el("div", { class: "login__device", hidden: true });
  const connect = el("button", { type: "button", class: "btn btn--primary btn--md btn--block", text: t("common.connect_to_nexus"), onclick: () => begin("authorization_code") });
  const alternate = el("button", { type: "button", class: "btn btn--secondary btn--md btn--block", text: t("login.use_a_device_code"), onclick: () => begin("device_code") });
  const actions = el("div", { class: "login__actions" }, connect, alternate);
  // The password gate: the field, Unlock, and a way to the Nexus sign-in instead.
  const password = el("input", { class: "control", type: "password", name: "unlock_password", autocomplete: "current-password",
    "aria-label": t("login.unlock_password"), placeholder: t("login.unlock_password") });
  const unlockButton = el("button", { type: "submit", class: "btn btn--primary btn--md btn--block", text: t("login.unlock") });
  const instead = el("button", { type: "button", class: "btn btn--ghost btn--sm", text: t("login.sign_in_with_nexus_instead"),
    onclick: () => { gate.hidden = true; actions.hidden = false; title.textContent = t("common.connect_to_nexus"); description.textContent = t("login.sign_in_with_your_nexus_account_to_use"); } });
  const gate = el("form", { class: "login__gate", hidden: true, onsubmit: async (event) => {
    event.preventDefault();
    await admit(password.value);
  } }, password, unlockButton, instead);
  root.hidden = false;
  root.replaceChildren(el("main", { class: "login", "aria-labelledby": "login-title" },
    el("div", { class: "login__brand" }, el("span", { class: "mark mark--lg" }, icon("rho")), el("span", { class: "login__wordmark", text: t("brand.rho") })),
    title, description, nexus, alert.element, progress, actions, gate, device,
    el("p", { class: "login__description", text: t("connection.local_import") })));

  function destroy() { controller.abort(); clearTimeout(timer); }
  function working(value) { busy = value; connect.disabled = value; alternate.disabled = value; unlockButton.disabled = value; password.disabled = value; }
  function showError(error) {
    if (controller.signal.aborted || error.name === "AbortError") return;
    alert.show(error.message || t("login.could_not_connect_to_nexus_try_again"));
    progress.hidden = true;
  }
  async function finish() { destroy(); await onReady(); }
  function showSetup(error) {
    const url = safeUrl(error.details?.initialization_uri);
    if (!url) { showError(error); return; }
    alert.hide(); progress.hidden = true; device.hidden = false;
    const resume = el("button", { type: "button", class: "btn btn--secondary btn--sm", text: t("login.continue_after_setup"), onclick: async () => {
      resume.disabled = true;
      try { await begin("device_code"); } finally { resume.disabled = false; }
    } });
    device.replaceChildren(el("h2", { class: "login__device-title", text: t("login.create_your_nexus_account_first") }),
      el("p", { class: "text-secondary", text: t("login.open_nexus_setup_in_another_tab_use_the") }),
      el("p", {}, link({ href: url, text: t("login.open_nexus_setup") })), resume);
  }
  function showDevice(transaction) {
    const url = safeUrl(transaction.verification_uri_complete || transaction.verification_uri);
    if (!url) throw new Error(t("login.nexus_returned_an_invalid_device_login_address"));
    device.hidden = false;
    device.replaceChildren(el("h2", { class: "login__device-title", text: t("login.approve_this_device_login") }),
      el("p", { class: "text-secondary", text: t("login.check_device_code") }),
      el("p", {}, el("strong", { class: "login__code", text: transaction.user_code })),
      el("p", {}, link({ href: url, text: t("login.open_nexus_to_approve") })),
      el("p", { class: "text-tertiary", text: t("login.keep_this_tab_open_rho_will_continue_after") }));
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
  // Through rho's own gate: by itself in `open` mode, with the password in
  // `password` mode. A refusal is shown where the password was typed.
  async function admit(secret) {
    if (busy || controller.signal.aborted) return;
    working(true); alert.hide();
    progress.textContent = t("login.opening_rho"); progress.hidden = false;
    try {
      await session.unlock(secret, controller.signal);
      if (controller.signal.aborted) return;
      await finish();
    } catch (error) {
      showError(error);
      password.value = "";
      if (!gate.hidden) password.focus();
    } finally { working(false); }
  }
  function showGate() {
    title.textContent = t("login.unlock_rho");
    description.textContent = t("login.enter_the_unlock_password");
    actions.hidden = true;
    gate.hidden = false;
    password.focus();
  }
  // A Nexus sign-in leaves this page for Nexus; its buttons stay off while
  // the browser goes, so a second click cannot start a rival transaction. A
  // page the browser brings back is rebuilt (`pageshow`), buttons and all.
  async function begin(flow) {
    if (busy || controller.signal.aborted) return;
    working(true); clearTimeout(timer); alert.hide(); device.hidden = true;
    progress.textContent = t("login.connecting_to_nexus"); progress.hidden = false;
    let leaving = false;
    try {
      const transaction = await session.start(flow, controller.signal);
      if (controller.signal.aborted) return;
      if (flow === "device_code") showDevice(transaction); else leaving = true;
    } catch (error) {
      if (error.code === "initialization_required") showSetup(error);
      else showError(error);
    } finally { if (!leaving) working(false); }
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
      nexus.textContent = status.nexus_url ? t("login.nexus_address", { url: status.nexus_url }) : "";
      nexus.hidden = !status.nexus_url;
      connect.hidden = !status.flows.includes("authorization_code");
      alternate.hidden = !status.flows.includes("device_code");
      const transaction = session.pending();
      if (transaction?.flow === "device_code") { showDevice(transaction); return; }
      // Pairing comes first; after it the gate decides what a browser needs.
      const mode = status.paired ? status.access?.mode : "nexus";
      if (mode === "open") await admit(undefined);
      else if (mode === "password") showGate();
    } catch (error) { showError(error); }
  }
  return { initialize, destroy };
}
