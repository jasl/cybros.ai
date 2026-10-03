import { el } from "./views.js";
import { webLink } from "./settings_state.js";

// The installation has no saved wizard step. Account setup comes from the
// installer; pairing readiness comes from the daemon's ordinary authority read.
export function installationStage(installation, daemon) {
  if (!installation.enabled) return "ready";
  if (installation.password_required) return "password";
  const planes = daemon?.authority?.planes;
  if (["member", "executor_transport", "runner_transport"].every((plane) => planes?.[plane] === "live") &&
      daemon?.identity?.executor_public_id && daemon.identity.runner_executor_public_id) return "ready";
  if (installation.error) return "error";
  if (installation.nexus_ready === false) return "account";
  return installation.nexus_ready === true ? "pairing" : "waiting";
}

export async function installationSnapshot(call, signal) {
  const installation = await call("/installation", { signal });
  const daemon = installation.enabled && !installation.password_required ? await call("/status", { signal }) : null;
  return [installation, daemon];
}

export async function saveInstallationPassword(call, password, confirmation, signal) {
  if (password.length < 8) throw new Error("Use at least 8 characters for your rho password.");
  if (password !== confirmation) throw new Error("The passwords do not match.");
  return call("/settings", { method: "PATCH", body: { access_passphrase: password }, signal });
}

export function createInstallation({ root, call, onReady, onError }) {
  const session = new AbortController();
  let reading = false;
  let saving = false;
  let poll = null;
  let revision = 0;
  let passwordError = null;
  let installation = null;
  let stage = "waiting";
  let guided = false;
  const title = el("h1", { id: "installation-title", tabindex: "-1", text: "Starting your installation" });
  const description = el("p", { class: "muted", text: "Checking your installation…", role: "status" });
  const alert = el("p", { class: "bad", role: "alert", tabindex: "-1", hidden: true });
  const password = el("input", { id: "installation-password", name: "password", type: "password", autocomplete: "new-password", required: true, minlength: 8 });
  const confirmation = el("input", { id: "installation-confirmation", name: "confirmation", type: "password", autocomplete: "new-password", required: true, minlength: 8 });
  for (const input of [password, confirmation]) input.addEventListener("input", () => {
    if (passwordError) { passwordError = null; alert.hidden = true; }
  });
  const fields = el("fieldset", { class: "settings-fields" },
    el("label", { for: "installation-password", text: "rho password" }, password),
    el("label", { for: "installation-confirmation", text: "Confirm rho password" }, confirmation),
    el("button", { type: "submit", class: "primary", text: "Save password and continue" }));
  const form = el("form", { class: "installation-form", hidden: true, onsubmit: savePassword }, fields);
  const setup = el("a", { class: "installation-link", text: "Open Nexus setup", target: "_blank", rel: "noopener noreferrer", hidden: true });
  const help = el("p", { class: "faint", hidden: true }, "If setup does not continue, run ", el("code", { text: "./cybros up" }),
    " in your installation directory, then retry. You can also connect through Settings.");
  const retry = el("button", { type: "button", text: "Refresh status", onclick: () => refresh() });
  const manual = el("button", { type: "button", text: "Open Settings instead", hidden: true,
    onclick: () => finish(true) });
  const actions = el("div", { class: "installation-actions" }, retry, manual);
  const page = el("main", { class: "installation", "aria-labelledby": "installation-title" },
    el("p", { class: "installation-brand", text: "rho" }), title, description, alert, form, setup, help, actions);
  root.hidden = false;
  root.replaceChildren(page);

  function destroy() {
    session.abort(); clearTimeout(poll);
    password.value = ""; confirmation.value = ""; setup.removeAttribute("href");
  }
  function finish(openSettings) {
    destroy(); onReady({ openSettings });
  }
  function showError(error) {
    if (session.signal.aborted || error.name === "AbortError") return;
    if (error.status === 401) { destroy(); onError(error); return; }
    alert.textContent = error.message || "Could not check your installation. Try again.";
    alert.hidden = false;
    help.hidden = false;
    manual.hidden = installation?.password_required === true;
  }
  function paint(document, daemon) {
    const next = installationStage(document, daemon);
    const changed = next !== stage;
    stage = next;
    if (stage === "ready") { finish(guided); return; }
    guided = true;
    const labels = {
      password: ["Set your rho password", "Choose a password with at least 8 characters to open rho on this device. You will create your Nexus account next."],
      account: ["Create your Nexus account", "Open Nexus in a new tab to create your account. Return here afterward; rho will connect automatically."],
      pairing: ["Connecting rho to Nexus", "Your Nexus account is ready. Waiting for the Agent and its Runner to connect…"],
      waiting: ["Starting your installation", "Waiting for Nexus setup to become available. This page checks automatically."],
      error: ["Installation needs attention", "Your settings are saved. Check the installation and try again."],
    };
    [title.textContent, description.textContent] = labels[stage];
    form.hidden = stage !== "password";
    // Keep the form and its typed values alive across status/focus refreshes.
    const url = stage === "account" ? webLink(document.setup_url) : null;
    setup.hidden = !url;
    if (url) setup.href = url; else setup.removeAttribute("href");
    help.hidden = stage === "password";
    manual.hidden = stage === "password";
    if (document.error) showError(new Error(document.error));
    if (changed) { title.focus({ preventScroll: true }); window.scrollTo(0, 0); }
  }
  async function savePassword(event) {
    event.preventDefault();
    if (saving || session.signal.aborted) return;
    saving = true; ++revision; fields.disabled = true; retry.disabled = true; clearTimeout(poll);
    passwordError = null; alert.hidden = true;
    try {
      await saveInstallationPassword(call, password.value, confirmation.value, session.signal);
      password.value = ""; confirmation.value = "";
      if (session.signal.aborted) return;
      // The settings writer confirmed this fact even if the following helper
      // read is temporarily unavailable. Do not ask to save the password again.
      installation = { ...installation, password_required: false };
      paint(installation, null);
    } catch (error) {
      passwordError = error.message;
      showError(error); if (!session.signal.aborted) alert.focus();
      return;
    } finally {
      saving = false; fields.disabled = false; retry.disabled = false;
      if (!session.signal.aborted) poll = setTimeout(() => refresh(), 2000);
    }
    await refresh();
  }
  async function refresh() {
    if (session.signal.aborted || reading || saving) return;
    reading = true; retry.disabled = true; clearTimeout(poll);
    const version = revision;
    try {
      const [document, daemon] = await installationSnapshot(call, session.signal);
      if (session.signal.aborted || saving || version !== revision) return;
      installation = document;
      alert.hidden = !passwordError;
      if (passwordError) alert.textContent = passwordError;
      paint(document, daemon);
    } catch (error) { showError(error); }
    finally {
      reading = false; retry.disabled = saving;
      if (!session.signal.aborted && !saving) poll = setTimeout(() => refresh(), 2000);
    }
  }
  window.addEventListener("focus", () => refresh(), { signal: session.signal });
  return { refresh, destroy };
}
