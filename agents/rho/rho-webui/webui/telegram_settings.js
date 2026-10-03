import { el } from "./views.js";
import { telegramConfiguration, telegramSetupPrompt, webLink } from "./settings_state.js";

const button = (text, onclick, attrs = {}) => el("button", { type: "button", text, onclick, ...attrs });
const field = (text, input) => el("label", {}, text, input);
const lists = [["allowed_users", "Allowed people"], ["allowed_chats", "Allowed groups"], ["ignored_users", "Ignored people"]];

export function telegramSettings({ write, changed, showError }) {
  let observed = null;
  let dirty = false;
  let optionsDirty = false;
  const guidance = el("p", { class: "settings-progress", role: "status", hidden: true });
  const status = el("p", { class: "muted", role: "status" });
  const botLink = el("div");
  const token = el("input", { name: "token", type: "password", autocomplete: "new-password", spellcheck: "false" });
  const tokenHint = el("p", { class: "faint" });
  const clearToken = el("input", { type: "checkbox", onchange: () => { token.disabled = clearToken.checked; } });
  const clearTokenField = el("label", { class: "check", hidden: true }, clearToken, "Clear the saved token and use the environment fallback");
  const owner = el("input", { name: "owner_id", inputmode: "numeric", pattern: "[0-9]+", placeholder: "Your numeric Telegram user ID" });
  const enabled = el("input", { name: "enabled", type: "checkbox" });
  const save = el("button", { type: "submit", class: "primary", text: "Verify and save Telegram" });
  const fields = el("fieldset", { class: "settings-fields" },
    field("Bot token", token), tokenHint, clearTokenField,
    el("p", { class: "faint", text: "To clear a saved token without an environment fallback, also turn off Enable Telegram before saving." }),
    field("Bot owner user ID", owner),
    el("p", { class: "faint", text: "You can leave the owner blank first. Save the token, open your bot and send /start to get your user ID, then enter it here. No model is needed." }),
    el("label", { class: "check" }, enabled, "Enable Telegram"), save);
  const form = el("form", { class: "settings-form", oninput: () => { dirty = true; }, onsubmit: async (event) => {
    event.preventDefault();
    fields.disabled = true;
    try {
      const body = telegramConfiguration({ token: token.value, ownerId: owner.value, enabled: enabled.checked, clearToken: clearToken.checked });
      const answer = await write("/telegram/configuration", body);
      if (!answer) return;
      token.value = ""; clearToken.checked = false; dirty = false;
      update(answer);
      await changed(answer, "Telegram settings are active.");
    } catch (error) { showError(error); }
    finally { fields.disabled = false; }
  } }, fields);

  const stale = el("input", { type: "number", name: "stale_after", min: 1, step: 1, required: true });
  const transcription = el("input", { name: "transcription_model", placeholder: "provider/model (optional)" });
  const speech = el("input", { name: "speech_model", placeholder: "provider/model (optional)" });
  const tokenEnv = el("input", { name: "token_env", placeholder: "RHO_TELEGRAM_BOT_TOKEN" });
  const optionsFields = el("fieldset", { class: "settings-fields" },
    field("Ignore messages older than (seconds)", stale),
    field("Transcription model", transcription), field("Speech model", speech), field("Token environment variable", tokenEnv),
    el("p", { class: "faint", text: "Audio models are optional. A saved token takes precedence; the environment is used when no token is saved." }),
    el("button", { type: "submit", text: "Save Telegram options" }));
  const options = el("form", { class: "settings-form", oninput: () => { optionsDirty = true; }, onsubmit: async (event) => {
    event.preventDefault(); optionsFields.disabled = true;
    try {
      const answer = await write("/telegram/configuration", { stale_after: Number(stale.value),
        transcription_model: transcription.value.trim(), speech_model: speech.value.trim(),
        token_env: tokenEnv.value.trim() || "RHO_TELEGRAM_BOT_TOKEN" });
      if (!answer) return;
      optionsDirty = false; update(answer); await changed(answer, "Telegram options are active.");
    } catch (error) { showError(error); }
    finally { optionsFields.disabled = false; }
  } }, optionsFields);

  const accessStatus = el("p", { class: "muted" });
  const accessRows = el("div", { class: "settings-access" });
  const list = el("select", { name: "list" }, ...lists.map(([value, text]) => el("option", { value, text })));
  const id = el("input", { name: "id", inputmode: "numeric", pattern: "-?[0-9]+", required: true, placeholder: "Numeric user or group ID" });
  const accessFields = el("fieldset", { class: "settings-fields" }, field("Access list", list), field("Telegram ID", id),
    el("button", { type: "submit", text: "Add to list" }));
  const accessForm = el("form", { class: "settings-form", onsubmit: async (event) => {
    event.preventDefault();
    if (await changeAccess(list.value, "add", id.value.trim())) id.value = "";
  } }, accessFields);
  const setup = el("div", {},
    el("p", {}, "Create a bot with ", el("a", { href: "https://t.me/BotFather", target: "_blank", rel: "noopener noreferrer", text: "@BotFather" }),
      " in Telegram, then paste its token here."), botLink, form,
    el("details", { class: "settings-details" }, el("summary", { text: "Telegram options and access" }), options,
      el("h4", { text: "People and groups" }),
      el("p", { class: "faint", text: "The bot owner is always allowed. Group IDs may be negative. You can also manage access with /access and /ignore in a private chat with the bot." }),
      accessStatus, accessRows, accessForm));
  const element = el("section", { class: "settings-section", "aria-label": "Telegram setup" },
    el("h3", { text: "2. Connect and pair Telegram" }), guidance, status, setup);

  async function changeAccess(name, action, value) {
    accessFields.disabled = true;
    for (const control of accessRows.querySelectorAll("button")) control.disabled = true;
    try {
      const answer = await write("/telegram/access", { list: name, action, id: value });
      if (!answer) return false;
      update(answer); await changed(answer, "Telegram access updated.");
      return true;
    } catch (error) { showError(error); return false; }
    finally { if (observed) renderAccess(observed); }
  }

  function renderAccess(document) {
    accessRows.replaceChildren();
    accessFields.disabled = !document.access;
    accessStatus.textContent = document.access ? "" : "Access lists become available after Telegram connects to Nexus.";
    if (!document.access) return;
    for (const [name, label] of lists) {
      const values = document.access[name] || [];
      const rows = values.map((value) => el("li", {}, el("code", { text: value }),
        button("Remove", () => changeAccess(name, "remove", value), { "aria-label": `Remove ${value} from ${label.toLowerCase()}` })));
      accessRows.append(el("div", {}, el("h5", { text: label }), rows.length ? el("ul", {}, rows) : el("p", { class: "faint", text: "None" })));
    }
  }

  function update(document) {
    observed = document;
    const prompt = telegramSetupPrompt(document);
    guidance.textContent = prompt || "";
    guidance.hidden = !prompt;
    setup.hidden = document === null;
    if (document === null) {
      status.textContent = "Telegram is unavailable in this installation. Install rho-ingress-telegram to use this channel. Model and agent settings remain available.";
      return;
    }
    const config = document.configuration || {};
    status.textContent = !document.enabled ? "Telegram is not enabled." : document.connection === "running"
      ? config.owner_id ? "Telegram is connected and the owner is configured." : "Bot connected. Bind your user ID to accept agent messages."
      : `Telegram: ${document.connection || "starting"}. Use Refresh status to check again.`;
    const username = document.bot?.username;
    const url = username && webLink(`https://t.me/${encodeURIComponent(username)}`);
    botLink.replaceChildren(...(url ? [el("p", {}, el("a", { href: url, target: "_blank", rel: "noopener noreferrer", text: `Open @${username}` }),
      " and send /start to see your user ID.")] : []));
    tokenHint.textContent = document.token?.source === "environment"
      ? "The environment supplies the current token. Save a token here to replace that default."
      : document.token?.present ? "A token is saved. Leave this field blank to keep it." : "Your token is only sent when you save; it is never shown again.";
    clearTokenField.hidden = document.token?.source !== "saved";
    if (clearTokenField.hidden) clearToken.checked = false;
    token.disabled = clearToken.checked;
    if (!dirty) {
      owner.value = config.owner_id || "";
      enabled.checked = document.enabled || !document.token?.present;
    }
    if (!optionsDirty) {
      stale.value = config.stale_after || 600;
      transcription.value = config.transcription_model || "";
      speech.value = config.speech_model || "";
      tokenEnv.value = config.token_env || "RHO_TELEGRAM_BOT_TOKEN";
    }
    save.textContent = document.token?.present && !token.value ? "Save Telegram" : "Verify and save Telegram";
    renderAccess(document);
  }

  return { element, update, clearToken: () => { token.value = ""; clearToken.checked = false; token.disabled = false; } };
}
