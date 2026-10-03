// Setup is a projection of the connected services, never a saved wizard step.
export function setupProgress(status, telegram) {
  if (!status?.connected) return { step: "connection", title: "Connect rho to Nexus", ready: false };
  const telegramPrompt = telegramSetupPrompt(telegram);
  if (telegramPrompt) return { step: "telegram", title: telegramPrompt, ready: false };
  if (!status.model?.ready) {
    return { step: "model", title: status.model?.eligible?.length ? "Choose your default model" : "To do: configure a model in Nexus", ready: false };
  }
  return { step: "ready", title: "rho is ready to use", ready: true };
}

export function telegramSetupPrompt(telegram) {
  if (telegram === null) return null;
  if (!telegram?.enabled || !telegram.token?.present) return "Connect your Telegram bot";
  if (!telegram.configuration?.owner_id) return "Bind your Telegram account";
  return telegram.connection === "running" ? null : "Check your Telegram connection";
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
  catch { throw new Error(`${label} must be valid JSON.`); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be a JSON object.`);
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

export function verificationLink(document, publicUrl, apiUrl) {
  const original = webLink(document.verification_uri);
  const address = webLink(publicUrl);
  if (!original) return null;
  const url = new URL(original);
  if (address) {
    const publicAddress = new URL(address);
    const internalAddress = webLink(apiUrl);
    const basePath = internalAddress ? new URL(internalAddress).pathname.replace(/\/$/, "") : "";
    const route = basePath && url.pathname.startsWith(`${basePath}/`) ? url.pathname.slice(basePath.length) : url.pathname;
    url.protocol = publicAddress.protocol;
    url.host = publicAddress.host;
    url.port = publicAddress.port;
    url.pathname = `${publicAddress.pathname.replace(/\/$/, "")}${route}`;
  }
  if (document.user_code) url.searchParams.set("user_code", document.user_code);
  return url.href;
}
