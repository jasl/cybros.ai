import { t } from "./i18n.js";
import { el } from "./views.js";
import { automaticModel, setupProgress, webLink } from "./settings_state.js";
import { settingsEditor } from "./settings_editor.js";
import { telegramSettings } from "./telegram_settings.js";
import { pluginSettings } from "./plugin_settings.js";
import { pluginSaveMessage } from "./plugin_draft.js";
import { packageSettings } from "./package_settings.js";
import { promptSettings } from "./prompt_settings.js";

const button = (text, onclick, attrs = {}) => el("button", { type: "button", text, onclick, ...attrs });

export async function settingsSnapshot(call, signal) {
  const [configuration, readiness, identity] = await Promise.all([
    call("/settings", { signal }), call("/settings/status", { signal }),
    call("/auth/status", { signal }),
  ]);
  const telegram = configuration.extensions.some((extension) => extension.name === "rho.ingress_telegram")
    ? await call("/telegram", { signal }) : null;
  return [configuration, readiness, telegram, identity];
}

// This panel belongs to the console session, independently of conversation
// navigation. Status reads never replace a form or persist wizard progress.
export function createSettings({ shell, notice, call, onChanged, onError, onUse }) {
  const session = new AbortController();
  let document = null;
  let status = null;
  let telegramDocument = null;
  let identity = null;
  let choices = { runners: [], workspaces: [] };
  let reading = 0;
  let busy = false;
  let modelDirty = false;
  const automaticAttempts = new Set();
  const alert = el("p", { class: "bad", role: "alert", tabindex: "-1", hidden: true });
  const saved = el("p", { class: "settings-saved", role: "status", hidden: true });
  const complete = el("p", { class: "settings-progress", role: "status", text: t("common.rho_is_ready_to_use"), hidden: true });
  const nexusStatus = el("p", { class: "muted" });
  const connectionSection = el("section", { class: "settings-section", "aria-label": t("common.nexus_account") },
    el("h3", { text: t("common.nexus_account") }), nexusStatus);
  const telegram = telegramSettings({ write: async (path, body) => {
    const answer = await write(path, body, "POST");
    if (!answer || path !== "/telegram/configuration") return answer;
    return call("/telegram", { signal: session.signal });
  }, showError, activate: async () => {
    const answer = await write("/extensions/rho.ingress_telegram/enable", {}, "POST");
    if (answer) acknowledge(pluginSaveMessage(answer));
    await refresh();
  },
    changed: async (answer, message) => { telegramDocument = answer; acknowledge(message); await refresh(); } });
  const modelStatus = el("p", { class: "muted" });
  const modelLink = el("div");
  const model = el("select", { name: "default_model", required: true, onchange: () => { modelDirty = true; } });
  const modelSave = el("button", { type: "submit", text: t("settings.save_default_model") });
  const modelFields = el("fieldset", { class: "settings-fields" }, el("label", {}, t("settings.default_model_2"), model), modelSave);
  const modelForm = el("form", { class: "settings-form", onsubmit: async (event) => {
    event.preventDefault(); modelFields.disabled = true;
    try {
      if (await save({ default_model: model.value })) { modelDirty = false; paintModel(); }
    } finally { modelFields.disabled = !status?.connected; }
  } }, modelFields);
  const modelSection = el("section", { class: "settings-section", "aria-label": t("settings.model_setup") },
    el("h3", { text: t("settings.configure_a_model_in_nexus") }), modelStatus, modelLink,
    el("p", { class: "faint", text: t("settings.add_or_enable_a_model_in_nexus_then") }), modelForm);
  const defaults = el("p", { class: "faint" });
  const use = button(t("settings.start_using_rho"), () => { dialog.close(); onUse(); }, { class: "primary", hidden: true });
  const advanced = settingsEditor({ save, showError });
  const prompts = promptSettings({ save, showError });
  const plugins = pluginSettings({ call, signal: session.signal, showError, changed: async () => { await refresh(); } });
  const packages = packageSettings({ call, signal: session.signal, showError, changed: async () => { await refresh(); } });
  const refreshButton = button(t("settings.refresh_status"), () => refresh());
  const dialog = el("dialog", { class: "task-dialog settings-dialog", "aria-labelledby": "settings-title" },
    el("div", { class: "settings-heading" }, el("h2", { id: "settings-title", text: t("common.settings") }),
      el("div", { class: "settings-actions" }, refreshButton, button(t("common.close"), () => dialog.close()))),
    alert, saved, connectionSection, telegram.element, modelSection, defaults, complete, use,
    prompts.element, plugins.element, packages.element, advanced.element);
  shell.append(dialog);
  dialog.addEventListener("close", () => { telegram.clearToken(); advanced.clearSecrets(); plugins.clearSecrets(); packages.clearSecrets(); });
  const alive = () => !session.signal.aborted;

  function showError(error) {
    if (!alive() || error.name === "AbortError") return;
    alert.textContent = error.message || t("settings.the_request_failed_your_changes_have_not_been");
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
    refreshButton.disabled = true;
    try {
      const answer = await call(path, { method, body, signal: session.signal });
      return alive() ? answer : null;
    } catch (error) { showError(error); return null; }
    finally {
      busy = false;
      for (const [node, disabled] of fields) node.disabled = disabled;
      refreshButton.disabled = false;
    }
  }
  async function save(changes) {
    const answer = await write("/settings", changes, "PATCH");
    if (!answer) return null;
    document = answer; advanced.update(document, choices); prompts.update(document);
    acknowledge(t("settings.settings_saved_and_active"));
    await refresh();
    return document;
  }
  function paintConnection() {
    const human = identity?.human;
    nexusStatus.textContent = human
      ? t("settings.signed_in_to_nexus_as", { value1: human.display_name || human.public_id, role: t(`roles.${human.role}`, {}, human.role) })
      : t("settings.your_nexus_session_is_unavailable_sign_out_and");
  }
  function paintModel() {
    const state = status?.model;
    const rows = state?.eligible || [];
    modelStatus.textContent = state?.ready ? t("settings.default_model", { default_model: state.default_model })
      : state?.default_model ? t("settings.the_saved_default_is_unavailable_enable_it_in", { default_model: state.default_model })
        : rows.length ? t("settings.choose_a_default_from_the_available_models") : t("settings.to_do_add_an_available_text_model_with");
    const url = webLink(document?.nexus.model_settings_url);
    modelLink.replaceChildren(...(url ? [el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: t("settings.open_nexus_model_settings") })] : []));
    if (!modelDirty) {
      model.replaceChildren(el("option", { value: "", text: rows.length > 1 ? t("settings.choose_a_default_model") : t("settings.no_default_selected") }),
        ...rows.map((row) => el("option", { value: row.ref, text: row.display_name ? `${row.display_name} · ${row.ref}` : row.ref })));
      if (state?.default_model && !rows.some((row) => row.ref === state.default_model)) {
        model.append(el("option", { value: state.default_model, text: t("common.unavailable_item", { name: state.default_model }), disabled: true }));
      }
      model.value = state?.default_model || "";
    }
    modelFields.disabled = !status?.connected;
    modelSave.disabled = !rows.length;
  }
  function paint() {
    const step = setupProgress(status, telegramDocument);
    notice.replaceChildren(el("span", { text: t("settings.finish_setup_in_settings") }), button(t("settings.open_settings"), () => open()));
    notice.hidden = step.ready;
    for (const [name, section] of [["connection", connectionSection], ["telegram", telegram.element], ["model", modelSection]]) {
      section.classList.toggle("settings-current", step.step === name);
    }
    use.hidden = !step.ready;
    complete.hidden = !step.ready;
    defaults.textContent = status?.defaults?.tools_ready && status?.defaults?.runner_executor_public_id
      ? t("settings.agent_tools_and_the_default_runner_are_ready")
      : t("settings.agent_and_tool_defaults_are_installed_runner_readiness");
    paintConnection(); paintModel();
    telegram.update(telegramDocument, plugins.get("rho.ingress_telegram")); advanced.update(document, choices); prompts.update(document);
  }
  async function refresh({ notify = true } = {}) {
    if (!alive() || busy) return;
    const version = ++reading;
    refreshButton.disabled = true;
    try {
      const [[configuration, readiness, telegramState, humanIdentity]] = await Promise.all([
        settingsSnapshot(call, session.signal), plugins.refresh(), packages.refresh(),
      ]);
      if (!alive() || version !== reading) return;
      document = configuration; status = readiness; telegramDocument = telegramState; identity = humanIdentity;
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
          acknowledge(t("settings.default_model_selected", { automatic: automatic })); paint();
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
    session.abort(); telegram.clearToken(); advanced.clearSecrets(); plugins.clearSecrets(); packages.clearSecrets(); dialog.close(); dialog.remove();
  } };
}
