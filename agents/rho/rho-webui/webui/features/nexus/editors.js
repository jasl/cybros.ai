import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, field, formGroup, input, section, select } from "../../primitives/index.js";
import { modelDefaults } from "./model_defaults.js";

// The wire protocols a connection may declare, as Nexus's own form lists
// them (Codex Responses only when a connection already declares it).
export const PROTOCOLS = ["openai_compatible_chat", "openai_responses", "anthropic_messages", "gemini_generate_content", "openrouter_chat",
  "deepseek_responses", "xai_responses", "openai_images", "openai_audio_speech", "openai_audio_transcriptions", "openai_embeddings", "gemini_embeddings"];
const TEXT_FORMATS = new Set(["openai_compatible_chat", "openai_responses", "anthropic_messages", "gemini_generate_content", "openrouter_chat",
  "deepseek_responses", "xai_responses", "codex_responses"]);
const LIMIT_FIELDS = ["input_tokens", "output_tokens", "combined_input_output_tokens", "effective_input_tokens"];
const BOOLEAN_FIELDS = ["tool_calls", "streaming"];
const TEXT_RATES = ["input_per_mtok", "output_per_mtok", "cached_input_per_mtok"];
const DEEPSEEK_RATES = ["input_cache_hit_per_mtok", "input_cache_miss_per_mtok", "output_per_mtok"];

export const protocolLabel = (format) => t(`nexus.protocol_${format}`, {}, format);

// THE CONNECTION DECLARATION from the form over the one Nexus holds: the
// visible fields replace their keys, blank ones leave, and every key the
// form does not show — wire options, tiers, limits per workload — stands.
export function connectionDefinition(existing, values) {
  const definition = { ...(existing || {}) };
  for (const key of ["display_name", "api_format", "base_url", "credentials"]) {
    const value = String(values[key] ?? "").trim();
    if (value) definition[key] = value; else delete definition[key];
  }
  const limit = String(values.concurrency_limit ?? "").trim();
  if (limit) definition.concurrency_limit = Number.parseInt(limit, 10); else delete definition.concurrency_limit;
  return definition;
}

// THE MODEL DECLARATION the same way: the id, the name, the limits and the
// two capabilities the form shows, the pricing as chosen — none, kept, or
// the rates given — over whatever else the declaration carries.
export function modelDefinition(existing, values) {
  const definition = { ...(existing || {}) };
  definition.model_id = String(values.model_id ?? "").trim();
  const inherit = String(values.inherit ?? "").trim();
  if (inherit) definition.inherit = inherit; else delete definition.inherit;
  const name = String(values.display_name ?? "").trim();
  if (name) definition.display_name = name; else delete definition.display_name;
  const capabilities = { ...(definition.capabilities || {}) };
  const limits = { ...(values.reset_limits ? {} : capabilities.limits || {}) };
  for (const key of LIMIT_FIELDS) {
    const value = String(values[key] ?? "").trim();
    if (value) limits[key] = Number.parseInt(value, 10); else delete limits[key];
  }
  // An authored empty block deliberately clears the model's entire window.
  // Merely opening and saving the form must not turn that into inheritance.
  const keepEmptyLimits = Object.hasOwn(capabilities, "limits") && Object.keys(capabilities.limits).length === 0 && !values.reset_limits && !values.limits_edited;
  if (Object.keys(limits).length || keepEmptyLimits) capabilities.limits = limits; else delete capabilities.limits;
  for (const key of BOOLEAN_FIELDS) {
    const value = String(values[key] ?? "");
    if (value) capabilities[key] = value === "true"; else delete capabilities[key];
  }
  if (values.input_modalities_mode === "inherit") delete capabilities.input_modalities;
  else if (values.input_modalities_mode === "custom") capabilities.input_modalities = values.input_modalities;
  if (Object.keys(capabilities).length) definition.capabilities = capabilities; else delete definition.capabilities;
  if (values.pricing_mode === "none") delete definition.pricing;
  else if (values.pricing_mode === "custom") {
    const rates = {};
    for (const key of values.rate_keys) {
      const value = String(values[key] ?? "").trim();
      if (value) rates[key] = value;
    }
    const schedule = { ...((definition.pricing || {}).schedule || {}) };
    delete schedule.kind;
    delete schedule.rates;
    definition.pricing = { account_unit: String(values.pricing_unit ?? "").trim(), schedule: { ...schedule, kind: "catalog_only", rates } };
  }
  return definition;
}

