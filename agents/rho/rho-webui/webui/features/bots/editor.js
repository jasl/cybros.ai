import { el, uniqueId } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, field, input, select, switchControl, textarea } from "../../primitives/index.js";

export const NAME_FORMAT = /^[a-z0-9][a-z0-9_-]{1,31}$/;

// Bot identity and delegation choices are independent of the reusable Preset.
export function policyOf(bot) {
  return {
    name: bot?.name || "", display_name: bot?.display_name || "", description: bot?.description || "",
    audience: bot?.audience || "owner", preset_public_id: bot?.preset_public_id || "", subagent: bot?.subagent ?? true,
    welcome_message: bot?.welcome_message || "",
    welcome_mode: bot?.welcome_message == null ? "default" : bot.welcome_message === "" ? "none" : "custom",
  };
}

export function bodyOf(values) {
  return {
    name: values.name.trim(), display_name: values.display_name.trim() || null, description: values.description.trim(),
    audience: values.audience, preset_public_id: values.preset_public_id, subagent: values.subagent,
    welcome_message: values.welcome_mode === "none" ? "" : values.welcome_mode === "custom" ? values.welcome_message : null,
  };
}

export const purposeOptions = () => [
  { value: "owner", label: t("agents.purpose_owner") }, { value: "external", label: t("agents.purpose_external") },
];

