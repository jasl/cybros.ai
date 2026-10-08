import { t } from "./i18n.js";
// Setup is a projection of the connected services, never a saved wizard step.
export function setupProgress(status, telegram) {
  if (!status?.connected) return { step: "connection", title: t("settings_state.connect_rho_to_nexus"), ready: false };
  const telegramPrompt = telegramSetupPrompt(telegram);
  if (telegramPrompt) return { step: "telegram", title: telegramPrompt, ready: false };
  if (!status.model?.ready) {
    return { step: "model", title: status.model?.eligible?.length ? t("settings_state.choose_your_default_model") : t("settings_state.to_do_configure_a_model_in_nexus"), ready: false };
  }
  return { step: "ready", title: t("common.rho_is_ready_to_use"), ready: true };
}

export function telegramSetupPrompt(telegram) {
  if (telegram === null) return null;
  if (!telegram?.enabled || !telegram.token?.present) return t("settings_state.connect_your_telegram_bot");
  if (!telegram.configuration?.owner_id) return t("settings_state.bind_your_telegram_account");
  return telegram.connection === "running" ? null : t("settings_state.check_your_telegram_connection");
}

// An existing choice always wins. An unavailable choice needs a deliberate
// replacement; catalog order never chooses among several usable models.
export function automaticModel(model) {
  return !model?.default_model && model?.eligible?.length === 1 ? model.eligible[0].ref : null;
}

// The daemon resolves its implicit own Runner and any saved selection. Keep a
// deliberate browser choice, but never guess a default from inventory order.
export function runnerChoice(runners, { current, defaultRunner, edited }) {
  const selected = edited ? current : defaultRunner || runners.find((row) => row.selected)?.public_id || current;
  return runners.find((row) => row.public_id === selected) || null;
}

export function settingsChanges(previous, edited) {
  return Object.fromEntries(Object.entries(edited).filter(([key, value]) => JSON.stringify(value) !== JSON.stringify(previous[key])));
}

export function jsonSetting(text, label) {
  let value;
  try { value = JSON.parse(text); }
  catch { throw new Error(t("settings_state.must_be_valid_json", { label: label })); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(t("settings_state.must_be_a_json_object", { label: label }));
  return value;
}

export function telegramConfiguration({ token, ownerId, enabled, clearToken = false }) {
  const body = { enabled, owner_id: ownerId.trim() || null };
  if (clearToken) body.token = null;
  else if (token.trim()) body.token = token.trim();
  return body;
}

export function webLink(value) {
  try {
    const url = new URL(value);
    return ["https:", "http:"].includes(url.protocol) ? url.href : null;
  } catch { return null; }
}