// Which rates a model of this wire is priced by.
export function rateKeys(format) {
  if (format === "deepseek_responses") return DEEPSEEK_RATES;
  return TEXT_FORMATS.has(format) ? TEXT_RATES : [];
}

function editorForm({ title, description, fields, submitLabel, onSubmit, onClose, attrs = {} }) {
  const failure = alert({ tone: "error" });
  const save = button({ label: submitLabel, variant: "primary", size: "sm", type: "submit" });
  const fieldset = el("fieldset", { class: "settings-form__fields" }, ...fields, el("div", { class: "row" }, save, button({ label: t("common.cancel"), size: "sm", onClick: onClose })));
  const form = el("form", { class: "settings-form", onsubmit: async (event) => {
    event.preventDefault();
    failure.hide();
    const refusal = await onSubmit({ disable: () => { fieldset.disabled = true; } });
    if (refusal) { failure.show(refusal); fieldset.disabled = false; }
  } }, fieldset, failure.element);
  const card = section({ title, description });
  card.body.append(form);
  card.element.classList.add("nexus-page__editor");
  for (const [name, value] of Object.entries(attrs)) card.element.setAttribute(name, value);
  return { element: card.element, form, dispose() { card.element.remove(); } };
}

// THE CONNECTION EDITOR: a new provider, or one's connection — id, name,
// protocol, endpoint, authentication, and the concurrency ceiling under
// Advanced. `save(definition)` answers a refusal sentence or nothing.
export function connectionEditor({ provider = null, definition = null, save, onClose }) {
  const creating = !provider;
  const current = definition || {};
  const id = input({ name: "provider_id", autocomplete: "off", spellcheck: "false", value: provider?.id || "", attrs: creating ? {} : { readonly: "" } });
  const displayName = input({ name: "display_name", autocomplete: "off", value: current.display_name || "" });
  const formats = PROTOCOLS.includes(current.api_format) || !current.api_format ? PROTOCOLS : [...PROTOCOLS, current.api_format];
  const format = select({ name: "api_format", options: formats.map((value) => ({ value, label: protocolLabel(value) })), value: current.api_format || "openai_compatible_chat" });
  const baseUrl = input({ name: "base_url", type: "url", autocomplete: "url", spellcheck: "false", value: current.base_url || "", placeholder: "http://localhost:11434/v1" });
  const credentialOptions = current.credentials === "codex" ? [{ value: "codex", label: t("nexus.credentials_codex") }]
    : [{ value: "api_key", label: t("nexus.credentials_api_key") }, { value: "none", label: t("nexus.credentials_none") }];
  const credentials = select({ name: "credentials", options: credentialOptions, value: current.credentials || "api_key" });
  const concurrency = input({ name: "concurrency_limit", type: "number", min: 1, step: 1, value: current.concurrency_limit ?? "" });
  const advanced = formGroup({ title: t("nexus.concurrency") });
  advanced.append(field({ label: t("nexus.concurrent_requests"), control: concurrency, hint: t("nexus.concurrent_requests_hint") }).element);
  const idField = field({ label: t("nexus.provider_id"), control: id, hint: t("nexus.provider_id_hint") });
  return editorForm({
    title: creating ? t("nexus.add_provider") : t("nexus.edit_connection_title", { name: provider.display_name || provider.id }),
    description: t("nexus.connection_description"),
    attrs: { "data-editor": creating ? "new-provider" : `connection:${provider.id}` },
    fields: [idField.element,
      field({ label: t("nexus.display_name"), control: displayName, hint: t("nexus.display_name_hint") }).element,
      field({ label: t("nexus.protocol"), control: format, hint: t("nexus.protocol_hint") }).element,
      field({ label: t("nexus.base_url"), control: baseUrl, hint: t("nexus.base_url_hint") }).element,
      field({ label: t("nexus.authentication"), control: credentials, hint: t("nexus.authentication_hint") }).element,
      advanced.element],
    submitLabel: creating ? t("nexus.add_provider") : t("nexus.save_connection"),
    onClose,
    onSubmit: async ({ disable }) => {
      const providerId = id.value.trim();
      if (!/^[a-z0-9][a-z0-9_-]*$/.test(providerId)) { idField.setError(t("nexus.provider_id_hint")); id.focus(); return null; }
      idField.setError(null);
      if (!baseUrl.value.trim()) { baseUrl.focus(); return t("nexus.base_url_required"); }
      disable();
      return save(providerId, connectionDefinition(current, { display_name: displayName.value, api_format: format.value, base_url: baseUrl.value,
        credentials: credentials.value, concurrency_limit: concurrency.value }));
    },
  });
}