export function agentEditor({ shell, bot = null, catalog = null, onCreated, onSaved, onClose }) {
  const editing = !!bot;
  const values = policyOf(bot);
  const requests = new AbortController();
  let saving = false;
  const failure = alert({ tone: "error" });
  const name = input({ name: "name", autocomplete: "off", spellcheck: "false", value: values.name, attrs: { readonly: editing || undefined } });
  const nameField = field({ label: t("agents.name"), control: name, hint: editing ? null : t("agents.name_hint") });
  const displayName = input({ name: "display_name", autocomplete: "off", value: values.display_name });
  const description = input({ name: "description", autocomplete: "off", value: values.description });
  let savedAudience = values.audience;
  const purpose = select({ name: "audience", value: values.audience, options: purposeOptions() });
  const purposeHelp = el("p", { class: "field__hint" });
  function paintPurpose() {
    purpose.disabled = editing && savedAudience === "external";
    purposeHelp.textContent = purpose.value === "external" ?
      (editing && savedAudience === "external" ? t("agents.purpose_external_fixed") : t("agents.purpose_external_hint")) : t("agents.purpose_owner_hint");
  }
  purpose.addEventListener("change", paintPurpose);
  paintPurpose();
  const preset = select({ name: "preset_public_id", required: true });
  const presetField = field({ label: t("agents.preset"), control: preset, hint: t("agents.preset_hint") });
  const editPreset = button({ label: t("agents.edit_preset"), size: "sm", onClick: () => shell.settings.open("presets", preset.value) });
  const subagentHintId = uniqueId("subagent-hint");
  const subagent = switchControl({ label: t("agents.subagent"), checked: values.subagent,
    attrs: { name: "subagent", "aria-describedby": subagentHintId } });
  const welcomeMode = select({ name: "welcome_mode", value: values.welcome_mode, options: [
    { value: "default", label: t("agents.welcome_default") }, { value: "custom", label: t("agents.welcome_custom") },
    { value: "none", label: t("agents.welcome_none") },
  ] });
  const welcome = textarea({ name: "welcome_message", rows: 4, attrs: { autocomplete: "off" } });
  welcome.value = values.welcome_message;
  const paintWelcome = () => { welcome.disabled = welcomeMode.value !== "custom"; };
  welcomeMode.addEventListener("change", paintWelcome);
  paintWelcome();
  const save = button({ label: editing ? t("common.save") : t("agents.create"), variant: "primary", size: "sm", type: "submit" });
  const cancel = button({ label: t("common.cancel"), size: "sm", onClick: () => onClose() });
  const fields = el("fieldset", { class: "settings-form__fields" },
    nameField.element,
    field({ label: t("agents.display_name"), control: displayName }).element,
    field({ label: t("agents.description_label"), control: description, hint: t("agents.description_hint") }).element,
    el("div", { class: "stack stack--tight" }, field({ label: t("agents.purpose"), control: purpose }).element, purposeHelp),
    el("div", { class: "stack stack--tight" }, presetField.element, el("div", { class: "row" }, editPreset)),
    el("div", { class: "field" }, subagent.element, el("p", { class: "field__hint", id: subagentHintId, text: t("agents.subagent_hint") })),
    field({ label: t("agents.welcome_mode"), control: welcomeMode }).element,
    field({ label: t("agents.welcome"), control: welcome, hint: t("agents.welcome_hint") }).element,
    el("div", { class: "row" }, save, cancel));
  const form = el("form", { class: "settings-form", onsubmit: (event) => { event.preventDefault(); submitBot(); } }, fields, failure.element);
  const element = el("section", { class: "card bots-page__editor" }, form);

  function paintPresets(chosen = values.preset_public_id) {
    const selected = chosen || (!editing ? catalog?.default_bot_preset_public_id : null) || "";
    const options = (catalog?.presets || []).map((entry) => ({ value: entry.public_id, label: entry.name }));
    if (selected && !options.some((entry) => entry.value === selected)) {
      options.push({ value: selected, label: t("common.unavailable_item", { name: bot?.preset_name || selected }), disabled: true });
    }
    if (!selected) options.unshift({ value: "", label: t(catalog ? "agents.preset_choose" : "presets.loading"), disabled: true });
    preset.replaceChildren(...options.map((option) => el("option", { value: option.value, text: option.label, disabled: option.disabled || undefined })));
    preset.value = selected;
    preset.disabled = !catalog;
    save.disabled = !catalog;
    editPreset.disabled = !selected || !catalog?.presets.some((entry) => entry.public_id === selected);
  }
  preset.addEventListener("change", () => { presetField.setError(null); editPreset.disabled = !preset.value; });

  async function submitBot() {
    if (saving || !catalog || requests.signal.aborted) return;
    const body = bodyOf({ name: name.value, display_name: displayName.value, description: description.value,
      audience: purpose.value, preset_public_id: preset.value, subagent: subagent.input.checked,
      welcome_message: welcome.value, welcome_mode: welcomeMode.value });
    if (!NAME_FORMAT.test(body.name)) { nameField.setError(t("agents.name_hint")); name.focus(); return; }
    nameField.setError(null);
    if (!body.description) { failure.show(t("agents.description_required")); description.focus(); return; }
    if (!catalog.presets.some((entry) => entry.public_id === body.preset_public_id)) {
      presetField.setError(t("agents.preset_choose")); preset.focus(); return;
    }
    saving = true; fields.disabled = true; failure.hide();
    try {
      const answer = await shell.call("/agents", { method: "PUT", body, signal: requests.signal });
      if (requests.signal.aborted) return;
      savedAudience = answer.agent.audience || body.audience;
      paintPurpose();
      if (editing) onSaved?.({ ...answer.agent, audience: savedAudience });
      const label = answer.agent.display_name || answer.agent.name;
      shell.toast(editing ? t("agents.saved", { name: label }) : t("agents.created", { name: label }), { tone: "success" });
      if (!editing) onCreated(answer.agent);
    } catch (error) {
      if (!requests.signal.aborted && error.name !== "AbortError") failure.show(error.message || t("conversation.request_failed"));
    } finally { saving = false; fields.disabled = false; }
  }

  paintPresets();
  return {
    element,
    updateChoices(next) { catalog = next; paintPresets(preset.value); },
    focus() { (editing ? displayName : name).focus(); },
    dispose() { requests.abort(); element.remove(); },
  };
}
