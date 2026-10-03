import { el } from "./views.js";
import { automaticModel, setupProgress, verificationLink, webLink } from "./settings_state.js";
import { settingsEditor } from "./settings_editor.js";
import { telegramSettings } from "./telegram_settings.js";

const button = (text, onclick, attrs = {}) => el("button", { type: "button", text, onclick, ...attrs });

export async function settingsSnapshot(call, signal) {
  const [configuration, readiness, daemon] = await Promise.all([
    call("/settings", { signal }), call("/settings/status", { signal }),
    call("/status", { signal }),
  ]);
  const telegram = configuration.extensions.some((extension) => extension.name === "rho.ingress_telegram")
    ? await call("/telegram", { signal }) : null;
  return [configuration, readiness, telegram, daemon];
}

// This panel belongs to the console session, independently of conversation
// navigation. Status reads never replace a form or persist wizard progress.
export function createSettings({ shell, notice, call, onChanged, onError, onUse }) {
  const session = new AbortController();
  let document = null;
  let status = null;
  let telegramDocument = null;
  let connection = null;
  let choices = { runners: [], workspaces: [] };
  let reading = 0;
  let busy = false;
  let pendingPoll = null;
  let modelDirty = false;
  const automaticAttempts = new Set();
  const alert = el("p", { class: "bad", role: "alert", tabindex: "-1", hidden: true });
  const saved = el("p", { class: "settings-saved", role: "status", hidden: true });
  const complete = el("p", { class: "settings-progress", role: "status", text: "rho is ready to use", hidden: true });
  const nexusStatus = el("p", { class: "muted" });
  const device = el("div");
  const connect = button("Connect Nexus", async () => {
    const answer = await write("/device/start", {}, "POST");
    if (answer) { connection = answer; paintConnection(); await refresh(); }
  }, { class: "primary" });
  const connectionSection = el("section", { class: "settings-section", "aria-label": "Nexus connection" },
    el("h3", { text: "1. Connect to Nexus" }), nexusStatus, device, connect);
  const telegram = telegramSettings({ write: async (path, body) => {
    const answer = await write(path, body, "POST");
    if (!answer || path !== "/telegram/configuration") return answer;
    return call("/telegram", { signal: session.signal });
  }, showError,
    changed: async (answer, message) => { telegramDocument = answer; acknowledge(message); await refresh(); } });
  const modelStatus = el("p", { class: "muted" });
  const modelLink = el("div");
  const model = el("select", { name: "default_model", required: true, onchange: () => { modelDirty = true; } });
  const modelSave = el("button", { type: "submit", text: "Save default model" });
  const modelFields = el("fieldset", { class: "settings-fields" }, el("label", {}, "Default model", model), modelSave);
  const modelForm = el("form", { class: "settings-form", onsubmit: async (event) => {
    event.preventDefault(); modelFields.disabled = true;
    try {
      if (await save({ default_model: model.value })) { modelDirty = false; paintModel(); }
    } finally { modelFields.disabled = !status?.connected; }
  } }, modelFields);
  const modelSection = el("section", { class: "settings-section", "aria-label": "Model setup" },
    el("h3", { text: "3. Configure a model in Nexus" }), modelStatus, modelLink,
    el("p", { class: "faint", text: "Add or enable a model in Nexus, then return here. This page checks the available models again when you return. It keeps your saved default, or selects the only eligible model when no default is saved." }), modelForm);
  const defaults = el("p", { class: "faint" });
  const use = button("Start using rho", () => { dialog.close(); onUse(); }, { class: "primary", hidden: true });
  const advanced = settingsEditor({ save, showError });
  const refreshButton = button("Refresh status", () => refresh());
  const dialog = el("dialog", { class: "task-dialog settings-dialog", "aria-labelledby": "settings-title" },
    el("div", { class: "settings-heading" }, el("h2", { id: "settings-title", text: "Settings" }),
      el("div", { class: "settings-actions" }, refreshButton, button("Close", () => dialog.close()))),
    alert, saved, connectionSection, telegram.element, modelSection, defaults, complete, use, advanced.element);
  shell.append(dialog);
  dialog.addEventListener("close", () => { telegram.clearToken(); advanced.clearSecrets(); });
  const alive = () => !session.signal.aborted;

  function showError(error) {
    if (!alive() || error.name === "AbortError") return;
    alert.textContent = error.message || "The request failed. Your changes have not been confirmed. Refresh status before retrying.";
    alert.hidden = false; saved.hidden = true;
    if (dialog.open) alert.focus();
    if (error.status === 401) onError(error);
  }
  function acknowledge(message) {
    alert.hidden = true; saved.textContent = message; saved.hidden = false;
  }
  async function write(path, body, method) {
    if (!alive() || busy) return null;
    busy = true; ++reading;
    const fields = [...dialog.querySelectorAll("fieldset")].map((node) => [node, node.disabled]);
    for (const [node] of fields) node.disabled = true;
    connect.disabled = true; refreshButton.disabled = true;
    try {
      const answer = await call(path, { method, body, signal: session.signal });
      return alive() ? answer : null;
    } catch (error) { showError(error); return null; }
    finally {
      busy = false;
      for (const [node, disabled] of fields) node.disabled = disabled;
      connect.disabled = !!status?.connected; refreshButton.disabled = false;
    }
  }
  async function save(changes) {
    const answer = await write("/settings", changes, "PATCH");
    if (!answer) return null;
    document = answer; advanced.update(document, choices);
    acknowledge("Settings saved and active.");
    await refresh();
    return document;
  }
  function paintConnection() {
    const connected = !!status?.connected;
    nexusStatus.textContent = connected ? "rho is connected to Nexus." : "Connect rho to Nexus to continue.";
    connect.hidden = connected || !!connection?.user_code;
    connect.disabled = connected || busy;
    const url = connection && verificationLink(connection, document?.nexus.public_url, document?.nexus.api_url);
    device.replaceChildren(...(!connected && url ? [el("p", {},
      el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: "Open Nexus and approve this connection" })),
    connection.user_code && el("p", {}, "Connection code: ", el("code", { text: connection.user_code })),
    el("p", { class: "faint", text: "Return here after approving. The connection status updates automatically." })] : []));
    if (!connected && connection?.error) device.append(el("p", { class: "bad", text: connection.error }));
    const pending = !connected && ["starting", "pending", "pending_runner", "activating"].includes(connection?.phase);
    clearTimeout(pendingPoll);
    if (pending && alive()) pendingPoll = setTimeout(() => refresh(), 2000);
  }
  function paintModel() {
    const state = status?.model;
    const rows = state?.eligible || [];
    modelStatus.textContent = state?.ready ? `Default model: ${state.default_model}.`
      : state?.default_model ? `The saved default ${state.default_model} is unavailable. Enable it in Nexus or choose another model.`
        : rows.length ? "Choose a default from the available models." : "To do: add an available text model with tool support in Nexus.";
    const url = webLink(document?.nexus.model_settings_url);
    modelLink.replaceChildren(...(url ? [el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: "Open Nexus model settings" })] : []));
    if (!modelDirty) {
      model.replaceChildren(el("option", { value: "", text: rows.length > 1 ? "Choose a default model" : "No default selected" }),
        ...rows.map((row) => el("option", { value: row.ref, text: row.display_name ? `${row.display_name} · ${row.ref}` : row.ref })));
      if (state?.default_model && !rows.some((row) => row.ref === state.default_model)) {
        model.append(el("option", { value: state.default_model, text: `${state.default_model} · unavailable`, disabled: true }));
      }
      model.value = state?.default_model || "";
    }
    modelFields.disabled = !status?.connected;
    modelSave.disabled = !rows.length;
  }
  function paint() {
    const step = setupProgress(status, telegramDocument);
    notice.replaceChildren(el("span", { text: "Finish setup in Settings." }), button("Open settings", () => open()));
    notice.hidden = step.ready;
    for (const [name, section] of [["connection", connectionSection], ["telegram", telegram.element], ["model", modelSection]]) {
      section.classList.toggle("settings-current", step.step === name);
    }
    use.hidden = !step.ready;
    complete.hidden = !step.ready;
    defaults.textContent = status?.defaults?.tools_ready && status?.defaults?.runner_executor_public_id
      ? "Agent tools and the default runner are ready. Working location and other options are under More settings."
      : "Agent and tool defaults are installed. Runner readiness updates after Nexus connects.";
    paintConnection(); paintModel();
    telegram.update(telegramDocument); advanced.update(document, choices);
  }
  async function refresh({ notify = true } = {}) {
    if (!alive() || busy) return;
    const version = ++reading;
    refreshButton.disabled = true;
    try {
      const [configuration, readiness, telegramState, daemon] = await settingsSnapshot(call, session.signal);
      if (!alive() || version !== reading) return;
      document = configuration; status = readiness; telegramDocument = telegramState; connection = daemon.connection;
      paint();
      const automatic = automaticModel(status.model);
      if (status.connected && automatic && !automaticAttempts.has(automatic)) {
        automaticAttempts.add(automatic);
        const answer = await write("/settings", { default_model: automatic }, "PATCH");
        if (answer) {
          const afterWrite = reading;
          document = answer;
          const readiness = await call("/settings/status", { signal: session.signal });
          if (!alive() || afterWrite !== reading) return;
          status = readiness;
          acknowledge(`Default model selected: ${automatic}.`); paint();
        }
      }
      if (notify) await onChanged(document, status);
    } catch (error) { showError(error); }
    finally { if (alive()) refreshButton.disabled = busy; }
  }
  async function loadChoices() {
    if (!status?.connected) return;
    try {
      const [runners, workspaces] = await Promise.all([
        call("/runners", { signal: session.signal }), call("/workspaces", { signal: session.signal }),
      ]);
      if (!alive()) return;
      choices = { runners: runners.runners, workspaces: workspaces.workspaces };
      advanced.update(document, choices);
    } catch (error) { showError(error); }
  }
  function open() {
    if (!alive()) return;
    if (!dialog.open) dialog.showModal();
    refresh().then(loadChoices);
  }
  window.addEventListener("focus", () => refresh().then(() => { if (dialog.open) return loadChoices(); }), { signal: session.signal });
  return { open, refresh, document: () => document, status: () => status, destroy: () => {
    session.abort(); clearTimeout(pendingPoll); telegram.clearToken(); advanced.clearSecrets(); dialog.close(); dialog.remove();
  } };
}