// THE MODEL EDITOR: a new model under a provider, or one's declaration —
// the upstream id, the name, the context limits, tool calls and streaming
// as the protocol's default, supported or disabled, and the optional cost
// estimate. `save(ref, definition)` answers a refusal sentence or nothing.
export function modelEditor({ provider, format, model = null, definition = null, modelDefinitions = {}, costUnit = null, save, onClose }) {
  const creating = !model;
  const current = definition || {};
  const capabilities = current.capabilities || {};
  const limits = capabilities.limits || {};
  const pricing = current.pricing || {};
  const keys = rateKeys(current.api_format || format);
  const inherit = select({ name: "inherit", options: [{ value: "", label: t("nexus.custom_definition") },
    ...Object.entries(modelDefinitions).sort(([left], [right]) => left.localeCompare(right)).map(([value, base]) => ({ value, label: base.display_name || value }))],
  value: current.inherit || "" });
  const modelId = input({ name: "model_id", autocomplete: "off", spellcheck: "false", value: current.model_id || (model ? model.replace(`${provider.id}/`, "") : "") });
  const displayName = input({ name: "display_name", autocomplete: "off", value: current.display_name || "" });
  const limitInputs = Object.fromEntries(LIMIT_FIELDS.map((key) => [key, input({ name: key, type: "number", min: 1, step: 1, value: limits[key] ?? "" })]));
  const booleanInputs = Object.fromEntries(BOOLEAN_FIELDS.map((key) => [key, select({ name: key, options: [
    { value: "", label: t("nexus.capability_default") }, { value: "true", label: t("nexus.capability_supported") }, { value: "false", label: t("nexus.capability_disabled") }],
  value: key in capabilities ? String(capabilities[key]) : "" })]));
  const limitFields = Object.fromEntries(LIMIT_FIELDS.map((key) => [key, field({ label: t(`nexus.limit_${key}`), control: limitInputs[key] })]));
  const booleanFields = Object.fromEntries(BOOLEAN_FIELDS.map((key) => [key, field({ label: t(`nexus.capability_${key}`), control: booleanInputs[key] })]));
  const defaults = modelDefaults({ inherit, modelDefinitions, capabilities, limitInputs, limitFields, booleanInputs, booleanFields });
  let limitsEdited = false;
  let resetLimits = false;
  const restoreLimits = button({ label: t("nexus.use_model_limits"), size: "sm", onClick: () => {
    for (const control of Object.values(limitInputs)) control.value = "";
    resetLimits = true;
    limitsEdited = true;
    paintLimits();
  } });
  const paintLimits = () => {
    const hasValues = Object.values(limitInputs).some((control) => control.value.trim() !== "");
    const hasOtherLimits = !resetLimits && Object.keys(limits).some((key) => !LIMIT_FIELDS.includes(key));
    const hasEmptyBlock = !resetLimits && !limitsEdited && Object.hasOwn(capabilities, "limits") && !Object.keys(limits).length;
    const limitsOverridden = hasValues || hasOtherLimits || hasEmptyBlock;
    restoreLimits.hidden = !limitsOverridden;
    defaults.paint({ limitsOverridden });
  };
  for (const control of Object.values(limitInputs)) control.addEventListener("input", () => { limitsEdited = true; paintLimits(); });
  paintLimits();
  const contextLimits = formGroup({ title: t("nexus.context_limits"), description: t("nexus.limits_hint") });
  contextLimits.append(...Object.values(limitFields).map((item) => item.element), el("div", { class: "row" }, restoreLimits));
  const priced = Object.keys(pricing).length > 0;
  const mode = select({ name: "pricing_mode", options: [
    { value: "none", label: t("nexus.pricing_none") }, ...(priced ? [{ value: "preserve", label: t("nexus.pricing_preserve") }] : []),
    ...(keys.length ? [{ value: "custom", label: t("nexus.pricing_custom") }] : [])], value: priced ? "preserve" : "none" });
  const unit = input({ name: "pricing_unit", autocomplete: "off", value: pricing.account_unit || costUnit || "" });
  const rateInputs = Object.fromEntries(keys.map((key) => [key, input({ name: key, inputmode: "decimal", autocomplete: "off", value: pricing.schedule?.rates?.[key] ?? "" })]));
  const rates = el("div", { class: "stack stack--tight" }, field({ label: t("nexus.cost_unit"), control: unit, hint: t("nexus.cost_unit_hint") }).element,
    ...keys.map((key) => field({ label: t(`nexus.rate_${key}`, {}, key), control: rateInputs[key] }).element));
  const paintRates = () => { rates.hidden = mode.value !== "custom"; };
  mode.addEventListener("change", paintRates);
  paintRates();
  const cost = formGroup({ title: t("nexus.cost_estimate"), description: t("nexus.cost_estimate_hint") });
  cost.append(field({ label: t("nexus.pricing"), control: mode }).element, rates);
  const idField = field({ label: t("nexus.model_id"), control: modelId, hint: t("nexus.model_id_hint") });
  return editorForm({
    title: creating ? t("nexus.add_model_title", { name: provider.display_name || provider.id }) : t("nexus.edit_model_title", { ref: model }),
    description: t("nexus.model_description"),
    attrs: { "data-editor": creating ? `new-model:${provider.id}` : `model:${model}` },
    fields: [field({ label: t("nexus.model_definition"), control: inherit, hint: t("nexus.model_definition_hint") }).element,
      defaults.element,
      idField.element,
      field({ label: t("nexus.display_name"), control: displayName, hint: t("nexus.model_display_name_hint") }).element,
      contextLimits.element,
      ...Object.values(booleanFields).map((item) => item.element),
      defaults.mediaElement,
      cost.element],
    submitLabel: t("nexus.save_model"),
    onClose,
    onSubmit: async ({ disable }) => {
      const upstream = modelId.value.trim();
      if (!upstream) { idField.setError(t("nexus.model_id_hint")); modelId.focus(); return null; }
      idField.setError(null);
      disable();
      const values = { model_id: upstream, inherit: inherit.value, display_name: displayName.value, pricing_mode: mode.value, pricing_unit: unit.value,
        rate_keys: keys, reset_limits: resetLimits, limits_edited: limitsEdited, ...defaults.values() };
      for (const key of LIMIT_FIELDS) values[key] = limitInputs[key].value;
      for (const key of BOOLEAN_FIELDS) values[key] = booleanInputs[key].value;
      for (const key of keys) values[key] = rateInputs[key].value;
      return save(model || `${provider.id}/${upstream}`, modelDefinition(current, values));
    },
  });
}
