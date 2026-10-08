import { statusText, t } from "./i18n.js";
import { el } from "./views.js";
import { telegramConfiguration, telegramSetupPrompt, webLink } from "./settings_state.js";

const button = (text, onclick, attrs = {}) => el("button", { type: "button", text, onclick, ...attrs });
const field = (text, input) => el("label", {}, text, input);
const lists = [["allowed_users", t("telegram_settings.allowed_people")], ["allowed_chats", t("telegram_settings.allowed_groups")], ["ignored_users", t("telegram_settings.ignored_people")]];

export function telegramSettings({ write, activate, changed, showError }) {
  let observed = null;
  let observedPlugin = null;
  let dirty = false;
  let optionsDirty = false;
  let activating = false;
  const guidance = el("p", { class: "settings-progress", role: "status", hidden: true });
  const status = el("p", { class: "muted", role: "status" });
  const issues = el("p", { class: "plugin-issues bad", role: "status", hidden: true });
  const enablePlugin = button(t("common.enable_telegram"), async () => {
    if (activating) return;
    activating = true; enablePlugin.disabled = true;
    enablePlugin.textContent = t("telegram_settings.enabling_telegram");
    try { await activate(); } catch (error) { showError(error); }
    finally {
      activating = false; update(observed, observedPlugin);
    }
  }, { class: "primary", hidden: true });
  const botLink = el("div");
  const token = el("input", { name: "token", type: "password", autocomplete: "new-password", spellcheck: "false" });
  const tokenHint = el("p", { class: "faint" });
  const clearToken = el("input", { type: "checkbox", onchange: () => { token.disabled = clearToken.checked; } });
  const clearTokenField = el("label", { class: "check", hidden: true }, clearToken, t("telegram_settings.clear_the_saved_token_and_use_the_environment"));
  const owner = el("input", { name: "owner_id", inputmode: "numeric", pattern: "[0-9]+", placeholder: t("telegram_settings.your_numeric_telegram_user_id") });
  const enabled = el("input", { name: "enabled", type: "checkbox" });
  const save = el("button", { type: "submit", class: "primary", text: t("common.verify_and_save_telegram") });
  const fields = el("fieldset", { class: "settings-fields" },
    field(t("telegram_settings.bot_token"), token), tokenHint, clearTokenField,
    el("p", { class: "faint", text: t("telegram_settings.clearing_the_token_uses_the_environment_fallback_when") }),
    field(t("telegram_settings.bot_owner_user_id"), owner),
    el("p", { class: "faint", text: t("telegram_settings.you_can_leave_the_owner_blank_first_save") }),
    el("label", { class: "check" }, enabled, t("common.enable_telegram")), save);
  const form = el("form", { class: "settings-form", oninput: () => { dirty = true; }, onsubmit: async (event) => {
    event.preventDefault();
    fields.disabled = true;
    try {
      const body = telegramConfiguration({ token: token.value, ownerId: owner.value, enabled: enabled.checked, clearToken: clearToken.checked });
      const answer = await write("/telegram/configuration", body);
      if (!answer) return;
      token.value = ""; clearToken.checked = false; dirty = false;
      update(answer);
      await changed(answer, t("telegram_settings.telegram_settings_are_active"));
    } catch (error) { showError(error); }
    finally { fields.disabled = false; }
  } }, fields);

  const stale = el("input", { type: "number", name: "stale_after", min: 1, step: 1, required: true });
  const debounce = el("input", { type: "number", name: "input_debounce_seconds", min: 0, max: 10, step: 1, required: true });
  const transcription = el("input", { name: "transcription_model", placeholder: t("telegram_settings.optional_model") });
  const speech = el("input", { name: "speech_model", placeholder: t("telegram_settings.optional_model") });
  const tokenEnv = el("input", { name: "token_env", placeholder: "RHO_TELEGRAM_BOT_TOKEN" });
  const optionsFields = el("fieldset", { class: "settings-fields" },
    field(t("telegram_settings.ignore_messages_older_than_seconds"), stale),
    field(t("telegram_settings.message_grouping_delay_seconds"), debounce),
    el("p", { class: "faint", text: t("telegram_settings.message_grouping_help") }),
    field(t("telegram_settings.transcription_model"), transcription), field(t("telegram_settings.speech_model"), speech), field(t("telegram_settings.token_environment_variable"), tokenEnv),
    el("p", { class: "faint", text: t("telegram_settings.audio_models_are_optional_a_saved_token_takes") }),
    el("button", { type: "submit", text: t("telegram_settings.save_telegram_options") }));
  const options = el("form", { class: "settings-form", oninput: () => { optionsDirty = true; }, onsubmit: async (event) => {
    event.preventDefault(); optionsFields.disabled = true;
    try {
      const answer = await write("/telegram/configuration", { stale_after: Number(stale.value),
        input_debounce_seconds: Number(debounce.value),
        transcription_model: transcription.value.trim(), speech_model: speech.value.trim(),
        token_env: tokenEnv.value.trim() || "RHO_TELEGRAM_BOT_TOKEN" });
      if (!answer) return;
      optionsDirty = false; update(answer); await changed(answer, t("telegram_settings.telegram_options_are_active"));
    } catch (error) { showError(error); }
    finally { optionsFields.disabled = false; }
  } }, optionsFields);

  const accessStatus = el("p", { class: "muted" });
  const accessRows = el("div", { class: "settings-access" });
  const list = el("select", { name: "list" }, ...lists.map(([value, text]) => el("option", { value, text })));
  const id = el("input", { name: "id", inputmode: "numeric", pattern: "-?[0-9]+", required: true, placeholder: t("telegram_settings.numeric_user_or_group_id") });
  const accessFields = el("fieldset", { class: "settings-fields" }, field(t("telegram_settings.access_list"), list), field(t("telegram_settings.telegram_id"), id),
    el("button", { type: "submit", text: t("telegram_settings.add_to_list") }));
  const accessForm = el("form", { class: "settings-form", onsubmit: async (event) => {
    event.preventDefault();
    if (await changeAccess(list.value, "add", id.value.trim())) id.value = "";
  } }, accessFields);
  const setup = el("div", {},
    el("p", { text: t("telegram_settings.create_a_bot") }),
    el("p", {}, el("a", { href: "https://t.me/BotFather", target: "_blank", rel: "noopener noreferrer", text: t("telegram_settings.open_botfather") })), botLink, form,
    el("details", { class: "settings-details" }, el("summary", { text: t("telegram_settings.telegram_options_and_access") }), options,
      el("h4", { text: t("telegram_settings.people_and_groups") }),
      el("p", { class: "faint", text: t("telegram_settings.the_bot_owner_is_always_allowed_group_ids") }),
      accessStatus, accessRows, accessForm));
  const element = el("section", { class: "settings-section", "aria-label": t("telegram_settings.telegram_setup") },
    el("h3", { text: t("telegram_settings.connect_and_pair_telegram") }), guidance, status, issues, enablePlugin, setup);

  async function changeAccess(name, action, value) {
    accessFields.disabled = true;
    for (const control of accessRows.querySelectorAll("button")) control.disabled = true;
    try {
      const answer = await write("/telegram/access", { list: name, action, id: value });
      if (!answer) return false;
      update(answer); await changed(answer, t("telegram_settings.telegram_access_updated"));
      return true;
    } catch (error) { showError(error); return false; }
    finally { if (observed) renderAccess(observed); }
  }

  function renderAccess(document) {
    accessRows.replaceChildren();
    accessFields.disabled = !document.access;
    accessStatus.textContent = document.access ? "" : t("telegram_settings.access_lists_become_available_after_telegram_connects_to");
    if (!document.access) return;
    for (const [name, label] of lists) {
      const values = document.access[name] || [];
      const rows = values.map((value) => el("li", {}, el("code", { text: value }),
        button(t("telegram_settings.remove"), () => changeAccess(name, "remove", value), { "aria-label": t("telegram_settings.remove_from", { value: value, value2: label.toLowerCase() }) })));
      accessRows.append(el("div", {}, el("h5", { text: label }), rows.length ? el("ul", {}, rows) : el("p", { class: "faint", text: t("common.none") })));
    }
  }

  function update(document, plugin = observedPlugin) {
    observed = document;
    observedPlugin = plugin;
    const prompt = telegramSetupPrompt(document);
    guidance.textContent = prompt || "";
    guidance.hidden = !prompt;
    setup.hidden = document === null;
    enablePlugin.hidden = document !== null || !plugin;
    enablePlugin.disabled = activating || plugin?.configurable === false;
    enablePlugin.textContent = activating ? t("telegram_settings.enabling_telegram")
      : plugin?.enabled ? t("telegram_settings.retry_telegram") : t("common.enable_telegram");
    // Once activated, the setup form explains the ordinary token/owner steps.
    // Plugin readiness belongs here only when activation has not produced that form.
    const activationIssues = document === null ? plugin?.readiness?.issues || [] : [];
    issues.textContent = [...(plugin?.configuration?.diagnostics || []), ...activationIssues]
      .map((issue) => typeof issue === "string" ? issue : issue.message || issue.reason || issue.code).filter(Boolean).join("\n");
    issues.hidden = !issues.textContent;
    if (document === null) {
      status.textContent = !plugin
        ? t("telegram_settings.install_rho_ingress_telegram_to_connect_your_telegram")
        : plugin.enabled ? t("telegram_settings.activation_incomplete")
          : t("telegram_settings.enable_telegram_here_then_enter_your_bot_token");
      return;
    }
    const config = document.configuration || {};
    status.textContent = !document.enabled ? t("telegram_settings.telegram_is_not_enabled") : !document.token?.present
      ? t("telegram_settings.save_a_bot_token_to_start_telegram_polling") : document.connection === "running"
      ? config.owner_id ? t("telegram_settings.telegram_is_connected_and_the_owner_is_configured") : t("telegram_settings.bot_connected_bind_your_user_id_to_accept")
      : t("telegram_settings.telegram_use_refresh_status_to_check_again", { value1: statusText(document.connection || "starting") });
    const username = document.bot?.username;
    const url = username && webLink(`https://t.me/${encodeURIComponent(username)}`);
    botLink.replaceChildren(...(url ? [el("p", {}, el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: t("telegram_settings.open_and_find_user_id", { username }) }))] : []));
    tokenHint.textContent = document.token?.source === "environment"
      ? t("telegram_settings.the_environment_supplies_the_current_token_save_a")
      : document.token?.present ? t("telegram_settings.a_token_is_saved_leave_this_field_blank") : t("telegram_settings.your_token_is_only_sent_when_you_save");
    clearTokenField.hidden = document.token?.source !== "saved";
    if (clearTokenField.hidden) clearToken.checked = false;
    token.disabled = clearToken.checked;
    if (!dirty) {
      owner.value = config.owner_id || "";
      enabled.checked = document.enabled || !document.token?.present;
    }
    if (!optionsDirty) {
      stale.value = config.stale_after || 600;
      debounce.value = config.input_debounce_seconds ?? 2;
      transcription.value = config.transcription_model || "";
      speech.value = config.speech_model || "";
      tokenEnv.value = config.token_env || "RHO_TELEGRAM_BOT_TOKEN";
    }
    save.textContent = document.token?.present && !token.value ? t("telegram_settings.save_telegram") : t("common.verify_and_save_telegram");
    renderAccess(document);
  }

  return { element, update, clearToken: () => { token.value = ""; clearToken.checked = false; token.disabled = false; } };
}
